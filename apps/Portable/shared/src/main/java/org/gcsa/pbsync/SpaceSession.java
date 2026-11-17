package org.gcsa.pbsync;

import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.nio.channels.FileChannel;
import java.nio.channels.FileLock;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.StandardCopyOption;
import java.nio.file.StandardOpenOption;
import java.security.MessageDigest;
import java.security.SecureRandom;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Base64;
import java.util.Comparator;
import java.util.HashMap;
import java.util.HashSet;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Set;
import java.util.UUID;
import java.util.regex.Pattern;
import javax.crypto.AEADBadTagException;
import javax.crypto.Cipher;
import javax.crypto.SecretKeyFactory;
import javax.crypto.spec.GCMParameterSpec;
import javax.crypto.spec.PBEKeySpec;
import javax.crypto.spec.SecretKeySpec;
import org.json.JSONArray;
import org.json.JSONObject;

import static java.nio.charset.StandardCharsets.UTF_8;

public final class SpaceSession implements AutoCloseable {
    static final int MAX_BYTES = 128 * 1024 * 1024;
    private static final int ATTACHMENT_LIMIT = 10 * 1024 * 1024;
    private static final Pattern UUID_PATTERN = Pattern.compile("[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}");
    private static final SecureRandom RANDOM = new SecureRandom();
    private static final String[] VAULT_TYPES = {"login", "totp", "passkey", "recoveryCodes", "card", "identity", "note"};

    public record Entry(String id, String title, String kind, String parent, long order,
                        String url, String username, String password, String notes, boolean deleted) {
        public boolean editable() { return kind.equals("bookmark") || kind.equals("folder") || kind.equals("login"); }
        @Override public String toString() { return title; }
    }

    public record Changes(int downloaded, int uploaded) {}

    private final Path file;
    private final JSONObject header;
    private final String prefix;
    private final String deviceID;
    private final byte[] key;
    private JSONObject state;
    private byte[] knownDigest;

    private SpaceSession(Path file, byte[] knownBytes, byte[] archiveBytes,
                         char[] secret, boolean recovery) throws Exception {
        this(file, knownBytes, archiveBytes, secret, recovery, null);
    }

    private SpaceSession(Path file, byte[] knownBytes, byte[] archiveBytes,
                         char[] secret, boolean recovery, byte[] localKey) throws Exception {
        this.file = file;
        // 同一份本地副本始终有稳定的设备 ID。不同安装目录独立生成。
        this.deviceID = deviceID(file.getParent());
        JSONObject archive = json(archiveBytes);
        header = archive.getJSONObject("header");
        String spaceID = id(header.getString("spaceID"));
        int epoch = header.getInt("keyEpoch");
        int iterations = header.getInt("iterations");
        byte[] salt = bytes(header, "salt");
        if (header.getInt("format") != 1 || epoch < 1 || iterations < 600_000 || iterations > 2_000_000
                || salt.length != 32 || bytes(header, "passwordSlot").length != 60
                || bytes(header, "recoverySlot").length != 60) throw damaged();
        prefix = "PBsync|1|" + spaceID + "|" + epoch + "|";
        key = localKey == null ? unwrap(secret, recovery, salt, iterations) : localKey.clone();
        try {
            state = decodeState(archive);
            knownDigest = knownBytes == null ? null : digest(knownBytes);
        } catch (Exception error) {
            Arrays.fill(key, (byte) 0);
            throw error;
        }
    }

    private byte[] unwrap(char[] secret, boolean recovery, byte[] salt, int iterations) throws Exception {
        String slot = recovery ? "recovery" : "password";
        byte[] wrapping;
        if (recovery) {
            try {
                wrapping = Base64.getDecoder().decode(new String(secret).trim());
                if (wrapping.length != 32) throw new IllegalArgumentException();
            } catch (IllegalArgumentException error) {
                throw new IOException("恢复密钥无效。");
            }
        } else {
            if (new String(secret).getBytes(UTF_8).length > 4096) throw new IOException("主密码过长。");
            PBEKeySpec spec = new PBEKeySpec(secret, salt, iterations, 256);
            try {
                wrapping = SecretKeyFactory.getInstance("PBKDF2WithHmacSHA256").generateSecret(spec).getEncoded();
            } finally {
                spec.clearPassword();
            }
        }
        try {
            return open(wrapping, bytes(header, slot + "Slot"), prefix + slot);
        } catch (AEADBadTagException error) {
            throw new IOException("解锁材料错误，或保险库已损坏。");
        } finally {
            Arrays.fill(wrapping, (byte) 0);
        }
    }

    public static SpaceSession openLocal(Path file, char[] secret, boolean recovery) throws Exception {
        byte[] data = readFile(file);
        return new SpaceSession(file, data, data, secret, recovery);
    }

    public static SpaceSession openWithDeviceKey(Path file, byte[] localKey) throws Exception {
        if (localKey.length != 32) throw new IOException("本机解锁密钥无效。");
        byte[] data = readFile(file);
        return new SpaceSession(file, data, data, null, false, localKey);
    }

    public synchronized byte[] deviceKey() throws Exception {
        active();
        return key.clone();
    }

    public static SpaceSession restore(Path file, byte[] backup, char[] secret, boolean recovery, boolean bookmarks) throws Exception {
        SpaceSession session = new SpaceSession(file, null, backup, secret, recovery);
        try {
            session.checkKind(bookmarks);
            session.persist(session.state);
            return session;
        } catch (Exception error) {
            session.close();
            throw error;
        }
    }

    public static SpaceSession connect(Path file, DavStorage dav, char[] password, boolean bookmarks) throws Exception {
        SpaceSession session = new SpaceSession(file, null, dav.read("space.pbsync"), password, false);
        try {
            session.checkKind(bookmarks);
            session.exchange(dav, false);
            return session;
        } catch (Exception error) {
            session.close();
            throw error;
        }
    }

    private void checkKind(boolean bookmarks) throws Exception {
        if (bookmarks() != bookmarks) throw new IOException("请选择与此备份类型对应的空间。");
    }

    public synchronized String name() throws Exception { return active().getString("name"); }
    public synchronized boolean bookmarks() throws Exception { return active().getString("kind").equals("bookmarks"); }

    // 列表只读取导航字段。密码只在用户打开指定条目时交给界面。
    public synchronized List<Entry> entries(boolean deleted) throws Exception {
        Map<String, JSONObject> latest = latest(revisions(active()));
        List<Entry> rows = new ArrayList<>();
        for (JSONObject revision : latest.values()) {
            if (revision.getBoolean("deleted") != deleted) continue;
            JSONObject item = revision.getJSONObject("item");
            rows.add(entry(item, effectiveParent(item, latest), deleted, false));
        }
        rows.sort(Comparator.comparingLong(Entry::order).thenComparing(Entry::id));
        return rows;
    }

    public synchronized Entry detail(String itemID) throws Exception {
        Map<String, JSONObject> latest = latest(revisions(active()));
        JSONObject revision = latest.get(requireID(itemID));
        if (revision == null) throw new IOException("条目不存在。");
        JSONObject item = revision.getJSONObject("item");
        return entry(item, effectiveParent(item, latest), revision.getBoolean("deleted"), true);
    }

    public synchronized void save(String itemID, String kind, String title, String url, String username,
                                  String password, String notes, String parent) throws Exception {
        JSONObject next = copy(writable());
        Map<String, JSONObject> history = revisions(next);
        Map<String, JSONObject> latest = latest(history);
        JSONObject previous = itemID == null ? null : latest.get(id(itemID));
        if (itemID != null && (previous == null || previous.getBoolean("deleted"))) throw changed();
        JSONObject item;
        if (previous == null) {
            item = new JSONObject().put("id", newID()).put("kind", kind).put("fields", new JSONObject())
                .put("urls", new JSONArray()).put("tags", new JSONArray()).put("sourceData", new JSONObject())
                .put("attachments", new JSONArray());
            long order = 0;
            for (JSONObject row : latest.values()) {
                order = Math.max(order, row.getJSONObject("item").getLong("order"));
            }
            item.put("order", Math.addExact(order, 1));
        } else {
            item = copy(previous.getJSONObject("item"));
            kind = item.getString("kind");
        }
        if (!Arrays.asList("bookmark", "folder", "login").contains(kind) || title.trim().isEmpty()) {
            throw new IOException("请输入有效的条目标题。");
        }
        item.put("title", title).put("notes", notes);
        if (!kind.equals("folder")) {
            JSONArray urls = item.getJSONArray("urls");
            if (urls.length() > 0 || !url.isEmpty()) urls.put(0, url);
        }
        if (kind.equals("login")) {
            item.getJSONObject("fields").put("username", username).put("password", password);
        }
        if (bookmarks()) {
            if (parent == null) item.remove("parentID");
            else {
                item.put("parentID", id(parent).toUpperCase(Locale.ROOT));
                if (effectiveParent(item, latest) == null) throw new IOException("目标目录无效。");
            }
        }
        append(next, history, previous, item, false);
        persist(next);
    }

    public synchronized void delete(String itemID) throws Exception {
        JSONObject next = copy(writable());
        Map<String, JSONObject> history = revisions(next);
        Map<String, JSONObject> latest = latest(history);
        JSONObject revision = latest.get(requireID(itemID));
        if (revision == null || revision.getBoolean("deleted")) throw changed();
        Set<String> deleting = new HashSet<>();
        deleting.add(id(itemID));
        boolean changed;
        do {
            changed = false;
            for (Map.Entry<String, JSONObject> row : latest.entrySet()) {
                JSONObject item = row.getValue().getJSONObject("item");
                if (!row.getValue().getBoolean("deleted") && deleting.contains(parentID(item))) {
                    changed |= deleting.add(row.getKey());
                }
            }
        } while (changed);
        for (String target : deleting) {
            JSONObject previous = latest.get(target);
            append(next, history, previous, previous.getJSONObject("item"), true);
        }
        persist(next);
    }

    public synchronized void restoreItem(String itemID) throws Exception {
        JSONObject next = copy(writable());
        Map<String, JSONObject> history = revisions(next);
        JSONObject revision = latest(history).get(requireID(itemID));
        if (revision == null || !revision.getBoolean("deleted")) throw changed();
        append(next, history, revision, revision.getJSONObject("item"), false);
        persist(next);
    }

    public synchronized void move(String itemID, int offset) throws Exception {
        JSONObject next = copy(writable());
        Map<String, JSONObject> history = revisions(next);
        Map<String, JSONObject> latest = latest(history);
        Entry entry = detail(itemID);
        if (!bookmarks() || entry.deleted() || (offset != -1 && offset != 1)) throw changed();
        List<Entry> siblings = new ArrayList<>();
        for (Entry row : entries(false)) if (java.util.Objects.equals(row.parent(), entry.parent())) siblings.add(row);
        int from = 0;
        while (from < siblings.size() && !siblings.get(from).id().equals(entry.id())) from++;
        int to = from + offset;
        if (to < 0 || to >= siblings.size()) return;
        java.util.Collections.swap(siblings, from, to);
        // 重新分配同级顺序，避免原有条目具有相同 order 时交换无效。
        for (int index = 0; index < siblings.size(); index++) {
            Entry row = siblings.get(index);
            if (row.order() == index) continue;
            JSONObject previous = latest.get(row.id());
            JSONObject item = copy(previous.getJSONObject("item")).put("order", index);
            append(next, history, previous, item, false);
        }
        persist(next);
    }

    public synchronized Changes sync(DavStorage dav) throws Exception { return exchange(dav, true); }

    private Changes exchange(DavStorage dav, boolean push) throws Exception {
        JSONObject before = writable();
        JSONObject remote = decodeState(json(dav.read("space.pbsync")));
        if (remote.getBoolean("retired") || remote.getLong("generation") != before.getLong("generation")
                || !remote.getString("kind").equals(before.getString("kind"))) throw changed();

        Map<String, JSONObject> incoming = revisions(remote);
        Set<String> names = dav.list();
        for (String name : names) {
            if (!name.endsWith(".pbop")) continue;
            JSONObject revision = operation(dav.read(name), name);
            validate(revision, before.getString("kind"));
            add(incoming, revision);
        }
        for (JSONObject revision : incoming.values()) {
            JSONArray attachments = revision.getJSONObject("item").getJSONArray("attachments");
            for (int i = 0; i < attachments.length(); i++) {
                JSONObject attachment = attachments.getJSONObject(i);
                if (!attachment.isNull("remoteSize") && !names.contains(id(attachment.getString("id")) + ".pbatt")) {
                    throw new IOException("远端附件缺失。");
                }
            }
        }
        JSONObject next = copy(before);
        Map<String, JSONObject> combined = revisions(next);
        int oldCount = combined.size();
        for (JSONObject revision : incoming.values()) add(combined, revision);
        validateChain(combined, before.getString("kind"));
        next.put("revisions", new JSONArray(combined.values()));
        int downloaded = combined.size() - oldCount;
        if (downloaded > 0 || knownDigest == null) persist(next);

        int uploaded = 0;
        if (push) {
            List<JSONObject> outgoing = new ArrayList<>();
            for (Map.Entry<String, JSONObject> row : combined.entrySet()) {
                if (!incoming.containsKey(row.getKey())) outgoing.add(row.getValue());
            }
            outgoing.sort(SpaceSession::compare); // 先提交父版本，网络中断后可重试。
            for (JSONObject revision : outgoing) {
                JSONArray attachments = revision.getJSONObject("item").getJSONArray("attachments");
                for (int i = 0; i < attachments.length(); i++) {
                    JSONObject attachment = attachments.getJSONObject(i);
                    if (!attachment.isNull("remoteSize")) validateRemoteAttachment(dav, attachment, names);
                }
                String revisionID = id(revision.getString("id"));
                String name = revisionID + ".pbop";
                JSONObject encrypted = new JSONObject().put("id", revision.getString("id"))
                    .put("spaceID", header.getString("spaceID")).put("keyEpoch", header.getInt("keyEpoch"))
                    .put("sealed", encode(seal(jsonBytes(revision), prefix + "operation:" + revisionID)));
                if (!dav.create(name, jsonBytes(encrypted)) &&
                        !sameRevision(revision, operation(dav.read(name), name))) throw damaged();
                uploaded++;
            }
        }
        return new Changes(downloaded, uploaded);
    }

    private void validateRemoteAttachment(DavStorage dav, JSONObject attachment, Set<String> names) throws Exception {
        String attachmentID = id(attachment.getString("id"));
        String name = attachmentID + ".pbatt";
        if (!names.contains(name)) throw new IOException("附件只存在于来源空间，当前修改已保存在本机。");
        byte[] data = open(key, dav.read(name), prefix + name);
        try {
            if (data.length != attachment.getInt("remoteSize") ||
                    !hex(digest(data)).equals(attachment.getString("digest"))) throw damaged();
        } finally {
            Arrays.fill(data, (byte) 0);
        }
    }

    private JSONObject operation(byte[] data, String name) throws Exception {
        JSONObject object = json(data);
        String revisionID = id(object.getString("id"));
        if (!(revisionID + ".pbop").equals(name) || object.getInt("keyEpoch") != header.getInt("keyEpoch")
                || !id(object.getString("spaceID")).equals(id(header.getString("spaceID")))) throw damaged();
        JSONObject revision = json(open(key, bytes(object, "sealed"), prefix + "operation:" + revisionID));
        if (!id(revision.getString("id")).equals(revisionID)) throw damaged();
        return revision;
    }

    private JSONObject decodeState(JSONObject archive) throws Exception {
        JSONObject remoteHeader = archive.getJSONObject("header");
        if (!equivalent(header, remoteHeader)) throw new IOException("同步位置的保险库标识或密钥已更改。");
        JSONObject decoded = json(open(key, bytes(archive, "sealedState"), prefix + "state"));
        decoded.getString("name");
        if (decoded.getLong("generation") < 1) throw damaged();
        decoded.getBoolean("retired");
        validateChain(revisions(decoded), decoded.getString("kind"));
        return decoded;
    }

    private void append(JSONObject next, Map<String, JSONObject> history, JSONObject parent,
                        JSONObject item, boolean deleted) throws Exception {
        long time = 0, counter = 0;
        for (JSONObject revision : history.values()) {
            JSONObject clock = revision.getJSONObject("time");
            long ms = clock.getLong("milliseconds"), tick = clock.getLong("counter");
            if (ms > time || (ms == time && tick > counter)) {
                time = ms;
                counter = tick;
            }
        }
        long now = System.currentTimeMillis();
        JSONObject clock = new JSONObject().put("milliseconds", Math.max(now, time))
            .put("counter", now > time ? 0 : Math.addExact(counter, 1));
        JSONObject revision = new JSONObject().put("id", newID()).put("deviceID", deviceID)
            .put("time", clock).put("parents", parent == null ? new JSONArray() : new JSONArray().put(parent.getString("id")))
            .put("item", item).put("deleted", deleted);
        validate(revision, next.getString("kind"));
        next.getJSONArray("revisions").put(revision);
        add(history, revision);
    }

    private static Map<String, JSONObject> revisions(JSONObject state) throws Exception {
        Map<String, JSONObject> revisions = new HashMap<>();
        JSONArray list = state.getJSONArray("revisions");
        for (int i = 0; i < list.length(); i++) add(revisions, list.getJSONObject(i));
        return revisions;
    }

    private static void add(Map<String, JSONObject> map, JSONObject revision) throws Exception {
        String key = id(revision.getString("id"));
        JSONObject existing = map.putIfAbsent(key, revision);
        if (existing != null && !sameRevision(existing, revision)) throw damaged();
    }

    private static boolean sameRevision(JSONObject first, JSONObject second) throws Exception {
        if (equivalent(first, second)) return true;
        JSONObject projected = copy(second);
        JSONArray left = first.getJSONObject("item").getJSONArray("attachments");
        JSONArray right = projected.getJSONObject("item").getJSONArray("attachments");
        if (left.length() != right.length()) return false;
        for (int i = 0; i < left.length(); i++) {
            JSONObject a = left.getJSONObject(i), b = right.getJSONObject(i);
            if (a.isNull("remoteSize") == b.isNull("remoteSize")) continue;
            int aSize = a.isNull("remoteSize") ? bytes(a, "data").length : a.getInt("remoteSize");
            int bSize = b.isNull("remoteSize") ? bytes(b, "data").length : b.getInt("remoteSize");
            if (aSize != bSize) return false;
            if (a.isNull("remoteSize")) b.remove("remoteSize");
            else b.put("remoteSize", aSize);
            b.put("data", a.getString("data"));
        }
        return equivalent(first, projected);
    }

    private static Map<String, JSONObject> latest(Map<String, JSONObject> history) throws Exception {
        Map<String, JSONObject> latest = new HashMap<>();
        for (JSONObject revision : history.values()) {
            String item = id(revision.getJSONObject("item").getString("id"));
            JSONObject previous = latest.get(item);
            if (previous == null || compare(previous, revision) < 0) latest.put(item, revision);
        }
        return latest;
    }

    // 顺序与 Swift 的逻辑时钟、设备 ID、版本 ID 保持一致。
    private static int compare(JSONObject a, JSONObject b) {
        JSONObject left = a.optJSONObject("time"), right = b.optJSONObject("time");
        int result = Long.compare(left.optLong("milliseconds"), right.optLong("milliseconds"));
        if (result == 0) result = Long.compare(left.optLong("counter"), right.optLong("counter"));
        if (result == 0) result = a.optString("deviceID").compareToIgnoreCase(b.optString("deviceID"));
        if (result == 0) result = a.optString("id").compareToIgnoreCase(b.optString("id"));
        return result;
    }

    private static void validateChain(Map<String, JSONObject> history, String kind) throws Exception {
        if (!kind.equals("bookmarks") && !kind.equals("vault")) throw damaged();
        for (JSONObject revision : history.values()) {
            validate(revision, kind);
            String item = id(revision.getJSONObject("item").getString("id"));
            JSONArray parents = revision.getJSONArray("parents");
            Set<String> seen = new HashSet<>();
            for (int i = 0; i < parents.length(); i++) {
                String parentID = id(parents.getString(i));
                JSONObject parent = history.get(parentID);
                if (!seen.add(parentID) || parent == null || !id(parent.getJSONObject("item").getString("id")).equals(item)
                        || compareTime(parent.getJSONObject("time"), revision.getJSONObject("time")) >= 0) throw damaged();
            }
        }
    }

    private static int compareTime(JSONObject a, JSONObject b) throws Exception {
        int cmp = Long.compare(a.getLong("milliseconds"), b.getLong("milliseconds"));
        return cmp != 0 ? cmp : Long.compare(a.getLong("counter"), b.getLong("counter"));
    }

    private static void validate(JSONObject revision, String space) throws Exception {
        id(revision.getString("id"));
        id(revision.getString("deviceID"));
        revision.getBoolean("deleted");
        JSONObject clock = revision.getJSONObject("time");
        if (clock.getLong("milliseconds") < 0 || clock.getLong("counter") < 0 ||
                revision.getJSONArray("parents").length() > 10_000) throw damaged();
        JSONObject item = revision.getJSONObject("item");
        String itemID = id(item.getString("id"));
        String type = item.getString("kind");
        boolean bookmark = type.equals("folder") || type.equals("bookmark");
        if (bookmark != space.equals("bookmarks") || (!bookmark && !Arrays.asList(VAULT_TYPES).contains(type))
                || itemID.equals(parentID(item))) throw damaged();
        item.getLong("order");
        bounded(item.getString("title"), 8192);
        bounded(item.getString("notes"), 1_048_576);
        JSONObject fields = item.getJSONObject("fields");
        if (fields.length() > 256) throw damaged();
        for (java.util.Iterator<String> keys = fields.keys(); keys.hasNext();) bounded(fields.getString(keys.next()), 1_048_576);
        JSONArray urls = item.getJSONArray("urls");
        if (urls.length() > 100) throw damaged();
        for (int i = 0; i < urls.length(); i++) bounded(urls.getString(i), 32768);
        JSONArray attachments = item.getJSONArray("attachments");
        if (attachments.length() > 100) throw damaged();
        Set<String> seen = new HashSet<>();
        for (int i = 0; i < attachments.length(); i++) {
            JSONObject ref = attachments.getJSONObject(i);
            byte[] data = bytes(ref, "data");
            String hash = ref.getString("digest");
            if (!seen.add(id(ref.getString("id"))) || !hash.matches("[a-f0-9]{64}")) throw damaged();
            bounded(ref.getString("name"), 1024);
            ref.getString("mediaType");
            if (ref.isNull("remoteSize")) {
                if (data.length > ATTACHMENT_LIMIT || !hex(digest(data)).equals(hash)) throw damaged();
            } else if (data.length != 0 || ref.getInt("remoteSize") < 1 || ref.getInt("remoteSize") > ATTACHMENT_LIMIT) {
                throw damaged();
            }
        }
        JSONArray tags = item.getJSONArray("tags");
        for (int i = 0; i < tags.length(); i++) tags.getString(i);
        JSONObject source = item.getJSONObject("sourceData");
        for (java.util.Iterator<String> keys = source.keys(); keys.hasNext();) bytes(source, keys.next());
    }

    private static void bounded(String text, int limit) throws IOException {
        if (text.getBytes(UTF_8).length > limit) throw damaged();
    }

    private static Entry entry(JSONObject item, String parent, boolean deleted, boolean details) throws Exception {
        JSONObject fields = item.getJSONObject("fields");
        return new Entry(id(item.getString("id")), item.getString("title"), item.getString("kind"), parent,
            item.getLong("order"), item.getJSONArray("urls").optString(0, ""), fields.optString("username", ""),
            details ? fields.optString("password", "") : "", details ? item.getString("notes") : "", deleted);
    }

    private static String parentID(JSONObject item) throws Exception {
        return item.isNull("parentID") ? null : id(item.getString("parentID"));
    }

    private static String effectiveParent(JSONObject item, Map<String, JSONObject> latest) throws Exception {
        String parent = parentID(item);
        String cursor = parent;
        Set<String> seen = new HashSet<>();
        seen.add(id(item.getString("id")));
        while (cursor != null) {
            JSONObject revision = latest.get(cursor);
            if (!seen.add(cursor) || revision == null || revision.getBoolean("deleted")) return null;
            JSONObject folder = revision.getJSONObject("item");
            if (!folder.getString("kind").equals("folder")) return null;
            cursor = parentID(folder);
        }
        return parent;
    }

    private static boolean equivalent(Object left, Object right) throws Exception {
        if (left instanceof JSONObject && right instanceof JSONObject) {
            JSONObject a = (JSONObject) left, b = (JSONObject) right;
            if (a.length() != b.length()) return false;
            for (java.util.Iterator<String> keys = a.keys(); keys.hasNext();) {
                String name = keys.next();
                if (!b.has(name) || !equivalent(a.get(name), b.get(name))) return false;
            }
            return true;
        }
        if (left instanceof JSONArray && right instanceof JSONArray) {
            JSONArray a = (JSONArray) left, b = (JSONArray) right;
            if (a.length() != b.length()) return false;
            for (int i = 0; i < a.length(); i++) if (!equivalent(a.get(i), b.get(i))) return false;
            return true;
        }
        return left.equals(right);
    }

    private void persist(JSONObject next) throws Exception {
        byte[] encrypted = jsonBytes(new JSONObject().put("header", header)
            .put("sealedState", encode(seal(jsonBytes(next), prefix + "state"))));
        if (encrypted.length > MAX_BYTES) throw new IOException("保险库超过本地大小上限。");
        Path lock = file.resolveSibling(file.getFileName() + ".lock");
        try (FileChannel channel = FileChannel.open(lock, StandardOpenOption.CREATE, StandardOpenOption.WRITE);
             FileLock ignored = channel.lock()) {
            if (Files.exists(file) != (knownDigest != null) ||
                (knownDigest != null && !Arrays.equals(knownDigest, digest(readFile(file))))) throw changed();
            Path temporary = Files.createTempFile(file.getParent(), ".pbsync-", ".tmp");
            try {
                Files.write(temporary, encrypted);
                try (FileChannel stream = FileChannel.open(temporary, StandardOpenOption.WRITE)) { stream.force(true); }
                Files.move(temporary, file, StandardCopyOption.REPLACE_EXISTING, StandardCopyOption.ATOMIC_MOVE);
            } finally {
                Files.deleteIfExists(temporary);
            }
            knownDigest = digest(encrypted);
            state = next;
        }
    }

    private JSONObject active() throws IOException {
        if (state == null) throw new IOException("请先解锁。");
        return state;
    }

    private JSONObject writable() throws Exception {
        JSONObject current = active();
        if (current.getBoolean("retired")) throw new IOException("此同步位置已冻结。");
        return current;
    }

    @Override public synchronized void close() {
        Arrays.fill(key, (byte) 0);
        state = null;
    }

    private static String deviceID(Path directory) throws Exception {
        Files.createDirectories(directory);
        Path file = directory.resolve("device-id");
        Path lock = directory.resolve("device-id.lock");
        try (FileChannel channel = FileChannel.open(lock, StandardOpenOption.CREATE, StandardOpenOption.WRITE);
             FileLock ignored = channel.lock()) {
            if (!Files.exists(file)) Files.write(file, newID().getBytes(UTF_8), StandardOpenOption.CREATE_NEW);
            return id(new String(readFile(file), UTF_8)).toUpperCase(Locale.ROOT);
        }
    }

    public static byte[] readFile(Path file) throws IOException {
        try (InputStream stream = Files.newInputStream(file)) { return readLimited(stream, MAX_BYTES); }
    }

    public static byte[] readLimited(InputStream stream, int limit) throws IOException {
        ByteArrayOutputStream result = new ByteArrayOutputStream();
        byte[] block = new byte[16384];
        int count;
        while ((count = stream.read(block)) != -1) {
            if (result.size() > limit - count) throw new IOException("文件超过大小上限。");
            result.write(block, 0, count);
        }
        return result.toByteArray();
    }

    private byte[] seal(byte[] clear, String context) throws Exception {
        try {
            byte[] nonce = new byte[12];
            RANDOM.nextBytes(nonce);
            Cipher cipher = cipher(Cipher.ENCRYPT_MODE, key, nonce, context);
            byte[] body = cipher.doFinal(clear);
            byte[] packed = Arrays.copyOf(nonce, nonce.length + body.length);
            System.arraycopy(body, 0, packed, nonce.length, body.length);
            return packed;
        } finally {
            Arrays.fill(clear, (byte) 0);
        }
    }

    private static byte[] open(byte[] key, byte[] input, String context) throws Exception {
        if (input.length < 28) throw damaged();
        return cipher(Cipher.DECRYPT_MODE, key, Arrays.copyOf(input, 12), context)
            .doFinal(input, 12, input.length - 12);
    }

    private static Cipher cipher(int mode, byte[] key, byte[] nonce, String context) throws Exception {
        Cipher cipher = Cipher.getInstance("AES/GCM/NoPadding");
        cipher.init(mode, new SecretKeySpec(key, "AES"), new GCMParameterSpec(128, nonce));
        cipher.updateAAD(context.getBytes(UTF_8));
        return cipher;
    }

    private static JSONObject json(byte[] data) throws Exception { return new JSONObject(new String(data, UTF_8)); }
    private static byte[] jsonBytes(JSONObject json) { return json.toString().getBytes(UTF_8); }
    private static JSONObject copy(JSONObject json) throws Exception { return new JSONObject(json.toString()); }
    private static byte[] digest(byte[] input) throws Exception { return MessageDigest.getInstance("SHA-256").digest(input); }
    private static byte[] bytes(JSONObject json, String key) throws Exception { return Base64.getDecoder().decode(json.getString(key)); }
    private static String encode(byte[] bytes) { return Base64.getEncoder().encodeToString(bytes); }
    private static String newID() { return UUID.randomUUID().toString().toUpperCase(Locale.ROOT); }
    private static String id(String value) throws IOException {
        if (!UUID_PATTERN.matcher(value).matches()) throw damaged();
        return value.toLowerCase(Locale.ROOT);
    }
    private static String requireID(String value) throws IOException {
        if (value == null) throw new IOException("请选择条目。");
        return id(value);
    }
    static boolean isObjectName(String name) {
        return (name.endsWith(".pbop") || name.endsWith(".pbatt")) &&
            UUID_PATTERN.matcher(name.substring(0, name.lastIndexOf('.'))).matches() &&
            name.equals(name.toLowerCase(Locale.ROOT));
    }
    private static String hex(byte[] bytes) {
        StringBuilder text = new StringBuilder(bytes.length * 2);
        for (byte value : bytes) text.append(Character.forDigit((value >>> 4) & 15, 16)).append(Character.forDigit(value & 15, 16));
        return text.toString();
    }
    private static IOException damaged() { return new IOException("保险库校验失败。"); }
    private static IOException changed() { return new IOException("保险库或版本已变化，请重新打开。"); }
}
