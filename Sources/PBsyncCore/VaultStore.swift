import Foundation
import CryptoKit

public struct SyncResult: Sendable {
    public let downloaded: Int
    public let uploaded: Int
    public let pending: Int
    public var message: String { "已合并 \(downloaded) 个版本，上传 \(uploaded) 个版本。\(pending > 0 ? "另有 \(pending) 个本地版本待上传。" : "已同步到存储；另一设备是否应用需在该设备确认。")" }
}

public actor VaultStore {
    public let fileURL: URL
    public let deviceID: UUID
    private var header: SpaceHeader
    private var key: SymmetricKey?
    private var state: SpaceState?
    private var lockEpoch = UUID()
    private var syncing = false
    private var migrating = false

    public init(fileURL: URL, deviceID: UUID) throws {
        self.fileURL = fileURL; self.deviceID = deviceID
        let archive = try Coding.decode(Archive.self, from: Data(contentsOf: fileURL))
        try archive.header.validate(); self.header = archive.header
    }
    public static func create(fileURL: URL, name: String, kind: SpaceKind, password: String, deviceID: UUID) throws -> (VaultStore, String) {
        let created = try Crypto.create(password: password)
        let state = SpaceState(name: name, kind: kind)
        try SafeFile.withLock(at: fileURL.appendingPathExtension("lock")) {
            guard !FileManager.default.fileExists(atPath: fileURL.path) else { throw PBError.conflict }
            try SafeFile.write(Coding.encode(Crypto.archive(state, header: created.header, key: created.key)), to: fileURL)
        }
        return (try VaultStore(fileURL: fileURL, deviceID: deviceID), created.recovery)
    }
    public func spaceHeader() -> SpaceHeader { header }
    public func isUnlocked() -> Bool { key != nil }
    public func unlock(password: String) throws {
        let archive = try readArchive()
        let candidateKey = try Crypto.unlock(archive.header, password: password)
        let candidateState = try Crypto.restore(archive, key: candidateKey)
        header = archive.header; key = candidateKey; state = candidateState
    }
    public func unlock(deviceKey: Data) throws {
        guard deviceKey.count == 32 else { throw PBError.wrongSecret }
        let archive = try readArchive()
        try archive.header.validate()
        let candidateKey = SymmetricKey(data: deviceKey)
        let candidateState = try Crypto.restore(archive, key: candidateKey)
        header = archive.header; key = candidateKey; state = candidateState
    }
    public func deviceUnlockKey() throws -> Data {
        guard let key else { throw PBError.locked }
        return key.withUnsafeBytes { Data($0) }
    }
    public func recover(secret: String) throws {
        let archive = try readArchive()
        let candidateKey = try Crypto.recover(archive.header, recovery: secret)
        let candidateState = try Crypto.restore(archive, key: candidateKey)
        header = archive.header; key = candidateKey; state = candidateState
    }
    public func lock() { lockEpoch = UUID(); key = nil; state = nil }
    public func snapshot() throws -> SpaceState {
        guard let key else { throw PBError.locked }
        let archive = try readArchive()
        guard archive.header == header else { throw PBError.conflict }
        let current = try Crypto.restore(archive, key: key); state = current; return current
    }
    private func readArchive() throws -> Archive { try Coding.decode(Archive.self, from: Data(contentsOf: fileURL)) }
    func transaction<T>(_ edit: (inout SpaceState) throws -> T) throws -> T {
        guard !migrating else { throw PBError.invalid("迁移期间暂不能编辑，请等待位置切换完成。") }
        guard let key else { throw PBError.locked }
        return try SafeFile.withLock(at: fileURL.appendingPathExtension("lock")) {
            let archive = try readArchive()
            guard archive.header == header else { throw PBError.conflict }
            var candidate = try Crypto.restore(archive, key: key)
            let result = try edit(&candidate)
            try SafeFile.write(Coding.encode(Crypto.archive(candidate, header: header, key: key)), to: fileURL)
            state = candidate; return result
        }
    }
    @discardableResult public func save(_ item: Item, deleted: Bool = false, now: Date = Date()) throws -> Revision {
        try transaction { state in
            try append(item, deleted: deleted, now: now, to: &state)
        }
    }
    func append(_ item: Item, deleted: Bool, now: Date, to state: inout SpaceState) throws -> Revision {
        try item.validate(in: state.kind)
        let last = state.revisions.map(\.time).max() ?? LogicalTime(milliseconds: 0)
        let revision = Revision(deviceID: deviceID, time: last.next(now: now), parents: state.history(for: item.id).prefix(1).map(\.id), item: item, deleted: deleted)
        try state.merge([revision])
        return revision
    }

    /// 在同一本地写锁中复核账号和版本，确认框等待期间的修改也受保护。
    public func saveWebsiteLogin(origin: String, username: String, password: String, expected: String, automatic: Bool) throws -> Bool {
        try transaction { state in
            guard state.kind == .vault, CredentialPolicy.origin(origin) == origin else { throw PBError.unauthorized }
            let accounts = state.current.values.filter { !$0.deleted && CredentialPolicy.matches(item: $0.item, pageURL: origin) }
            let matches = accounts.filter { $0.item.fields["username"] == username }
            guard matches.count <= 1, !automatic || accounts.count == matches.count else { throw PBError.conflict }
            guard (matches.first?.id.uuidString ?? "new") == expected else { throw PBError.conflict }
            if let old = matches.first, old.item.fields["password"] == password { return false }
            var item = matches.first?.item ?? Item(kind: .login, title: URL(string: origin)?.host ?? origin, urls: [origin])
            item.fields["username"] = username
            item.fields["password"] = password
            _ = try append(item, deleted: false, now: Date(), to: &state)
            return true
        }
    }
    public func importItems(_ items: [Item], bookmarkBaselines: [String: BrowserBookmarkBaseline] = [:]) throws -> Int {
        try transaction { state in
            guard bookmarkBaselines.isEmpty || state.kind == .bookmarks else { throw PBError.unsupported }
            var changed = 0
            var clock = state.revisions.map(\.time).max() ?? LogicalTime(milliseconds: 0)
            var revisions: [Revision] = []
            let current = state.current
            guard Set(items.map(\.id)).count == items.count else { throw PBError.invalid("导入文件包含重复的对象身份。") }
            for proposed in items {
                var item = proposed
                if let baseline = bookmarkBaselines[item.id.uuidString.lowercased()],
                   let old = current[item.id], !old.deleted {
                    item = baseline.applying(proposed, to: old.item)
                }
                try item.validate(in: state.kind)
                if let old = current[item.id], old.item == item, !old.deleted { continue }
                clock = clock.next()
                revisions.append(Revision(deviceID: deviceID, time: clock, parents: current[item.id].map { [$0.id] } ?? [], item: item))
                changed += 1
            }
            try state.merge(revisions); return changed
        }
    }
    public func delete(_ id: UUID) throws -> Int {
        try transaction { state in
            let live = state.current
            guard let target = live[id], !target.deleted else { throw PBError.invalid("条目不存在或已在回收站。") }
            var ids: Set<UUID> = [id]
            if target.item.kind == .folder {
                var growing = true
                while growing {
                    growing = false
                    for item in state.items where item.parentID.map(ids.contains) == true && !ids.contains(item.id) { ids.insert(item.id); growing = true }
                }
            }
            var clock = state.revisions.map(\.time).max() ?? LogicalTime(milliseconds: 0)
            let revisions = ids.sorted { $0.uuidString < $1.uuidString }.compactMap { itemID -> Revision? in
                guard let old = live[itemID], !old.deleted else { return nil }
                clock = clock.next(); return Revision(deviceID: deviceID, time: clock, parents: [old.id], item: old.item, deleted: true)
            }
            try state.merge(revisions); return revisions.count
        }
    }
    public func restore(_ revisionID: UUID) throws {
        let snapshot = try snapshot()
        guard let revision = snapshot.revisions.first(where: { $0.id == revisionID }) else { throw PBError.invalid("历史版本不存在。") }
        _ = try save(revision.item)
    }
    // 新增的大附件使用独立密文。引用随条目认证，跨库不能关联文件名或内容。
    private func objectName(_ attachment: Attachment) -> String {
        attachment.id.uuidString.lowercased() + ".pbatt"
    }
    private func attachmentURL(_ attachment: Attachment) -> URL {
        fileURL.appendingPathExtension("attachments").appendingPathComponent(objectName(attachment))
    }
    private func openAttachment(_ data: Data, _ ref: Attachment, _ key: SymmetricKey) throws -> Data {
        let clear = try Crypto.open(data, key:key, context:header.context(objectName(ref)))
        guard clear.count == ref.remoteSize, Crypto.digest(clear) == ref.digest else { throw PBError.damaged }
        return clear
    }
    public func attachedItem(_ item: Item) throws -> Item {
        guard let key else { throw PBError.locked }
        var result = item
        for index in result.attachments.indices {
            var ref = result.attachments[index]
            guard ref.remoteSize == nil, ref.data.count >= 65536 else { continue }
            try ref.validate()
            let bytes = ref.data; ref.remoteSize = bytes.count; ref.data = Data()
            // 不改变旧历史中同一附件的内容；不同正文必须使用不同对象。
            ref.id = Coding.stableID(ref.id.uuidString + ":" + ref.digest + ":" + header.spaceID.uuidString)
            let sealed = try Crypto.seal(bytes,key:key,context:header.context(objectName(ref)))
            try SafeFile.write(sealed,to:attachmentURL(ref))
            result.attachments[index] = ref
        }
        return result
    }
    public func attachmentBytes(_ ref: Attachment, storage: (any ObjectStorage)? = nil) async throws -> Data {
        guard let key else { throw PBError.locked }
        try ref.validate()
        guard ref.remoteSize != nil else { return ref.data }
        if let cached = try? Data(contentsOf:attachmentURL(ref)), let bytes = try? openAttachment(cached,ref,key) { return bytes }
        guard let storage else { throw PBError.invalid("此附件还未下载，请连接原同步位置。") }
        let epoch = lockEpoch
        let sealed = try await storage.read(objectName(ref)).data
        guard epoch == lockEpoch, self.key != nil else { throw PBError.locked }
        let bytes = try openAttachment(sealed,ref,key)
        try SafeFile.write(sealed,to:attachmentURL(ref)); return bytes
    }
    private func completeState(_ state: SpaceState, storage: (any ObjectStorage)?) async throws -> SpaceState {
        // 展开前先约束历史正文总量，避免生成超出恢复上限的中间副本。
        var total = 0
        for rev in state.revisions {
            for ref in rev.item.attachments { total += ref.remoteSize ?? ref.data.count }
            guard total <= 72 * 1024 * 1024 else { throw PBError.invalid("历史附件展开后超过当前完整备份上限。") }
        }
        var full = state
        for i in full.revisions.indices {
            for j in full.revisions[i].item.attachments.indices {
                var ref = full.revisions[i].item.attachments[j]
                if ref.remoteSize != nil {
                    ref.data = try await attachmentBytes(ref,storage:storage); ref.remoteSize = nil
                    full.revisions[i].item.attachments[j] = ref
                }
            }
        }
        return full
    }
    public func exportArchive(storage: (any ObjectStorage)? = nil) async throws -> Data {
        guard let key else { throw PBError.locked }
        let epoch = lockEpoch, current = try snapshot()
        let full = try await completeState(current,storage:storage)
        guard epoch == lockEpoch, self.key != nil else { throw PBError.locked }
        let bytes = try Coding.encode(Crypto.archive(full,header:header,key:key))
        guard bytes.count <= 128*1024*1024 else { throw PBError.invalid("完整备份超过当前可恢复大小。") }
        return bytes
    }
    public func restoreBackup(_ data: Data) throws -> Int {
        guard let key else { throw PBError.locked }
        let archive = try Coding.decode(Archive.self, from: data)
        guard archive.header.spaceID == header.spaceID, archive.header.keyEpoch == header.keyEpoch else { throw PBError.invalid("备份不属于当前数据空间。") }
        let old = try Crypto.restore(archive, key: key)
        // 历史与删除先完整保存；恢复当前条目作为新操作传播。
        try transaction { state in try state.merge(old.revisions) }
        return try importItems(old.items)
    }
    public func changePassword(_ password: String, storage: (any ObjectStorage)? = nil) async throws {
        guard !syncing, let key else { throw PBError.locked }
        syncing = true; defer { syncing = false }
        let epoch = lockEpoch, current = try snapshot()
        let candidate = try Crypto.rewrap(header, key: key, newPassword: password)
        if let storage {
            let remote = try await storage.read("space.pbsync")
            let archive = try Coding.decode(Archive.self, from: remote.data)
            guard archive.header == header, let version = remote.version else { throw PBError.conflict }
            _ = try Crypto.restore(archive, key: key)
            var names = try await storage.list()
            try await uploadAttachments(current.revisions,to:storage,names:&names)
            guard epoch == lockEpoch else { throw PBError.locked }
            let data = try Coding.encode(Crypto.archive(current, header: candidate, key: key))
            try await storage.replace("space.pbsync", data: data, version: version)
        }
        try SafeFile.withLock(at: fileURL.appendingPathExtension("lock")) {
            let latest = try Crypto.restore(readArchive(), key: key)
            try SafeFile.write(Coding.encode(Crypto.archive(latest, header: candidate, key: key)), to: fileURL)
            header = candidate; state = latest
        }
    }
    public func synchronize(with storage: any ObjectStorage) async throws -> SyncResult {
        guard !syncing else { throw PBError.invalid("当前同步尚未结束。") }
        guard let key else { throw PBError.locked }
        syncing = true; defer { syncing = false }
        let before = try snapshot()
        var names = try await storage.list()
        if !names.contains("space.pbsync") {
            guard names.allSatisfy({ $0.hasSuffix(".pbatt") }) else { throw PBError.invalid("远端缺少空间文件，未创建空库覆盖现有内容。") }
            try await uploadAttachments(before.revisions, to:storage, names:&names)
            do { try await storage.create("space.pbsync", data: Coding.encode(Crypto.archive(before,header:header,key:key))) }
            catch PBError.conflict { /* 另一设备已创建，随后读取并校验。 */ }
        }
        let remote = try Coding.decode(Archive.self, from: await storage.read("space.pbsync").data)
        guard remote.header == header else { throw PBError.invalid("远端密钥保护或空间身份已变更，请重新解锁／连接。") }
        let remoteState = try Crypto.restore(remote, key: key)
        guard !remoteState.retired else { throw PBError.invalid("此同步位置已冻结，请从新位置重新连接；本机未上传修改仍保留。") }
        guard remoteState.kind == before.kind, remoteState.generation == before.generation else { throw PBError.conflict }
        names = try await storage.list()
        var incoming = remoteState.revisions
        var remoteIDs = Set(incoming.map(\.id))
        // 即使已存在本地也认证远端对象，检测同 ID 被替换或损坏。
        for name in names where name.hasSuffix(".pbop") {
            let object = try Coding.decode(EncryptedObject.self, from: await storage.read(name).data)
            guard name == object.id.uuidString.lowercased() + ".pbop" else { throw PBError.damaged }
            let revision = try Crypto.decrypt(object, header: header, key: key)
            incoming.append(revision); remoteIDs.insert(revision.id)
        }
        guard self.key != nil else { throw PBError.locked }
        let listed = Set(names)
        guard incoming.allSatisfy({ rev in rev.item.attachments.allSatisfy { $0.remoteSize == nil || listed.contains(objectName($0)) } }) else { throw PBError.damaged }
        let count = try transaction { state -> Int in
            let old = state.revisions.count; try state.merge(incoming); return state.revisions.count - old
        }
        let upload = try snapshot().revisions.filter { !remoteIDs.contains($0.id) }
        try await uploadAttachments(upload, to:storage, names:&names)
        var uploaded = 0
        for revision in upload {
            guard self.key != nil else { throw PBError.locked }
            let name = revision.id.uuidString.lowercased() + ".pbop"
            let data = try Coding.encode(Crypto.encrypt(revision, header: header, key: key))
            do { try await storage.create(name, data: data) }
            catch PBError.conflict {
                let existing = try Coding.decode(EncryptedObject.self, from: await storage.read(name).data)
                guard try Crypto.decrypt(existing, header: header, key: key) == revision else { throw PBError.damaged }
            }
            remoteIDs.insert(revision.id); uploaded += 1
        }
        let pending = try snapshot().revisions.filter { !remoteIDs.contains($0.id) }.count
        return SyncResult(downloaded: count, uploaded: uploaded, pending: pending)
    }
    private func uploadAttachments(_ revisions: [Revision], to storage: any ObjectStorage, names: inout [String]) async throws {
        guard let key else { throw PBError.locked }
        var known = Set(names), verified = Set<String>()
        for revision in revisions {
            for ref in revision.item.attachments where ref.remoteSize != nil {
                let name = objectName(ref)
                guard verified.insert(name).inserted else { continue }
                if known.contains(name) {
                    _ = try openAttachment(try await storage.read(name).data,ref,key)
                    continue
                }
                guard self.key != nil else { throw PBError.locked }
                let bytes = try Data(contentsOf:attachmentURL(ref))
                _ = try openAttachment(bytes,ref,key)
                do { try await storage.create(name,data:bytes) }
                catch PBError.conflict { _ = try openAttachment(try await storage.read(name).data,ref,key) }
                known.insert(name)
            }
        }
        names = known.sorted()
    }
    public static func connect(storage: any ObjectStorage, fileURL: URL, password: String, deviceID: UUID) async throws -> VaultStore {
        let data = try await storage.read("space.pbsync").data
        let archive = try Coding.decode(Archive.self, from: data)
        let key = try Crypto.unlock(archive.header, password: password)
        guard !(try Crypto.restore(archive, key: key)).retired else { throw PBError.invalid("此位置已冻结，请使用新的主要存储位置。") }
        let scratch = fileURL.deletingLastPathComponent().appendingPathComponent(".connect-" + UUID().uuidString)
        try SafeFile.privateDirectory(scratch)
        defer { try? FileManager.default.removeItem(at:scratch) }
        let candidate = scratch.appendingPathComponent("candidate.pbsync")
        try SafeFile.write(data,to:candidate)
        let staged = try VaultStore(fileURL:candidate,deviceID:deviceID)
        try await staged.unlock(password:password); _ = try await staged.synchronize(with:storage)
        try SafeFile.withLock(at:fileURL.appendingPathExtension("lock")) {
            guard !FileManager.default.fileExists(atPath:fileURL.path) else { throw PBError.conflict }
            try SafeFile.write(Data(contentsOf:candidate),to:fileURL)
        }
        let store = try VaultStore(fileURL:fileURL,deviceID:deviceID); try await store.unlock(password:password)
        return store
    }
    /// 新位置必须为空。先验证完整副本，再条件冻结旧位置，最后切换本机。
    /// 换新数据密钥后，旧设备即使保留旧密文，也不能解密新位置的未来修改。
    public func migrate(from source: any ObjectStorage, to destination: any ObjectStorage, newPassword: String) async throws -> String {
        _ = try await synchronize(with: source)
        guard let oldKey = key, !syncing else { throw PBError.locked }
        syncing = true; migrating = true; defer { syncing = false; migrating = false }
        guard try await destination.list().isEmpty else { throw PBError.invalid("迁移目标必须是空的专用目录。") }
        let epoch = lockEpoch, oldHeader = header
        let localArchive = try readArchive()
        var next = try await completeState(Crypto.restore(localArchive, key: oldKey),storage:source)
        let remote = try await source.read("space.pbsync")
        let remoteArchive = try Coding.decode(Archive.self, from: remote.data)
        guard remoteArchive.header == oldHeader, let version = remote.version else { throw PBError.conflict }
        let oldNames = try await source.list()
        let known = Set(next.revisions.map(\.id))
        guard oldNames.filter({ $0.hasSuffix(".pbop") }).allSatisfy({ UUID(uuidString: String($0.dropLast(5))).map(known.contains) == true }) else { throw PBError.conflict }
        next.generation += 1
        let created = try Crypto.create(password: newPassword, spaceID: oldHeader.spaceID, epoch: oldHeader.keyEpoch + 1)
        let newArchive = try Crypto.archive(next, header: created.header, key: created.key)
        try await destination.create("space.pbsync", data: Coding.encode(newArchive))
        let readback = try Coding.decode(Archive.self, from: await destination.read("space.pbsync").data)
        guard try Crypto.restore(readback, key: created.key) == next else { throw PBError.damaged }
        // 并发新上传出现时不冻结旧位置；目标仅作为待处理候选保留。
        guard try await source.list() == oldNames, try readArchive() == localArchive else { throw PBError.conflict }
        guard epoch == lockEpoch, self.key != nil else { throw PBError.locked }
        var retired = next; retired.retired = true
        try await source.replace("space.pbsync", data: Coding.encode(Crypto.archive(retired, header: oldHeader, key: oldKey)), version: version)
        guard epoch == lockEpoch, self.key != nil else { throw PBError.locked }
        try SafeFile.withLock(at: fileURL.appendingPathExtension("lock")) {
            guard try readArchive() == localArchive else { throw PBError.conflict }
            // 切换失败时仍保留本地原库和新位置完整副本，可从任一有效备份恢复。
            try SafeFile.write(Coding.encode(newArchive), to: fileURL)
        }
        header = created.header; key = created.key; state = next
        return created.recovery
    }
}
