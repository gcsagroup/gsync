package org.gcsa.pbsync.android;

import android.app.Activity;
import android.app.AlertDialog;
import android.content.Intent;
import android.hardware.biometrics.BiometricPrompt;
import android.net.Uri;
import android.os.Build;
import android.os.Bundle;
import android.os.CancellationSignal;
import android.os.Handler;
import android.os.Looper;
import android.text.InputType;
import android.text.method.PasswordTransformationMethod;
import android.view.Gravity;
import android.view.View;
import android.view.WindowManager;
import android.widget.Button;
import android.widget.CheckBox;
import android.widget.EditText;
import android.widget.LinearLayout;
import android.widget.ListView;
import android.widget.ScrollView;
import android.widget.TextView;
import org.gcsa.pbsync.DavStorage;
import org.gcsa.pbsync.SpaceSession;
import org.gcsa.pbsync.SpaceSession.Entry;

import java.io.InputStream;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import javax.crypto.Cipher;

import static org.gcsa.pbsync.android.LibraryUi.*;

public final class MainActivity extends Activity {
    private static final int PICK_BACKUP = 21;
    private final ExecutorService worker = Executors.newSingleThreadExecutor();
    private final Handler handler = new Handler(Looper.getMainLooper());
    private final Runnable periodic = new Runnable() {
        @Override public void run() {
            if (dav != null && session != null && !busy && !editing) synchronize(true);
            handler.postDelayed(this, 20_000);
        }
    };
    private SpaceSession session;
    private DavStorage dav;
    private LibraryUi ui;
    private BiometricUnlock biometric;
    private CancellationSignal biometricPrompt;
    private TextView status, count, empty;
    private EditText search;
    private EntryRows rowAdapter;
    private List<Entry> allRows = java.util.Collections.emptyList();
    private final long[] lastSync = new long[2];
    private boolean bookmarks = true;
    private boolean syncPage;
    private boolean trash;
    private boolean busy;
    private boolean editing;
    private String folder;
    private String searchQuery = "";
    private String notice = "";
    private String libraryName = "";

    @Override public void onCreate(Bundle state) {
        super.onCreate(state);
        ui = new LibraryUi(this);
        biometric = new BiometricUnlock(this);
        getWindow().addFlags(WindowManager.LayoutParams.FLAG_DRAWS_SYSTEM_BAR_BACKGROUNDS);
        getWindow().setStatusBarColor(CANVAS);
        getWindow().setNavigationBarColor(SURFACE);
        getWindow().getDecorView().setSystemUiVisibility(
            View.SYSTEM_UI_FLAG_LIGHT_STATUS_BAR | View.SYSTEM_UI_FLAG_LIGHT_NAVIGATION_BAR);
        if (Build.VERSION.SDK_INT >= 33) setRecentsScreenshotEnabled(false);
        show();
    }

    @Override protected void onStart() {
        super.onStart();
        handler.post(periodic);
    }

    @Override protected void onStop() {
        handler.removeCallbacks(periodic);
        cancelBiometric();
        super.onStop();
    }

    @Override protected void onDestroy() {
        handler.removeCallbacks(periodic);
        SpaceSession opening = session;
        worker.execute(() -> { if (opening != null) opening.close(); });
        worker.shutdown();
        super.onDestroy();
    }

    private Path archive() { return archive(bookmarks); }

    private Path archive(boolean collection) {
        return getFilesDir().toPath().resolve(collection ? "bookmarks.pbsync" : "vault.pbsync");
    }

    private String libraryTitle(boolean collection) { return collection ? "收藏夹" : "密码库"; }

    private Icon libraryIcon(boolean collection) { return collection ? Icon.BOOKMARK : Icon.VAULT; }

    private void switchSpace(boolean value) {
        if (busy || (!syncPage && bookmarks == value)) return;
        dismissKeyboard();
        if (bookmarks != value) {
            lock();
            bookmarks = value;
        }
        syncPage = false;
        show();
    }

    private void lock() {
        cancelBiometric();
        if (session != null) session.close();
        session = null;
        dav = null;
        folder = null;
        trash = false;
        searchQuery = "";
        notice = "";
        allRows = java.util.Collections.emptyList();
    }

    private void openSync() {
        if (busy || syncPage) return;
        cancelBiometric();
        dismissKeyboard();
        syncPage = true;
        show();
    }

    private void show() {
        rowAdapter = null;
        search = null;
        LinearLayout screen = ui.column();
        screen.setBackgroundColor(CANVAS);
        screen.setFocusableInTouchMode(true);

        LinearLayout page = ui.column();
        screen.addView(page, new LinearLayout.LayoutParams(-1, 0, 1f));
        page.addView(header());

        if (syncPage) {
            page.addView(scroll(syncContent()), new LinearLayout.LayoutParams(-1, 0, 1f));
        } else if (session == null) {
            page.addView(scroll(lockedContent()), new LinearLayout.LayoutParams(-1, 0, 1f));
        } else {
            try {
                showLibrary(page);
            } catch (Exception error) {
                setStatus(message(error));
            }
        }

        screen.addView(ui.divider());
        LinearLayout navigation = ui.row();
        navigation.setPadding(dp(9), 0, dp(9), 0);
        navigation.setBackgroundColor(SURFACE);
        navigation.addView(ui.nav(Icon.BOOKMARK, "收藏夹", !syncPage && bookmarks,
            () -> switchSpace(true)), new LinearLayout.LayoutParams(0, dp(66), 1));
        navigation.addView(ui.nav(Icon.VAULT, "密码库", !syncPage && !bookmarks,
            () -> switchSpace(false)), new LinearLayout.LayoutParams(0, dp(66), 1));
        navigation.addView(ui.nav(Icon.SYNC, "同步", syncPage, this::openSync),
            new LinearLayout.LayoutParams(0, dp(66), 1));
        screen.addView(navigation);
        setContentView(screen);
        screen.requestFocus();
    }

    private View header() {
        LinearLayout header = ui.column();
        header.setPadding(dp(22), dp(8), dp(22), dp(17));
        LinearLayout brand = ui.row();
        brand.addView(ui.badge(Icon.SHIELD, 19, SURFACE, ACCENT),
            new LinearLayout.LayoutParams(dp(33), dp(33)));
        TextView wordmark = ui.text("PBsync", 17, INK, true);
        LinearLayout.LayoutParams name = new LinearLayout.LayoutParams(0, -2, 1);
        name.leftMargin = dp(9);
        brand.addView(wordmark, name);
        if (session != null && !syncPage) {
            Button lock = ui.button("锁定", false, () -> {
                if (busy) return;
                dismissKeyboard();
                lock();
                show();
            });
            brand.addView(lock, new LinearLayout.LayoutParams(-2, dp(46)));
        }
        header.addView(brand, new LinearLayout.LayoutParams(-1, dp(46)));

        String heading = syncPage ? "同步与连接" : trash ? "回收站" : libraryTitle(bookmarks);
        TextView title = ui.text(heading, 33, INK, true);
        title.setAccessibilityHeading(true);
        LinearLayout.LayoutParams titleSize = new LinearLayout.LayoutParams(-1, -2);
        titleSize.topMargin = dp(7);
        header.addView(title, titleSize);

        status = ui.text("", 14, MUTED, false);
        status.setAccessibilityLiveRegion(View.ACCESSIBILITY_LIVE_REGION_POLITE);
        status.setPadding(0, dp(4), 0, 0);
        header.addView(status, new LinearLayout.LayoutParams(-1, -2));
        updateStatus();
        return header;
    }

    private void updateStatus() {
        if (status == null) return;
        String label = notice;
        if (label.isEmpty() && !syncPage && session != null) {
            label = libraryName;
            if (dav != null) label += "  ·  WebDAV";
        }
        status.setText(label);
        status.setVisibility(label.isEmpty() ? View.GONE : View.VISIBLE);
    }

    private void setStatus(String label) {
        notice = label;
        updateStatus();
    }

    private LinearLayout paddedContent() {
        LinearLayout view = ui.column();
        view.setPadding(dp(22), 0, dp(22), dp(20));
        return view;
    }

    private ScrollView scroll(View content) {
        ScrollView scroll = new ScrollView(this);
        scroll.setFillViewport(true);
        scroll.addView(content);
        return scroll;
    }

    private void addAction(LinearLayout group, String label, boolean primary, Runnable operation) {
        LinearLayout.LayoutParams p = new LinearLayout.LayoutParams(-1, -2);
        p.topMargin = dp(10);
        group.addView(ui.button(label, primary, operation), p);
    }

    private LinearLayout card() {
        LinearLayout view = ui.column();
        view.setBackground(ui.shape(SURFACE, 21, BORDER));
        view.setPadding(dp(17), dp(16), dp(17), dp(17));
        return view;
    }

    private View lockedContent() {
        LinearLayout content = paddedContent();
        LinearLayout panel = card();
        boolean local = Files.exists(archive());
        boolean quick = local && biometric.configured(bookmarks) && biometric.available();
        panel.addView(ui.badge(local ? Icon.LOCK : libraryIcon(bookmarks), 26, ACCENT, TINT),
            new LinearLayout.LayoutParams(dp(51), dp(51)));
        TextView heading = ui.text(local ? "本机副本已锁定" : "打开加密空间", 21, INK, true);
        heading.setPadding(0, dp(12), 0, dp(5));
        panel.addView(heading);
        String instructions = !local ? "连接已有的 WebDAV 空间，或从 .pbsync 备份恢复。"
            : quick ? "使用此设备的指纹或受支持的人脸识别。"
            : "输入主密码或恢复密钥，继续查看" + libraryTitle(bookmarks) + "。";
        TextView description = ui.text(instructions, 14, MUTED, false);
        panel.addView(description);
        if (local) {
            if (quick) addAction(panel, "使用生物识别解锁", true, () -> promptBiometric(false));
            addAction(panel, quick ? "使用主密码或恢复密钥" : "解锁本机副本", !quick, () -> unlock(null));
        }
        else {
            addAction(panel, "连接 WebDAV", true, () -> connect(false));
            addAction(panel, "打开加密备份", false, this::pick);
        }
        content.addView(panel, new LinearLayout.LayoutParams(-1, -2));
        return content;
    }

    private View syncContent() {
        LinearLayout content = paddedContent();
        for (boolean collection : new boolean[]{true, false}) {
            boolean current = bookmarks == collection;
            boolean unlocked = current && session != null;
            boolean connected = unlocked && dav != null;
            boolean local = Files.exists(archive(collection));
            LinearLayout panel = card();
            LinearLayout summary = ui.row();
            summary.addView(ui.badge(libraryIcon(collection), 22, ACCENT, TINT),
                new LinearLayout.LayoutParams(dp(43), dp(43)));
            LinearLayout labels = ui.column();
            labels.addView(ui.text(libraryTitle(collection), 17, INK, true));
            labels.addView(ui.text(connected ? "WebDAV 已配置" : unlocked ? "本机副本 · 待连接"
                : local ? "本机副本已锁定" : "尚未连接", 13, MUTED, false));
            LinearLayout.LayoutParams names = new LinearLayout.LayoutParams(0, -2, 1);
            names.leftMargin = dp(12);
            summary.addView(labels, names);
            panel.addView(summary);

            long last = lastSync[collection ? 0 : 1];
            if (last > 0) {
                TextView timestamp = ui.text("上次同步成功 · " +
                    java.text.DateFormat.getDateTimeInstance(java.text.DateFormat.SHORT,
                        java.text.DateFormat.SHORT).format(new java.util.Date(last)), 13, MUTED, false);
                timestamp.setPadding(0, dp(10), 0, 0);
                panel.addView(timestamp);
            }
            addAction(panel, connected ? "立即同步" : unlocked ? "连接 WebDAV" : local ? "打开" + libraryTitle(collection)
                : "设置" + libraryTitle(collection), connected, () -> {
                if (busy) return;
                if (!unlocked) switchSpace(collection);
                else if (!connected) connect(true);
                else synchronize(false);
            });
            if (local && biometric.configured(collection)) {
                addAction(panel, "关闭" + libraryTitle(collection) + "的生物识别解锁", false, () ->
                    work(() -> { biometric.remove(collection); return null; }, ignored -> {
                        setStatus("已关闭本机生物识别解锁");
                        show();
                    }));
            }
            LinearLayout.LayoutParams item = new LinearLayout.LayoutParams(-1, -2);
            item.bottomMargin = dp(12);
            content.addView(panel, item);
        }
        TextView timing = ui.text("保持此应用打开并解锁，已连接的空间会自动同步。", 13, MUTED, false);
        timing.setPadding(dp(4), dp(3), dp(4), dp(10));
        content.addView(timing);
        return content;
    }

    private void showLibrary(LinearLayout page) throws Exception {
        libraryName = session.name();
        updateStatus();
        LinearLayout toolbar = ui.column();
        toolbar.setPadding(dp(22), 0, dp(22), dp(4));
        toolbar.addView(searchBar());
        LinearLayout actions = ui.row();
        actions.setPadding(0, dp(10), 0, dp(7));
        View location = locationControl();
        actions.addView(location, new LinearLayout.LayoutParams(0, -2, 1));
        if (!trash) {
            Button add = ui.button(bookmarks ? "新增收藏" : "新增账号", true,
                () -> edit(null, bookmarks ? "bookmark" : "login"));
            LinearLayout.LayoutParams p = new LinearLayout.LayoutParams(-2, -2);
            p.leftMargin = dp(7);
            actions.addView(add, p);
        }
        actions.addView(ui.iconButton(Icon.MORE, "空间操作", this::showSpaceActions),
            new LinearLayout.LayoutParams(dp(48), dp(48)));
        toolbar.addView(actions);
        count = ui.text("", 13, MUTED, false);
        count.setPadding(0, 0, 0, dp(8));
        toolbar.addView(count);
        page.addView(toolbar);

        android.widget.FrameLayout listShell = new android.widget.FrameLayout(this);
        ListView list = new ListView(this);
        list.setDivider(null);
        list.setPadding(dp(22), 0, dp(22), dp(12));
        list.setClipToPadding(false);
        list.setItemsCanFocus(true);
        list.setVerticalScrollBarEnabled(false);
        rowAdapter = new EntryRows();
        list.setAdapter(rowAdapter);
        listShell.addView(list, new android.widget.FrameLayout.LayoutParams(-1, -1));
        empty = ui.text("", 15, MUTED, false);
        empty.setGravity(Gravity.CENTER);
        empty.setPadding(dp(26), dp(10), dp(26), dp(34));
        listShell.addView(empty, new android.widget.FrameLayout.LayoutParams(-1, -1));
        page.addView(listShell, new LinearLayout.LayoutParams(-1, 0, 1));
        refreshRows();
    }

    private View locationControl() throws Exception {
        if (trash) {
            return ui.button("返回条目", false, () -> {
                if (busy) return;
                trash = false;
                searchQuery = "";
                show();
            });
        }
        if (folder == null) return ui.text(bookmarks ? "全部收藏" : "登录条目", 16, INK, true);
        Entry current = session.detail(folder);
        LinearLayout location = ui.row();
        TextView caret = ui.icon(Icon.LEFT, 21, ACCENT);
        location.addView(caret, new LinearLayout.LayoutParams(dp(25), dp(46)));
        TextView label = ui.text(current.title(), 15, ACCENT, true);
        label.setSingleLine(true);
        label.setEllipsize(android.text.TextUtils.TruncateAt.END);
        location.addView(label, new LinearLayout.LayoutParams(0, -2, 1));
        location.setMinimumHeight(dp(46));
        location.setContentDescription("返回上一级，共享目录 " + current.title());
        location.setOnClickListener(view -> changeFolder(current.parent()));
        location.setBackground(ui.ripple(CANVAS, 13, 0));
        return location;
    }

    private View searchBar() {
        LinearLayout container = ui.row();
        container.setBackground(ui.shape(SURFACE, 15, BORDER));
        container.setPadding(dp(12), 0, dp(3), 0);
        container.addView(ui.icon(Icon.SEARCH, 21, MUTED), new LinearLayout.LayoutParams(dp(28), dp(48)));
        search = new EditText(this);
        search.setTextSize(15);
        search.setSingleLine(true);
        search.setTextColor(INK);
        search.setHintTextColor(MUTED);
        search.setPadding(dp(4), 0, 0, 0);
        search.setBackgroundColor(android.graphics.Color.TRANSPARENT);
        search.setInputType(InputType.TYPE_CLASS_TEXT | InputType.TYPE_TEXT_FLAG_NO_SUGGESTIONS);
        search.setImportantForAutofill(View.IMPORTANT_FOR_AUTOFILL_NO);
        search.setHint(bookmarks ? "搜索标题、网址" : "搜索标题、用户名或网址");
        search.setText(searchQuery);
        container.addView(search, new LinearLayout.LayoutParams(0, dp(50), 1));
        TextView clear = ui.iconButton(Icon.CLOSE, "清除搜索", () -> search.setText(""));
        clear.setVisibility(searchQuery.isEmpty() ? View.GONE : View.VISIBLE);
        container.addView(clear, new LinearLayout.LayoutParams(dp(48), dp(48)));
        search.addTextChangedListener(new android.text.TextWatcher() {
            public void beforeTextChanged(CharSequence text, int start, int count, int after) {}
            public void onTextChanged(CharSequence text, int start, int before, int count) {
                searchQuery = text.toString();
                clear.setVisibility(text.length() == 0 ? View.GONE : View.VISIBLE);
                filterRows();
            }
            public void afterTextChanged(android.text.Editable text) {}
        });
        return container;
    }

    private void showSpaceActions() {
        if (busy) return;
        List<String> actions = new ArrayList<>();
        if (!trash && bookmarks) actions.add("新建文件夹");
        actions.add(trash ? "返回条目" : "回收站");
        actions.add("同步与连接");
        new AlertDialog.Builder(this).setTitle(libraryTitle(bookmarks))
            .setItems(actions.toArray(new String[0]), (dialog, which) -> {
                String action = actions.get(which);
                if (action.equals("新建文件夹")) edit(null, "folder");
                else if (action.equals("同步与连接")) openSync();
                else {
                    trash = !trash;
                    searchQuery = "";
                    dismissKeyboard();
                    show();
                }
            }).show();
    }

    private void changeFolder(String id) {
        if (busy) return;
        dismissKeyboard();
        folder = id;
        searchQuery = "";
        show();
    }

    private void refreshRows() throws Exception {
        if (rowAdapter == null) return;
        allRows = session.entries(trash);
        filterRows();
    }

    private void filterRows() {
        if (rowAdapter == null) return;
        String query = searchQuery.trim().toLowerCase(java.util.Locale.ROOT);
        List<Entry> visible = new ArrayList<>();
        for (Entry entry : allRows) {
            if (query.isEmpty()) {
                if (!trash && !java.util.Objects.equals(folder, entry.parent())) continue;
            } else {
                String words = (entry.title() + "\n" + entry.url() + "\n" + entry.username())
                    .toLowerCase(java.util.Locale.ROOT);
                if (!words.contains(query)) continue;
            }
            visible.add(entry);
        }
        rowAdapter.rows = visible;
        rowAdapter.notifyDataSetChanged();
        count.setText(query.isEmpty() ? visible.size() + " 项" : "找到 " + visible.size() + " 项");
        empty.setText(!query.isEmpty() ? "没有匹配的条目" : trash ? "回收站为空" : "此处还没有条目");
        empty.setVisibility(visible.isEmpty() ? View.VISIBLE : View.GONE);
    }

    private void dismissKeyboard() {
        View focused = getCurrentFocus();
        if (focused != null) getSystemService(android.view.inputmethod.InputMethodManager.class)
            .hideSoftInputFromWindow(focused.getWindowToken(), 0);
    }

    @Override public void onBackPressed() {
        if (busy) return;
        if (syncPage || trash || folder != null || !searchQuery.isEmpty()) {
            dismissKeyboard();
            if (syncPage) syncPage = false;
            else if (!searchQuery.isEmpty()) searchQuery = "";
            else if (trash) trash = false;
            else {
                try { folder = session.detail(folder).parent(); }
                catch (Exception error) { folder = null; }
            }
            show();
        } else super.onBackPressed();
    }

    private final class EntryRows extends android.widget.BaseAdapter {
        List<Entry> rows = java.util.Collections.emptyList();

        @Override public int getCount() { return rows.size(); }
        @Override public Entry getItem(int position) { return rows.get(position); }
        @Override public long getItemId(int position) { return position; }

        @Override public View getView(int position, View view, android.view.ViewGroup parent) {
            Entry row = getItem(position);
            ItemRow holder = view == null ? new ItemRow() : (ItemRow) view.getTag();
            holder.bind(row);
            return holder.shell;
        }
    }

    private final class ItemRow {
        final LinearLayout shell = ui.column();
        final LinearLayout open = ui.row();
        final LinearLayout labels = ui.column();
        final TextView title = ui.text("", 16, INK, true);
        final TextView detail = ui.text("", 13, MUTED, false);
        final TextView icon = ui.badge(Icon.BOOKMARK, 21, ACCENT, TINT);
        Entry item;
        final TextView menu = ui.iconButton(Icon.MORE, "", () -> choose(item));

        ItemRow() {
            LinearLayout row = ui.row();
            row.setBackground(ui.shape(SURFACE, 17, BORDER));
            open.setMinimumHeight(dp(70));
            open.setPadding(dp(12), dp(9), dp(5), dp(9));
            open.setBackground(ui.ripple(0x00000000, 16, 0));
            open.setFocusable(true);
            open.setOnClickListener(view -> {
                if (busy) return;
                if (trash) choose(item);
                else if (item.kind().equals("folder")) changeFolder(item.id());
                else edit(item, item.kind());
            });
            open.addView(icon, new LinearLayout.LayoutParams(dp(43), dp(43)));
            title.setSingleLine(true);
            title.setEllipsize(android.text.TextUtils.TruncateAt.END);
            detail.setSingleLine(true);
            detail.setEllipsize(android.text.TextUtils.TruncateAt.END);
            labels.addView(title);
            labels.addView(detail);
            LinearLayout.LayoutParams text = new LinearLayout.LayoutParams(0, -2, 1);
            text.leftMargin = dp(11);
            open.addView(labels, text);
            row.addView(open, new LinearLayout.LayoutParams(0, -2, 1));
            row.addView(menu, new LinearLayout.LayoutParams(dp(48), dp(50)));
            LinearLayout.LayoutParams item = new LinearLayout.LayoutParams(-1, -2);
            item.bottomMargin = dp(7);
            shell.addView(row, item);
            shell.setTag(this);
        }

        void bind(Entry value) {
            item = value;
            Icon emblem = item.kind().equals("folder") ? Icon.FOLDER
                : item.kind().equals("login") ? Icon.ACCOUNT : bookmarks ? Icon.WEBSITE : Icon.FILE;
            icon.setText(new String(Character.toChars(emblem.code)));
            title.setText(item.title());
            String sub = item.kind().equals("folder") ? "文件夹"
                : item.kind().equals("login") && !item.username().isEmpty() ? item.username() : item.url();
            detail.setText(sub);
            detail.setVisibility(sub.isEmpty() ? View.GONE : View.VISIBLE);
            open.setContentDescription(item.title() + (sub.isEmpty() ? "" : "，" + sub));
            menu.setContentDescription(item.title() + " · 更多操作");
        }
    }

    private void pick() {
        if (busy) return;
        Intent intent = new Intent(Intent.ACTION_OPEN_DOCUMENT).addCategory(Intent.CATEGORY_OPENABLE).setType("*/*");
        startActivityForResult(intent, PICK_BACKUP);
    }

    @Override protected void onActivityResult(int request, int result, Intent data) {
        super.onActivityResult(request, result, data);
        if (request == PICK_BACKUP && result == RESULT_OK && data != null && data.getData() != null) unlock(data.getData());
    }

    private void unlock(Uri backup) {
        if (busy || biometricPrompt != null) return;
        LinearLayout fields = fields();
        EditText secret = input("主密码或恢复密钥", "", true);
        CheckBox recovery = new CheckBox(this);
        recovery.setText("使用恢复密钥");
        addField(fields, secret, "解锁材料");
        fields.addView(recovery);
        CheckBox enableBiometric = new CheckBox(this);
        if (backup == null && biometric.available() && !biometric.configured(bookmarks)) {
            enableBiometric.setText("在此设备启用生物识别解锁");
            fields.addView(enableBiometric);
            recovery.setOnCheckedChangeListener((button, checked) -> {
                if (checked) enableBiometric.setChecked(false);
                enableBiometric.setEnabled(!checked);
            });
        }
        AlertDialog dialog = new AlertDialog.Builder(this).setTitle("解锁保险库").setView(scroll(fields))
            .setNegativeButton("取消", null).setPositiveButton("解锁", (d, which) -> {
                char[] password = secret.getText().toString().toCharArray();
                secret.getText().clear();
                boolean useRecovery = recovery.isChecked();
                boolean enable = enableBiometric.isChecked() && !useRecovery;
                Path file = archive();
                work(() -> {
                    try {
                        if (backup == null) return checkSpace(SpaceSession.openLocal(file, password, useRecovery));
                        try (InputStream stream = getContentResolver().openInputStream(backup)) {
                            if (stream == null) throw new java.io.IOException("无法打开选中的文件。");
                            byte[] bytes = SpaceSession.readLimited(stream, 128 * 1024 * 1024);
                            return SpaceSession.restore(file, bytes, password, useRecovery, bookmarks);
                        }
                    } finally { Arrays.fill(password, '\0'); }
                }, opened -> {
                    session = opened;
                    notice = "";
                    show();
                    if (enable) promptBiometric(true);
                });
            }).create();
        protect(dialog);
    }

    private void cancelBiometric() {
        CancellationSignal pending = biometricPrompt;
        biometricPrompt = null;
        if (pending != null) pending.cancel();
    }

    private void promptBiometric(boolean enable) {
        if (busy || biometricPrompt != null || (session != null) != enable) return;
        boolean collection = bookmarks;
        SpaceSession opened = session;
        CancellationSignal signal = new CancellationSignal();
        try {
            Cipher cipher = enable ? biometric.encryption(collection) : biometric.decryption(collection);
            biometricPrompt = signal;
            biometric.authenticate(enable ? "启用生物识别解锁" : "解锁" + libraryTitle(collection), cipher, signal,
                () -> { if (biometricPrompt == signal) cancelBiometric(); },
                new BiometricPrompt.AuthenticationCallback() {
                    @Override public void onAuthenticationError(int code, CharSequence message) {
                        if (biometricPrompt != signal) return;
                        biometricPrompt = null;
                        if (code != BiometricPrompt.BIOMETRIC_ERROR_CANCELED
                                && code != BiometricPrompt.BIOMETRIC_ERROR_USER_CANCELED) {
                            setStatus("生物识别未完成，可使用主密码或恢复密钥。");
                        }
                    }
                    @Override public void onAuthenticationSucceeded(BiometricPrompt.AuthenticationResult result) {
                        if (biometricPrompt != signal || isDestroyed()) return;
                        biometricPrompt = null;
                        Cipher verified = result.getCryptoObject() == null ? null : result.getCryptoObject().getCipher();
                        if (verified == null || bookmarks != collection || session != opened) return;
                        completeBiometric(enable, collection, opened, verified);
                    }
                });
        } catch (Exception error) {
            if (biometricPrompt == signal) cancelBiometric();
            setStatus(enable ? "本机无法启用生物识别解锁。"
                : "本机生物识别密钥不可用。请使用主密码解锁，或从同步页关闭后重新启用。");
        }
    }

    private void completeBiometric(boolean enable, boolean collection, SpaceSession opened, Cipher cipher) {
        work(() -> {
            byte[] key = null;
            try {
                key = enable ? opened.deviceKey() : biometric.read(collection, cipher);
                if (enable) {
                    biometric.save(collection, cipher, key);
                    return opened;
                }
                return checkSpace(SpaceSession.openWithDeviceKey(archive(collection), key));
            } catch (Exception error) {
                throw new java.io.IOException(enable ? "本机未能保存生物识别设置。"
                    : "生物识别无法打开此副本，请使用主密码或恢复密钥。");
            } finally {
                if (key != null) Arrays.fill(key, (byte) 0);
            }
        }, result -> {
            session = result;
            notice = enable ? "已启用本机生物识别解锁" : "";
            show();
        });
    }

    private void connect(boolean existing) {
        if (busy) return;
        LinearLayout fields = fields();
        EditText address = input("HTTPS WebDAV 目录", "", false);
        EditText user = input("WebDAV 用户名", "", false);
        EditText secret = input("WebDAV 密码", "", true);
        EditText master = input("保险库主密码", "", true);
        addField(fields, address, "WebDAV 目录");
        addField(fields, user, "用户名");
        addField(fields, secret, "WebDAV 密码");
        if (!existing) addField(fields, master, "保险库主密码");
        AlertDialog dialog = new AlertDialog.Builder(this).setTitle("连接 WebDAV").setView(scroll(fields))
            .setNegativeButton("取消", null).setPositiveButton("连接", (d, which) -> {
                char[] password = secret.getText().toString().toCharArray();
                char[] vaultPassword = master.getText().toString().toCharArray();
                String url = address.getText().toString(), name = user.getText().toString();
                secret.getText().clear();
                master.getText().clear();
                Path file = archive();
                SpaceSession current = session;
                work(() -> {
                    try {
                        DavStorage storage = new DavStorage(url, name, password);
                        if (existing) {
                            current.sync(storage);
                            return new Connection(current, storage);
                        }
                        return new Connection(SpaceSession.connect(file, storage, vaultPassword, bookmarks), storage);
                    } finally {
                        Arrays.fill(password, '\0');
                        Arrays.fill(vaultPassword, '\0');
                    }
                }, connection -> {
                    session = connection.session();
                    dav = connection.dav();
                    lastSync[bookmarks ? 0 : 1] = System.currentTimeMillis();
                    setStatus("WebDAV 已连接");
                    show();
                });
            }).create();
        protect(dialog);
    }

    private SpaceSession checkSpace(SpaceSession opened) throws Exception {
        if (opened.bookmarks() == bookmarks) return opened;
        opened.close();
        throw new java.io.IOException("请选择与此备份类型对应的空间。");
    }

    private void synchronize(boolean silent) {
        if (busy || dav == null || session == null) return;
        SpaceSession current = session;
        DavStorage storage = dav;
        work(() -> current.sync(storage), result -> {
            lastSync[bookmarks ? 0 : 1] = System.currentTimeMillis();
            if (!silent || result.downloaded() > 0 || result.uploaded() > 0) {
                setStatus("同步完成 · 接收 " + result.downloaded() + " · 上传 " + result.uploaded());
            }
            try {
                if (syncPage) show();
                else if (result.downloaded() > 0) refreshRows();
            } catch (Exception error) { setStatus(message(error)); }
        }, !silent);
    }

    private void choose(Entry row) {
        if (busy) return;
        List<String> actions = new ArrayList<>();
        List<Runnable> operations = new ArrayList<>();
        if (trash) {
            actions.add("恢复条目");
            operations.add(() -> mutate(() -> session.restoreItem(row.id())));
        } else {
            if (row.kind().equals("folder")) {
                actions.add("打开文件夹");
                operations.add(() -> changeFolder(row.id()));
            }
            actions.add(row.editable() ? "查看与编辑" : "查看条目");
            operations.add(() -> edit(row, row.kind()));
            if (bookmarks) {
                actions.add("上移");
                operations.add(() -> mutate(() -> session.move(row.id(), -1)));
                actions.add("下移");
                operations.add(() -> mutate(() -> session.move(row.id(), 1)));
            }
            actions.add("移到回收站");
            operations.add(() -> new AlertDialog.Builder(this).setTitle("移到回收站？")
                .setMessage(row.title()).setNegativeButton("取消", null)
                .setPositiveButton("移到回收站", (d, w) -> mutate(() -> session.delete(row.id()))).show());
        }
        new AlertDialog.Builder(this).setTitle(row.title())
            .setItems(actions.toArray(new String[0]), (d, w) -> operations.get(w).run()).show();
    }

    private void edit(Entry selected, String kind) {
        if (busy) return;
        try {
            Entry row = selected == null ? null : session.detail(selected.id());
            LinearLayout fields = fields();
            EditText title = input("标题", row == null ? "" : row.title(), false);
            EditText url = input("网址", row == null ? "" : row.url(), false);
            EditText username = input("用户名", row == null ? "" : row.username(), false);
            EditText password = input("密码", row == null ? "" : row.password(), true);
            EditText notes = input("备注", row == null ? "" : row.notes(), false);
            addField(fields, title, "标题");
            if (!kind.equals("folder")) addField(fields, url, "网址");
            if (kind.equals("login")) {
                addField(fields, username, "用户名");
                addField(fields, password, "密码");
                CheckBox reveal = new CheckBox(this);
                reveal.setText("显示密码");
                reveal.setOnCheckedChangeListener((view, checked) -> password.setTransformationMethod(
                    checked ? null : PasswordTransformationMethod.getInstance()));
                fields.addView(reveal);
            }
            notes.setSingleLine(false);
            notes.setInputType(InputType.TYPE_CLASS_TEXT | InputType.TYPE_TEXT_FLAG_MULTI_LINE);
            notes.setMaxLines(4);
            addField(fields, notes, "备注");
            List<Entry> folders = new ArrayList<>();
            android.widget.Spinner destination = new android.widget.Spinner(this);
            if (bookmarks) {
                List<String> names = new ArrayList<>();
                names.add("根目录");
                int current = 0;
                String selectedParent = row == null ? folder : row.parent();
                for (Entry entry : session.entries(false)) {
                    if (!entry.kind().equals("folder") || (row != null && row.id().equals(entry.id()))) continue;
                    folders.add(entry);
                    names.add(entry.title());
                    if (entry.id().equals(selectedParent)) current = names.size() - 1;
                }
                destination.setAdapter(new android.widget.ArrayAdapter<>(this, android.R.layout.simple_spinner_dropdown_item, names));
                destination.setSelection(current);
                fields.addView(ui.text("所在目录", 13, MUTED, true));
                fields.addView(destination);
            }
            AlertDialog.Builder builder = new AlertDialog.Builder(this).setTitle(row == null ? "新建条目" : row.title())
                .setView(scroll(fields)).setNegativeButton("关闭", null);
            if (row == null || row.editable()) builder.setPositiveButton("保存", (dialog, which) -> {
                int index = destination.getSelectedItemPosition() - 1;
                String parent = index >= 0 ? folders.get(index).id() : null;
                String name = title.getText().toString(), link = url.getText().toString();
                String account = username.getText().toString(), value = password.getText().toString(), memo = notes.getText().toString();
                password.getText().clear();
                mutate(() -> session.save(row == null ? null : row.id(), kind, name, link, account, value, memo, parent));
            });
            else for (int i = 0; i < fields.getChildCount(); i++) fields.getChildAt(i).setEnabled(false);
            protect(builder.create());
        } catch (Exception error) { setStatus(message(error)); }
    }

    private void mutate(Mutation action) {
        work(() -> { action.run(); return null; }, ignored -> {
            setStatus("已保存");
            show();
            if (dav != null) synchronize(true);
        });
    }

    private <T> void work(Task<T> action, java.util.function.Consumer<T> done) {
        work(action, done, true);
    }

    private <T> void work(Task<T> action, java.util.function.Consumer<T> done, boolean showProgress) {
        if (busy) return;
        busy = true;
        if (showProgress) setStatus("正在处理…");
        worker.execute(() -> {
            try {
                T result = action.run();
                runOnUiThread(() -> {
                    busy = false;
                    if (!isDestroyed()) done.accept(result);
                    else if (result instanceof SpaceSession opened) opened.close();
                    else if (result instanceof Connection connection) connection.session().close();
                });
            } catch (Exception error) {
                runOnUiThread(() -> {
                    busy = false;
                    if (!isDestroyed()) setStatus(message(error));
                });
            }
        });
    }

    private void protect(AlertDialog dialog) {
        editing = true;
        dialog.setOnDismissListener(d -> editing = false);
        dialog.show();
        dialog.getWindow().addFlags(WindowManager.LayoutParams.FLAG_SECURE);
    }

    private String message(Exception error) {
        if (error.getClass() == java.io.IOException.class) return error.getMessage();
        return "操作未完成，请检查文件、网络和解锁材料。";
    }

    private LinearLayout fields() {
        LinearLayout layout = ui.column();
        layout.setPadding(dp(20), dp(3), dp(20), dp(12));
        return layout;
    }

    private void addField(LinearLayout layout, EditText field, String label) {
        TextView title = ui.text(label, 13, MUTED, true);
        title.setPadding(0, dp(8), 0, 0);
        field.setId(View.generateViewId());
        title.setLabelFor(field.getId());
        layout.addView(title);
        layout.addView(field, new LinearLayout.LayoutParams(-1, -2));
    }

    private EditText input(String hint, String value, boolean secret) {
        EditText text = new EditText(this);
        text.setHint(hint);
        text.setTextColor(INK);
        text.setHintTextColor(QUIET);
        text.setTextSize(16);
        text.setMinimumHeight(dp(48));
        text.setSingleLine(true);
        text.setInputType(InputType.TYPE_CLASS_TEXT |
            (secret ? InputType.TYPE_TEXT_VARIATION_PASSWORD : InputType.TYPE_TEXT_FLAG_NO_SUGGESTIONS));
        if (secret) {
            text.setImportantForAutofill(View.IMPORTANT_FOR_AUTOFILL_NO);
            text.setImeOptions(android.view.inputmethod.EditorInfo.IME_FLAG_NO_PERSONALIZED_LEARNING);
        }
        text.setText(value);
        return text;
    }

    private int dp(int value) { return ui.dp(value); }

    private record Connection(SpaceSession session, DavStorage dav) {}
    private interface Task<T> { T run() throws Exception; }
    private interface Mutation { void run() throws Exception; }
}
