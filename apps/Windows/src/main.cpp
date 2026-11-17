#include "browser_bridge.hpp"
#include "windows_hello.hpp"
#include <windows.h>
#include <commctrl.h>
#include <commdlg.h>
#include <wtsapi32.h>
#include <algorithm>
#include <array>
#include <functional>
#include <ranges>
#include <thread>
#include <unordered_map>
#ifdef PBSYNC_UI_CAPTURE
#include <fstream>
#endif

using namespace pb;

namespace {
constexpr COLORREF ink = RGB(23, 35, 38), secondary = RGB(83, 100, 103), soft = RGB(240, 244, 245);
constexpr COLORREF paper = RGB(253, 254, 254), border = RGB(224, 233, 233), tint = RGB(222, 241, 235);
constexpr COLORREF green = RGB(0, 110, 92), greenDark = RGB(0, 84, 71), white = RGB(255, 255, 255);
constexpr DWORD children = WS_CHILD | WS_TABSTOP;
constexpr UINT finished = WM_APP + 1;
constexpr int minWidth = 980, minHeight = 590;

enum Control {
    navBooks = 100, navVault, navSync, searchBox, foldersBox, itemsBox, primaryButton, lockButton,
    trashButton, folderButton, editButton, deleteButton, upButton, downButton, restoreButton,
    revealButton, openFolderButton, connectBooksButton, connectVaultButton, syncBooksButton,
    syncVaultButton, autoButton, fileButton, detailButton, pairBrowserButton, helloButton,
};

enum class Page { bookmarks, passwords, sync };

struct Fonts {
    HFONT body{}, bodyBold{}, small{}, title{}, brand{}, icons{};
    int dpi = 96;
    int px(int logical) const { return MulDiv(logical, dpi, 96); }
    void set(int value) {
        destroy();
        dpi = value;
        body = make(15, FW_NORMAL);
        bodyBold = make(15, FW_SEMIBOLD);
        small = make(13, FW_NORMAL);
        title = make(32, FW_SEMIBOLD);
        brand = make(23, FW_SEMIBOLD);
        icons = make(17, FW_NORMAL, L"Segoe MDL2 Assets");
    }
    HFONT make(int size, int weight, LPCWSTR family = L"Microsoft YaHei UI") const {
        return CreateFontW(-px(size), 0, 0, 0, weight, FALSE, FALSE, FALSE, DEFAULT_CHARSET, OUT_DEFAULT_PRECIS,
            CLIP_DEFAULT_PRECIS, CLEARTYPE_QUALITY, DEFAULT_PITCH, family);
    }
    void destroy() {
        for (auto font : {body, bodyBold, small, title, brand, icons}) if (font) DeleteObject(font);
    }
    ~Fonts() { destroy(); }
};

struct Theme {
    HBRUSH canvas = CreateSolidBrush(paper);
    HBRUSH input = CreateSolidBrush(white);
    ~Theme() { DeleteObject(canvas); DeleteObject(input); }
};

void fill(HDC dc, RECT r, COLORREF color) {
    auto brush = CreateSolidBrush(color);
    FillRect(dc, &r, brush);
    DeleteObject(brush);
}

void roundBox(HDC dc, RECT r, int radius, COLORREF color, COLORREF outline) {
    auto pen = CreatePen(PS_SOLID, 1, outline);
    auto brush = CreateSolidBrush(color);
    auto oldPen = SelectObject(dc, pen), oldBrush = SelectObject(dc, brush);
    RoundRect(dc, r.left, r.top, r.right, r.bottom, radius, radius);
    SelectObject(dc, oldBrush);
    SelectObject(dc, oldPen);
    DeleteObject(brush);
    DeleteObject(pen);
}

void draw(HDC dc, std::wstring_view text, RECT r, HFONT font, COLORREF color, UINT alignment = DT_LEFT) {
    auto old = SelectObject(dc, font);
    SetBkMode(dc, TRANSPARENT);
    SetTextColor(dc, color);
    DrawTextW(dc, text.data(), static_cast<int>(text.size()), &r,
        alignment | DT_SINGLELINE | DT_VCENTER | DT_NOPREFIX | DT_END_ELLIPSIS);
    SelectObject(dc, old);
}

std::wstring textOf(HWND control) {
    auto length = GetWindowTextLengthW(control);
    std::wstring text(static_cast<size_t>(length) + 1, L'\0');
    text.resize(GetWindowTextW(control, text.data(), length + 1));
    return text;
}

HWND child(HWND parent, LPCWSTR cls, LPCWSTR text, DWORD style, int id, HFONT font, DWORD ext = 0) {
    auto window = CreateWindowExW(ext, cls, text, style, 0, 0, 0, 0, parent,
        reinterpret_cast<HMENU>(static_cast<INT_PTR>(id)), GetModuleHandleW(nullptr), nullptr);
    if (!window) throw Fault("无法创建 Windows 界面。");
    SendMessageW(window, WM_SETFONT, reinterpret_cast<WPARAM>(font), FALSE);
    return window;
}

void place(HWND window, int x, int y, int width, int height) {
    MoveWindow(window, x, y, std::max(0, width), std::max(0, height), FALSE);
    ShowWindow(window, SW_SHOWNA);
}

LRESULT send(HWND handle, UINT message, WPARAM left = 0, LPARAM right = 0) {
    return SendMessageW(handle, message, left, right);
}

struct Field {
    std::wstring label, value;
    bool secret{};
    std::vector<std::wstring> choices;
    int index{};
    Field(std::wstring label, std::wstring value = {}, bool secret = false)
        : label(std::move(label)), value(std::move(value)), secret(secret) {}
};

struct Form {
    HWND owner{}, window{};
    Fonts& fonts;
    Theme& theme;
    std::wstring title, button;
    std::vector<Field>& fields;
    bool recoveryChoice{}, recovery{}, done{}, accepted{};
    std::vector<HWND> inputs{};

    static LRESULT CALLBACK proc(HWND window, UINT message, WPARAM w, LPARAM l) {
        auto form = reinterpret_cast<Form*>(GetWindowLongPtrW(window, GWLP_USERDATA));
        if (message == WM_NCCREATE) {
            form = static_cast<Form*>(reinterpret_cast<CREATESTRUCTW*>(l)->lpCreateParams);
            form->window = window;
            SetWindowLongPtrW(window, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(form));
        }
        if (!form) return DefWindowProcW(window, message, w, l);
        if (message == WM_COMMAND && (LOWORD(w) == IDOK || LOWORD(w) == IDCANCEL)) {
            bool ok = LOWORD(w) == IDOK;
            for (size_t i = 0; i < form->fields.size(); ++i) {
                auto& field = form->fields[i];
                if (ok) {
                    if (field.choices.empty()) field.value = textOf(form->inputs[i]);
                    else field.index = static_cast<int>(send(form->inputs[i], CB_GETCURSEL));
                }
                if (field.secret) SetWindowTextW(form->inputs[i], L"");
            }
            form->recovery = form->recoveryChoice && send(GetDlgItem(window, 600), BM_GETCHECK) == BST_CHECKED;
            form->accepted = ok;
            form->done = true;
            ShowWindow(window, SW_HIDE);
            return 0;
        }
        if (message == WM_CLOSE) { send(window, WM_COMMAND, IDCANCEL); return 0; }
        if (message == WM_CTLCOLORSTATIC) {
            SetBkMode(reinterpret_cast<HDC>(w), TRANSPARENT);
            SetTextColor(reinterpret_cast<HDC>(w), ink);
            return reinterpret_cast<LRESULT>(form->theme.canvas);
        }
        if (message == WM_ERASEBKGND) {
            RECT r{};
            GetClientRect(window, &r);
            fill(reinterpret_cast<HDC>(w), r, paper);
            return 1;
        }
        return DefWindowProcW(window, message, w, l);
    }

    bool show() {
        WNDCLASSW cls{};
        cls.lpfnWndProc = proc;
        cls.hInstance = GetModuleHandleW(nullptr);
        cls.lpszClassName = L"PBsyncForm";
        cls.hCursor = LoadCursorW(nullptr, IDC_ARROW);
        RegisterClassW(&cls);
        auto px = [this](int size) { return fonts.px(size); };
        int height = 75 + static_cast<int>(fields.size()) * 66 + (recoveryChoice ? 29 : 0);
        RECT bounds{0, 0, px(474), px(height)};
        constexpr DWORD style = WS_CAPTION | WS_SYSMENU | WS_POPUP;
        AdjustWindowRectEx(&bounds, style, FALSE, WS_EX_DLGMODALFRAME);
        RECT parent{};
        GetWindowRect(owner, &parent);
        int width = bounds.right - bounds.left, outerHeight = bounds.bottom - bounds.top;
        window = CreateWindowExW(WS_EX_DLGMODALFRAME | WS_EX_CONTROLPARENT, cls.lpszClassName, title.c_str(), style,
            parent.left + (parent.right - parent.left - width) / 2, parent.top + (parent.bottom - parent.top - outerHeight) / 2,
            width, outerHeight, owner, nullptr, cls.hInstance, this);
        if (!window) throw Fault("无法打开编辑窗口。");
        int y = 15;
        for (size_t i = 0; i < fields.size(); ++i) {
            auto& field = fields[i];
            auto label = child(window, L"STATIC", field.label.c_str(), WS_CHILD, 700 + static_cast<int>(i), fonts.small);
            place(label, px(24), px(y), px(426), px(20));
            HWND input;
            if (field.choices.empty()) {
                input = child(window, L"EDIT", field.value.c_str(),
                    children | ES_AUTOHSCROLL | (field.secret ? ES_PASSWORD : 0), 500 + static_cast<int>(i), fonts.body, WS_EX_CLIENTEDGE);
                send(input, EM_LIMITTEXT, field.secret ? 4096 : 32768);
                send(input, EM_SETMARGINS, EC_LEFTMARGIN | EC_RIGHTMARGIN, MAKELONG(px(7), px(7)));
                place(input, px(24), px(y + 23), px(426), px(31));
            } else {
                input = child(window, L"COMBOBOX", nullptr, children | CBS_DROPDOWNLIST | WS_VSCROLL,
                    500 + static_cast<int>(i), fonts.body);
                for (const auto& choice : field.choices) send(input, CB_ADDSTRING, 0, reinterpret_cast<LPARAM>(choice.c_str()));
                send(input, CB_SETCURSEL, field.index);
                place(input, px(24), px(y + 23), px(426), px(164));
            }
            inputs.push_back(input);
            y += 66;
        }
        if (recoveryChoice) {
            auto check = child(window, L"BUTTON", L"使用恢复密钥", children | BS_AUTOCHECKBOX, 600, fonts.body);
            place(check, px(24), px(y), px(220), px(25));
            y += 29;
        }
        auto ok = child(window, L"BUTTON", button.c_str(), children | BS_DEFPUSHBUTTON, IDOK, fonts.bodyBold);
        auto cancel = child(window, L"BUTTON", L"取消", children | BS_PUSHBUTTON, IDCANCEL, fonts.body);
        place(ok, px(340), px(y + 3), px(110), px(34));
        place(cancel, px(226), px(y + 3), px(104), px(34));
        SetWindowDisplayAffinity(window, 0x11);
        EnableWindow(owner, FALSE);
        ShowWindow(window, SW_SHOW);
        if (!inputs.empty()) SetFocus(inputs[0]);
        MSG message{};
        while (!done) {
            auto result = GetMessageW(&message, nullptr, 0, 0);
            if (result <= 0) { if (result == 0) PostQuitMessage(static_cast<int>(message.wParam)); break; }
            if (!IsDialogMessageW(window, &message)) {
                TranslateMessage(&message);
                DispatchMessageW(&message);
            }
        }
        EnableWindow(owner, TRUE);
        DestroyWindow(window);
        SetActiveWindow(owner);
        return accepted;
    }
};

struct Space {
    std::shared_ptr<Vault> vault;
    std::shared_ptr<Storage> remote;
    std::wstring status;
    std::string folder, selected;
    bool trash{};
};

struct Folder { std::string id; std::wstring title; int indent{}; };

class App {
public:
    HWND window{};
    Fonts fonts;
    Theme theme;

    void initialize() {
        fonts.set(static_cast<int>(GetDpiForWindow(window)));
        const wchar_t* data = _wgetenv(L"LOCALAPPDATA");
        if (!data || !*data) throw Fault("无法定位本机应用数据目录。");
        root = Path(data) / L"PBsync";
        try { browser = std::make_unique<BrowserBridge>(window, root); }
        catch (const Fault&) { browser = nullptr; }
        for (auto [id, title] : std::initializer_list<std::pair<int, LPCWSTR>>{
            {navBooks, L"收藏夹"}, {navVault, L"密码库"}, {navSync, L"同步与连接"},
            {primaryButton, L"新增收藏"}, {lockButton, L"锁定"}, {trashButton, L"回收站"},
            {folderButton, L"新建目录"}, {editButton, L"编辑"}, {deleteButton, L"移到回收站"},
            {upButton, L"上移"}, {downButton, L"下移"}, {restoreButton, L"恢复条目"},
            {revealButton, L"显示密码"}, {openFolderButton, L"打开目录"}, {connectBooksButton, L"连接 WebDAV"},
            {connectVaultButton, L"连接 WebDAV"}, {syncBooksButton, L"立即同步"}, {syncVaultButton, L"立即同步"},
            {autoButton, L"定时同步已开启"}, {fileButton, L"打开加密备份"}, {detailButton, L"查看"},
            {pairBrowserButton, L"复制配对密钥"}, {helloButton, L"启用 Windows Hello"}
        }) controls.emplace(id, child(window, L"BUTTON", title, children | BS_OWNERDRAW, id, fonts.body));

        controls.emplace(searchBox, child(window, L"EDIT", nullptr, children | ES_AUTOHSCROLL, searchBox, fonts.body));
        send(control(searchBox), EM_LIMITTEXT, 500);
        for (int id : {foldersBox, itemsBox}) {
            auto list = child(window, L"LISTBOX", nullptr,
                children | WS_VSCROLL | LBS_NOTIFY | LBS_HASSTRINGS | LBS_OWNERDRAWFIXED | LBS_NOINTEGRALHEIGHT,
                id, fonts.body);
            controls.emplace(id, list);
        }
        SetTimer(window, 1, 20000, nullptr);
        WTSRegisterSessionNotification(window, NOTIFY_FOR_THIS_SESSION);
        refresh();
    }

    int px(int value) const { return fonts.px(value); }
    int side() const { return px(208); }
    int header() const { return px(109); }
    int middle() const { return px(page == Page::bookmarks ? 192 : 310); }
    int dataIndex() const { return page == Page::passwords ? 1 : 0; }
    HWND control(int id) const { return controls.at(id); }

    void layout() {
        if (controls.empty()) return;
        GetClientRect(window, &frame);
        const int edge = frame.right - px(26);
        const int left = side() + px(25);
        const int center = side() + middle();
        const auto& space = spaces[dataIndex()];
        std::set<int> visible;
        auto pos = [&](int id, int x, int y, int width, int height) {
            visible.insert(id);
            place(control(id), x, y, width, height);
        };

        pos(navBooks, px(13), px(73), side() - px(26), px(45));
        pos(navVault, px(13), px(122), side() - px(26), px(45));
        pos(navSync, px(13), px(171), side() - px(26), px(45));

        if (page == Page::sync) {
            pos(autoButton, left, px(66), px(150), px(32));
            pos(connectBooksButton, edge - px(225), px(171), px(116), px(34));
            pos(connectVaultButton, edge - px(225), px(234), px(116), px(34));
            pos(syncBooksButton, edge - px(99), px(171), px(96), px(34));
            pos(syncVaultButton, edge - px(99), px(234), px(96), px(34));
            pos(pairBrowserButton, edge - px(133), px(317), px(130), px(34));
        } else if (!space.vault || locking) {
            pos(primaryButton, left + px(23), px(242), px(126), px(38));
            if (!exists(dataIndex()) && !locking) pos(fileButton, left + px(158), px(242), px(139), px(38));
            if (!locking && sessionKeys[dataIndex()] && exists(dataIndex())) {
                pos(helloButton, left + px(158), px(242), px(187), px(38));
            }
        } else {
            pos(searchBox, edge - px(412), px(31), px(202), px(27));
            pos(primaryButton, edge - px(176), px(25), px(107), px(38));
            pos(lockButton, edge - px(61), px(25), px(61), px(38));
            pos(trashButton, edge - px(91), px(71), px(91), px(28));
            if (exists(dataIndex())) pos(helloButton, edge - px(291), px(71), px(190), px(28));

            if (page == Page::bookmarks) {
                pos(foldersBox, side() + px(13), header() + px(43), middle() - px(25), frame.bottom - header() - px(97));
                if (!space.trash) pos(folderButton, side() + px(18), frame.bottom - px(49), px(145), px(33));
                pos(itemsBox, center + px(13), header() + px(43), frame.right - center - px(27), frame.bottom - header() - px(111));
            } else {
                pos(itemsBox, side() + px(13), header() + px(43), middle() - px(25), frame.bottom - header() - px(50));
            }

            if (!space.selected.empty()) {
                if (space.trash) {
                    pos(restoreButton, center + px(23), frame.bottom - px(52), px(111), px(34));
                } else if (page == Page::bookmarks) {
                    if (selectedKind() == "folder") pos(openFolderButton, center + px(19), frame.bottom - px(52), px(88), px(34));
                    pos(editButton, center + px(118), frame.bottom - px(52), px(62), px(34));
                    pos(upButton, center + px(189), frame.bottom - px(52), px(58), px(34));
                    pos(downButton, center + px(254), frame.bottom - px(52), px(58), px(34));
                    pos(deleteButton, edge - px(105), frame.bottom - px(52), px(105), px(34));
                } else {
                    pos(selectedEditable() ? editButton : detailButton, edge - px(157), header() + px(38), px(58), px(32));
                    pos(deleteButton, edge - px(93), header() + px(38), px(93), px(32));
                    if (selectedKind() == "login") pos(revealButton, edge - px(92), header() + px(194), px(92), px(31));
                }
            }
        }
        for (auto [id, handle] : controls) {
            if (!visible.contains(id)) ShowWindow(handle, SW_HIDE);
            bool enabled = (!busy || id == lockButton);
            if (id == syncBooksButton) enabled = enabled && spaces[0].remote != nullptr;
            if (id == syncVaultButton) enabled = enabled && spaces[1].remote != nullptr;
            if (id == pairBrowserButton) enabled = enabled && browser && spaces[0].vault != nullptr;
            EnableWindow(handle, enabled);
        }
        InvalidateRect(window, nullptr, FALSE);
        for (auto [_, handle] : controls) InvalidateRect(handle, nullptr, TRUE);
    }

    void refresh() {
        const auto& space = spaces[dataIndex()];
        const bool opened = space.vault && !locking;
        SetWindowTextW(control(primaryButton), !opened ? (locking ? L"正在锁定…" : (exists(dataIndex()) ? L"解锁保险库" :
            L"连接 WebDAV")) : page == Page::bookmarks ? L"＋ 新增收藏" : L"＋ 新增密码");
        SetWindowTextW(control(trashButton), space.trash ? L"返回条目" : L"回收站");
        SetWindowTextW(control(revealButton), reveal ? L"隐藏密码" : L"显示密码");
        SetWindowTextW(control(autoButton), automatic ? L"定时同步已开启" : L"定时同步已暂停");
        SetWindowTextW(control(connectBooksButton), spaces[0].remote ? L"更改连接" : L"连接 WebDAV");
        SetWindowTextW(control(connectVaultButton), spaces[1].remote ? L"更改连接" : L"连接 WebDAV");
        SetWindowTextW(control(helloButton), !opened ? L"用 Windows Hello 解锁" :
            sessionKeys[dataIndex()] ? L"关闭 Windows Hello" : L"启用 Windows Hello");
        updateLists();
        layout();
    }

    void paint() {
        PAINTSTRUCT ps{};
        auto dc = BeginPaint(window, &ps);
        auto compatible = CreateCompatibleDC(dc);
        auto bitmap = CreateCompatibleBitmap(dc, frame.right, frame.bottom);
        if (bitmap && compatible) {
            auto old = SelectObject(compatible, bitmap);
            background(compatible);
            BitBlt(dc, 0, 0, frame.right, frame.bottom, compatible, 0, 0, SRCCOPY);
            SelectObject(compatible, old);
        } else background(dc);
        if (bitmap) DeleteObject(bitmap);
        if (compatible) DeleteDC(compatible);
        EndPaint(window, &ps);
    }

    void background(HDC dc) {
        fill(dc, frame, paper);
        fill(dc, {0, 0, side(), frame.bottom}, soft);
        fill(dc, {side() - 1, 0, side(), frame.bottom}, border);
        auto logical = [&](int x, int y, int w, int h) -> RECT { return {px(x), px(y), px(x+w), px(y+h)}; };
        auto badge = logical(21, 21, 34, 34);
        roundBox(dc, badge, px(11), green, green);
        draw(dc, L"\uE72E", badge, fonts.icons, white, DT_CENTER);
        draw(dc, L"PBsync", logical(65, 17, 120, 42), fonts.brand, ink);

        const auto& space = spaces[dataIndex()];
        const std::wstring title = page == Page::bookmarks ? L"收藏夹" : page == Page::passwords ? L"密码库" : L"同步与连接";
        int left = side() + px(26), right = frame.right - px(26);
        draw(dc, title, {left, px(18), right, px(62)}, fonts.title, ink);
        bool local = exists(dataIndex());
        draw(dc, L"\uE73E", {px(23), frame.bottom - px(49), px(44), frame.bottom - px(22)}, fonts.icons, green);
        draw(dc, page == Page::sync ? L"加密同步" : space.remote ? L"WebDAV 已连接" :
            space.vault ? L"本机保险库已解锁" : L"本机保险库已锁定",
            {px(47), frame.bottom - px(49), side() - px(8), frame.bottom - px(22)}, fonts.small, secondary);

        if (page == Page::sync) {
            fill(dc, {left, px(116), right, px(116) + 1}, border);
            draw(dc, L"数据空间", {left + px(15), px(126), left + px(210), px(154)}, fonts.small, secondary);
            draw(dc, L"连接状态", {left + px(212), px(126), right, px(154)}, fonts.small, secondary);
            for (int index = 0; index < 2; ++index) {
                const int top = px(157 + index * 63);
                roundBox(dc, {left, top, right, top + px(57)}, px(14), index == 0 ? soft : paper, border);
                draw(dc, index == 0 ? L"收藏夹" : L"密码库", {left + px(15), top, left + px(196), top + px(57)}, fonts.bodyBold, ink);
                const auto& item = spaces[index];
                auto status = item.status.empty() ? (item.remote ? L"WebDAV 已连接" : L"等待连接") : item.status;
                draw(dc, status, {left + px(212), top, right - px(238), top + px(57)}, fonts.small, item.remote ? green : secondary);
            }
            fill(dc, {left, px(300), right, px(301)}, border);
            draw(dc, L"浏览器收藏夹", {left + px(15), px(307), left + px(196), px(362)}, fonts.bodyBold, ink);
            const auto browserStatus = !browser ? L"本机连接不可用" : !spaces[0].vault ? L"请先解锁收藏夹" :
                !browserNotice.empty() ? browserNotice.c_str() : browser->paired() ? L"已配对 · 等待浏览器同步" : L"等待配对";
            draw(dc, browserStatus, {left + px(212), px(307), right - px(144), px(362)}, fonts.small, secondary);
            return;
        }

        if (!space.vault || locking) {
            roundBox(dc, {left, px(120), right, px(309)}, px(22), white, border);
            draw(dc, locking ? L"正在锁定保险库" : local ? L"保险库已锁定" : L"打开保险库",
                {left + px(23), px(140), right - px(20), px(182)}, fonts.brand, ink);
            auto status = space.status.empty() ? (local ? L"使用主密码或恢复密钥解锁。" : L"连接现有 WebDAV 空间，或从加密备份恢复。") : space.status;
            draw(dc, status, {left + px(23), px(187), right - px(20), px(221)}, fonts.body, secondary);
            return;
        }

        auto status = space.status.empty() ? (space.remote ? L"WebDAV 已连接" : L"已解锁 · 本机副本") : space.status;
        draw(dc, status, {left, px(68), right - px(299), px(100)}, fonts.small, space.remote ? green : secondary);
        auto searchEdge = frame.right - px(26 + 412);
        roundBox(dc, {searchEdge - px(31), px(25), searchEdge + px(216), px(63)}, px(15), white, border);
        draw(dc, L"\uE721", {searchEdge - px(24), px(25), searchEdge - px(4), px(63)}, fonts.icons, secondary);

        int split = side() + middle();
        fill(dc, {side(), header(), frame.right, header()+1}, border);
        fill(dc, {split, header(), split+1, frame.bottom}, border);
        const std::wstring scope = space.trash ? L"回收站" : page == Page::bookmarks ? L"收藏目录" : L"登录条目";
        draw(dc, scope, {side() + px(25), header(), split - px(8), header() + px(43)}, fonts.small, secondary);

        if (page == Page::bookmarks) {
            draw(dc, L"名称", {split + px(62), header(), right, header() + px(43)}, fonts.small, secondary);
            draw(dc, L"网址", {split + (frame.right - split) * 58 / 100, header(), right, header() + px(43)}, fonts.small, secondary);
            if (rows.empty()) draw(dc, space.trash ? L"回收站为空" : L"没有匹配的收藏", {split + px(26), header() + px(54), right, header() + px(94)}, fonts.body, secondary);
        } else {
            if (rows.empty()) draw(dc, space.trash ? L"回收站为空" : L"没有匹配的条目", {left, header()+px(49), split, header()+px(89)}, fonts.body, secondary);
            if (!selected) {
                draw(dc, L"选择条目查看详情", {split + px(25), header() + px(31), right, header() + px(75)}, fonts.body, secondary);
                return;
            }
            const int head = header() + px(22), x = split + px(22);
            roundBox(dc, {x, head, x + px(44), head + px(44)}, px(13), tint, tint);
            draw(dc, L"\uE72E", {x, head, x + px(44), head + px(44)}, fonts.icons, green, DT_CENTER);
            draw(dc, wide(selected->title), {x + px(57), head, right - px(170), head + px(44)}, fonts.brand, ink);
            std::array<std::pair<LPCWSTR, std::wstring>, 3> fields{{
                {L"网站", wide(selected->url)}, {L"用户名", wide(selected->username)},
                {L"密码", selected->kind == "login" ? (reveal ? wide(selected->password) : L"● ● ● ● ● ● ● ●") : L"—"}
            }};
            for (size_t index = 0; index < fields.size(); ++index) {
                int y = header() + px(82 + static_cast<int>(index)*53);
                fill(dc, {x, y, right, y+1}, border);
                draw(dc, fields[index].first, {x, y, x + px(79), y + px(53)}, fonts.bodyBold, ink);
                draw(dc, fields[index].second.empty() ? L"—" : fields[index].second,
                    {x + px(88), y, right - (index == 2 ? px(102) : 0), y + px(53)}, fonts.body, secondary);
            }
            if (!selected->notes.empty()) draw(dc, wide(selected->notes),
                {x, header() + px(252), right, header() + px(300)}, fonts.body, secondary);
        }
    }

    LRESULT ownerDraw(const DRAWITEMSTRUCT& item) {
        const auto id = static_cast<int>(item.CtlID);
        RECT r = item.rcItem;
        auto dc = item.hDC;
        if (id == foldersBox || id == itemsBox) {
            fill(dc, r, paper);
            if (item.itemID == static_cast<UINT>(-1)) return TRUE;
            const bool active = (item.itemState & ODS_SELECTED) != 0;
            auto card = r;
            InflateRect(&card, -px(2), -px(3));
            if (active) roundBox(dc, card, px(14), tint, tint);
            else if (id == itemsBox) fill(dc, {r.left + px(10), r.bottom - 1, r.right - px(8), r.bottom}, border);
            if (id == foldersBox && item.itemID < folders.size()) {
                const auto& folder = folders[item.itemID];
                auto x = r.left + px(12 + folder.indent * 12);
                draw(dc, folder.id.empty() ? L"\uE81E" : L"\uE8B7", {x, r.top, x+px(21), r.bottom}, fonts.icons, active ? green : secondary);
                draw(dc, folder.title, {x + px(26), r.top, r.right - px(6), r.bottom}, active ? fonts.bodyBold : fonts.body, active ? greenDark : ink);
            } else if (id == itemsBox && item.itemID < rows.size()) {
                const auto& row = rows[item.itemID];
                RECT icon{r.left + px(10), r.top + px(10), r.left + px(44), r.bottom - px(10)};
                roundBox(dc, icon, px(11), active ? white : tint, active ? white : tint);
                draw(dc, row.kind == "folder" ? L"\uE8B7" : row.kind == "bookmark" ? L"\uE734" : L"\uE72E",
                    icon, fonts.icons, green, DT_CENTER);
                RECT title{r.left + px(52), r.top, r.right - px(10), r.bottom};
                if (page == Page::bookmarks) {
                    int x = r.left + (r.right - r.left) * 58 / 100;
                    title.right = x - px(10);
                    draw(dc, wide(row.url), {x, r.top, r.right - px(12), r.bottom}, fonts.small, secondary);
                } else {
                    title.top += px(4);
                    title.bottom = r.top + px(34);
                    draw(dc, wide(row.username.empty() ? row.url : row.username),
                        {title.left, r.top + px(31), title.right, r.bottom - px(6)}, fonts.small, secondary);
                }
                draw(dc, wide(row.title), title, fonts.bodyBold, ink);
            }
        } else {
            const bool nav = id == navBooks || id == navVault || id == navSync;
            const bool selectedNav = (id == navBooks && page == Page::bookmarks) ||
                (id == navVault && page == Page::passwords) || (id == navSync && page == Page::sync);
            bool strong = id == primaryButton;
            bool disabled = (item.itemState & ODS_DISABLED) != 0;
            fill(dc, r, nav ? soft : paper);
            COLORREF background = selectedNav ? tint : nav ? soft : strong ? green : white;
            COLORREF foreground = selectedNav ? greenDark : strong ? white : ink;
            if (disabled) { background = soft; foreground = secondary; }
            if ((item.itemState & ODS_SELECTED) && !disabled) background = strong ? greenDark : tint;
            roundBox(dc, r, px(15), background, nav || strong ? background : border);
            if (nav) {
                draw(dc, id == navBooks ? L"\uE734" : id == navVault ? L"\uE72E" : L"\uE895",
                    {r.left + px(13), r.top, r.left + px(38), r.bottom}, fonts.icons, selectedNav ? green : secondary);
                r.left += px(45);
            }
            draw(dc, textOf(item.hwndItem), r, selectedNav || strong ? fonts.bodyBold : fonts.body,
                foreground, nav ? DT_LEFT : DT_CENTER);
        }
        if ((item.itemState & ODS_FOCUS) && !(item.itemState & ODS_NOFOCUSRECT)) {
            RECT focus = item.rcItem;
            InflateRect(&focus, -px(3), -px(3));
            DrawFocusRect(dc, &focus);
        }
        return TRUE;
    }

#ifdef PBSYNC_UI_CAPTURE
    // 验收程序复用当前窗口的 GDI 绘制。无交互桌面的 WinRM 会话也能对照设计稿。
    LRESULT capture() {
        const auto* directory = _wgetenv(L"PBSYNC_QA_SCREENSHOT_DIR");
        if (!directory || frame.right <= 0 || frame.bottom <= 0 || reveal) return 0;
        const auto file = Path(directory) / (page == Page::bookmarks ? L"windows-bookmarks.bmp" :
            page == Page::passwords ? L"windows-passwords.bmp" : L"windows-sync.bmp");
        BITMAPINFO format{};
        auto& info = format.bmiHeader;
        info.biSize = sizeof(info);
        info.biWidth = frame.right;
        info.biHeight = frame.bottom;
        info.biPlanes = 1;
        info.biBitCount = 32;
        info.biCompression = BI_RGB;
        info.biSizeImage = frame.right * frame.bottom * 4;
        void* pixels = nullptr;
        auto dc = CreateCompatibleDC(nullptr);
        auto dib = CreateDIBSection(dc, &format, DIB_RGB_COLORS, &pixels, nullptr, 0);
        if (!dc || !dib) {
            if (dib) DeleteObject(dib);
            if (dc) DeleteDC(dc);
            return 0;
        }
        auto old = SelectObject(dc, dib);
        background(dc);
        for (const auto& [id, handle] : controls) {
            const auto style = GetWindowLongW(handle, GWL_STYLE);
            if (!(style & WS_VISIBLE)) continue;
            RECT bounds{};
            GetWindowRect(handle, &bounds);
            MapWindowPoints(nullptr, window, reinterpret_cast<POINT*>(&bounds), 2);
            if (id == searchBox) {
                auto label = textOf(handle);
                draw(dc, label.empty() ? (page == Page::bookmarks ? L"搜索收藏夹" : L"搜索密码库") : label,
                    bounds, fonts.body, label.empty() ? secondary : ink);
                continue;
            }
            const auto saved = SaveDC(dc);
            IntersectClipRect(dc, bounds.left, bounds.top, bounds.right, bounds.bottom);
            if (id == foldersBox || id == itemsBox) {
                auto first = static_cast<int>(send(handle, LB_GETTOPINDEX));
                auto count = static_cast<int>(send(handle, LB_GETCOUNT));
                auto chosen = static_cast<int>(send(handle, LB_GETCURSEL));
                int lineHeight = static_cast<int>(send(handle, LB_GETITEMHEIGHT));
                if (lineHeight > 0) for (int index = first, top = bounds.top; index < count && top < bounds.bottom; ++index, top += lineHeight) {
                    DRAWITEMSTRUCT item{};
                    item.CtlID = id;
                    item.itemID = index;
                    item.itemState = index == chosen ? ODS_SELECTED : 0;
                    item.hwndItem = handle;
                    item.hDC = dc;
                    item.rcItem = {bounds.left, top, bounds.right, top + lineHeight};
                    ownerDraw(item);
                }
            } else {
                DRAWITEMSTRUCT item{};
                item.CtlID = id;
                item.itemState = (style & WS_DISABLED) ? ODS_DISABLED : 0;
                item.hwndItem = handle;
                item.hDC = dc;
                item.rcItem = bounds;
                ownerDraw(item);
            }
            RestoreDC(dc, saved);
        }
        GdiFlush();
        BITMAPFILEHEADER header{};
        header.bfType = 0x4d42;
        header.bfOffBits = sizeof(header) + sizeof(info);
        header.bfSize = header.bfOffBits + info.biSizeImage;
        std::ofstream out(file, std::ios::binary);
        out.write(reinterpret_cast<const char*>(&header), sizeof(header));
        out.write(reinterpret_cast<const char*>(&info), sizeof(info));
        out.write(static_cast<const char*>(pixels), info.biSizeImage);
        SelectObject(dc, old);
        DeleteObject(dib);
        DeleteDC(dc);
        return out ? 1 : 0;
    }
#endif

    void onCommand(int id, int notification) {
        if (id == searchBox && notification != EN_CHANGE) return;
        if ((id == foldersBox || id == itemsBox) && notification != LBN_SELCHANGE && notification != LBN_DBLCLK) return;
        if (id == lockButton && busy && page != Page::sync && spaces[dataIndex()].vault && !locking) {
            locking = true;
            helloCancelled = true;
            spaces[dataIndex()].selected.clear();
            clearDetail();
            layout();
            return;
        }
        if (busy) return;
        if (id == navBooks || id == navVault || id == navSync) {
            auto next = id == navBooks ? Page::bookmarks : id == navVault ? Page::passwords : Page::sync;
            if (next != page) {
                page = next;
                clearDetail();
                SetWindowTextW(control(searchBox), L"");
                refresh();
            }
            return;
        }
        auto index = dataIndex();
        auto& space = spaces[index];
        switch (id) {
        case primaryButton:
            if (space.vault) edit(page == Page::bookmarks ? "bookmark" : "login", true);
            else if (exists(index)) unlock(index, {});
            else connect(index);
            break;
        case fileButton: chooseFile(index); break;
        case helloButton: useHello(index); break;
        case lockButton: lockSpace(index); break;
        case connectBooksButton: connect(0); break;
        case connectVaultButton: connect(1); break;
        case syncBooksButton: sync(0, false); break;
        case syncVaultButton: sync(1, false); break;
        case autoButton: automatic = !automatic; refresh(); break;
        case pairBrowserButton: copyPairingToken(); break;
        case searchBox: if (page != Page::sync) { space.selected.clear(); clearDetail(); refresh(); } break;
        case trashButton: space.trash = !space.trash; space.selected.clear(); clearDetail(); refresh(); break;
        case foldersBox: {
            auto row = static_cast<size_t>(send(control(foldersBox), LB_GETCURSEL));
            if (row < folders.size()) {
                space.folder = folders[row].id;
                space.selected.clear();
                space.trash = false;
                SetWindowTextW(control(searchBox), L"");
                refresh();
            }
            break;
        }
        case itemsBox: {
            auto row = static_cast<size_t>(send(control(itemsBox), LB_GETCURSEL));
            if (row >= rows.size()) return;
            space.selected = rows[row].id;
            clearDetail();
            if (notification == LBN_DBLCLK && !space.trash) {
                if (rows[row].kind == "folder") openFolder();
                else edit(rows[row].kind, false);
            } else { updateDetail(); layout(); }
            break;
        }
        case folderButton: edit("folder", true); break;
        case editButton: case detailButton: if (!space.selected.empty()) edit(selectedKind(), false); break;
        case openFolderButton: openFolder(); break;
        case upButton: case downButton:
            if (space.vault && !space.selected.empty()) {
                space.vault->move(space.selected, id == upButton ? -1 : 1);
                saved(index);
            }
            break;
        case deleteButton:
            if (space.vault && !space.selected.empty()) {
                modal = true;
                auto confirmed = MessageBoxW(window, L"条目将移到回收站，可以恢复。", L"移到回收站", MB_OKCANCEL | MB_ICONQUESTION) == IDOK;
                modal = false;
                if (confirmed) { space.vault->remove(space.selected); saved(index); }
            }
            break;
        case restoreButton:
            if (space.vault && !space.selected.empty()) { space.vault->recover(space.selected); saved(index); }
            break;
        case revealButton:
            if (selected && selected->kind == "login") {
                if (!reveal) selected->password = space.vault->detail(space.selected).password;
                else clearPassword();
                reveal = !reveal;
                SetWindowDisplayAffinity(window, reveal ? 0x11 : WDA_NONE);
                SetWindowTextW(control(revealButton), reveal ? L"隐藏密码" : L"显示密码");
                InvalidateRect(window, nullptr, FALSE);
            }
            break;
        }
    }

    void receiveBrowser() {
        if (!browser) return;
        bool changed = false, applied = false;
        browser->receive([&] {
            if (closing || !spaces[0].vault || (locking && dataIndex() == 0)) throw Fault("请先解锁 PBsync 收藏夹。");
            if (busy || modal) throw Fault("PBsync 正在处理，请稍后再试。");
            return spaces[0].vault->browserPairingKey(false);
        }, [&](const Json& request) {
            auto command = request.at("command").get<std::string>();
            if (command == "bookmarks.pull") return spaces[0].vault->browserSnapshot();
            if (command != "bookmarks.apply") throw Fault("此连接只支持浏览器收藏夹。");
            auto [snapshot, updated] = spaces[0].vault->browserApply(request.at("items"), request.at("deleted"));
            applied = true;
            changed = updated;
            return snapshot;
        });
        if (applied) {
            browserNotice = L"已与浏览器同步";
            if (changed) saved(0);
            else InvalidateRect(window, nullptr, FALSE);
        }
    }

    void tick() {
        if (busy || modal || !automatic) return;
        for (int i = 0; i < 2; ++i) {
            auto index = (nextSync + i) % 2;
            if (spaces[index].remote && spaces[index].vault) {
                nextSync = (index + 1) % 2;
                sync(index, true);
                return;
            }
        }
    }

    void complete() {
        if (worker.joinable()) worker.join();
        busy = false;
        auto& space = spaces[pendingIndex];
        if (pendingGeneration == lockGeneration && (!locking || pendingIndex != dataIndex())) {
            if (result.vault) space.vault = std::move(result.vault);
            if (result.remote) space.remote = std::move(result.remote);
            if (result.sessionKey) sessionKeys[pendingIndex] = std::move(result.sessionKey);
            space.status = result.status.empty() ? previousStatus : std::move(result.status);
        }
        result = {};
        if (locking) lockSpace(dataIndex());
        else refresh();
        if (closing) DestroyWindow(window);
    }

    void requestClose() {
        helloCancelled = true;
        if (!busy) DestroyWindow(window);
        else {
            closing = true;
            ShowWindow(window, SW_HIDE);
        }
    }

    void lockAll() {
        ++lockGeneration;
        helloCancelled = true;
        if (activeForm && activeForm->window) send(activeForm->window, WM_COMMAND, IDCANCEL);
        spaces = {};
        locking = false;
        browserNotice.clear();
        clearDetail();
        refresh();
    }

    void error(std::wstring message) {
        spaces[dataIndex()].status = message;
        InvalidateRect(window, nullptr, FALSE);
        MessageBoxW(window, message.c_str(), L"PBsync", MB_OK | MB_ICONWARNING);
    }

private:
    struct Result {
        std::shared_ptr<Vault> vault;
        std::shared_ptr<Storage> remote;
        std::wstring status;
        std::shared_ptr<SessionUnlockKey> sessionKey{};
    };
    struct Secret {
        std::string value;
        explicit Secret(std::wstring& input) : value(utf8(input)) {
            SecureZeroMemory(input.data(), input.size() * sizeof(wchar_t));
            input.clear();
        }
        ~Secret() { SecureZeroMemory(value.data(), value.size()); }
    };
    Page page = Page::bookmarks;
    std::array<Space, 2> spaces;
    std::array<std::shared_ptr<SessionUnlockKey>, 2> sessionKeys;
    std::unordered_map<int, HWND> controls;
    Path root;
    std::unique_ptr<BrowserBridge> browser;
    std::wstring browserNotice;
    RECT frame{};
    std::vector<Folder> folders;
    std::vector<Entry> rows;
    std::optional<Entry> selected;
    bool busy{}, modal{}, reveal{}, automatic{true}, closing{}, locking{};
    std::atomic_bool helloCancelled{false};
    unsigned long long lockGeneration{}, pendingGeneration{};
    int pendingIndex{}, nextSync{};
    std::thread worker;
    Form* activeForm{};
    Result result;
    std::wstring previousStatus;

    Path archive(int index) const { return root / (index == 0 ? L"bookmarks.pbsync" : L"vault.pbsync"); }
    bool exists(int index) const {
        std::error_code error;
        return std::filesystem::is_regular_file(archive(index), error);
    }

    void copyPairingToken() {
        if (!browser || !spaces[0].vault) return;
        auto key = spaces[0].vault->browserPairingKey(true);
        auto encoded = base64(key);
        SecureZeroMemory(key.data(), key.size());
        auto token = wide(encoded);
        SecureZeroMemory(encoded.data(), encoded.size());
        if (!OpenClipboard(window)) {
            SecureZeroMemory(token.data(), token.size() * sizeof(wchar_t));
            throw Fault("无法打开剪贴板，请重试。");
        }
        HGLOBAL memory = GlobalAlloc(GMEM_MOVEABLE, (token.size() + 1) * sizeof(wchar_t));
        bool copied = false;
        if (memory) {
            auto* text = static_cast<wchar_t*>(GlobalLock(memory));
            if (text) {
                std::copy(token.begin(), token.end(), text);
                text[token.size()] = L'\0';
                GlobalUnlock(memory);
                copied = EmptyClipboard() && SetClipboardData(CF_UNICODETEXT, memory) != nullptr;
            }
        }
        if (!copied && memory) GlobalFree(memory);
        CloseClipboard();
        SecureZeroMemory(token.data(), token.size() * sizeof(wchar_t));
        if (!copied) throw Fault("无法写入剪贴板，请重试。");
        browserNotice = L"密钥已复制 · 粘贴到 PBsync 书签扩展";
        InvalidateRect(window, nullptr, FALSE);
    }

    void clearPassword() {
        if (selected) {
            SecureZeroMemory(selected->password.data(), selected->password.size());
            selected->password.clear();
        }
    }
    void clearDetail() {
        if (reveal) SetWindowDisplayAffinity(window, WDA_NONE);
        clearPassword();
        selected.reset();
        reveal = false;
    }

    std::string selectedKind() const {
        auto& identity = spaces[dataIndex()].selected;
        auto row = std::ranges::find(rows, identity, &Entry::id);
        return row == rows.end() ? "" : row->kind;
    }
    bool selectedEditable() const { return selected && selected->editable(); }

    void updateDetail() {
        if (page != Page::passwords || spaces[1].selected.empty() || !spaces[1].vault) return;
        selected = spaces[1].vault->detail(spaces[1].selected);
        clearPassword();
        reveal = false;
    }

    void updateLists() {
        const int index = dataIndex();
        auto& space = spaces[index];
        auto foldersList = control(foldersBox), itemsList = control(itemsBox);
        send(foldersList, LB_RESETCONTENT); send(itemsList, LB_RESETCONTENT);
        send(foldersList, LB_SETITEMHEIGHT, 0, px(41));
        send(itemsList, LB_SETITEMHEIGHT, 0, px(page == Page::bookmarks ? 54 : 60));
        SendMessageW(control(searchBox), EM_SETCUEBANNER, TRUE,
            reinterpret_cast<LPARAM>(index == 0 ? L"搜索收藏夹" : L"搜索密码库"));
        folders.clear(); rows.clear(); clearDetail();
        if (page == Page::sync || !space.vault || locking) return;
        auto entries = space.vault->entries(space.trash);
        if (index == 0) {
            folders.push_back({{}, L"全部收藏", 0});
            const auto current = space.trash ? space.vault->entries() : entries;
            std::unordered_map<std::string, std::vector<const Entry*>> byParent;
            for (const auto& row : current) if (row.kind == "folder") byParent[row.parent].push_back(&row);
            auto visit = [&](auto&& self, const std::string& parent, int depth) -> void {
                auto group = byParent.find(parent);
                if (group == byParent.end()) return;
                for (const auto* folder : group->second) {
                    folders.push_back({folder->id, wide(folder->title), std::min(depth, 4)});
                    if (depth < 96) self(self, folder->id, depth + 1);
                }
            };
            visit(visit, {}, 0);
            auto found = std::ranges::find(folders, space.folder, &Folder::id);
            if (found == folders.end()) space.folder.clear();
            for (const auto& row : folders) send(foldersList, LB_ADDSTRING, 0, reinterpret_cast<LPARAM>(row.title.c_str()));
            send(foldersList, LB_SETCURSEL, found == folders.end() ? 0 : found - folders.begin());
        }

        auto query = textOf(control(searchBox));
        if (!query.empty()) CharLowerBuffW(query.data(), static_cast<DWORD>(query.size()));
        for (auto& row : entries) {
            if (!query.empty()) {
                auto terms = wide(row.title + "\n" + row.url + "\n" + row.username);
                CharLowerBuffW(terms.data(), static_cast<DWORD>(terms.size()));
                if (terms.find(query) == std::wstring::npos) continue;
            } else if (index == 0 && !space.trash && row.parent != space.folder) continue;
            auto title = wide(row.title);
            send(itemsList, LB_ADDSTRING, 0, reinterpret_cast<LPARAM>(title.c_str()));
            rows.push_back(std::move(row));
        }
        auto current = std::ranges::find(rows, space.selected, &Entry::id);
        if (current == rows.end()) {
            space.selected.clear();
            if (page == Page::passwords && !space.trash && !rows.empty()) {
                space.selected = rows[0].id;
                current = rows.begin();
            }
        }
        if (current != rows.end()) send(itemsList, LB_SETCURSEL, current - rows.begin());
        updateDetail();
    }

    bool form(std::wstring title, std::wstring button, std::vector<Field>& fields, bool* recovery = nullptr) {
        modal = true;
        auto generation = lockGeneration;
        Form form{window, nullptr, fonts, theme, std::move(title), std::move(button), fields, recovery != nullptr};
        activeForm = &form;
        try {
            auto accepted = form.show();
            activeForm = nullptr;
            if (recovery) *recovery = form.recovery;
            modal = false;
            return accepted && generation == lockGeneration;
        } catch (...) { activeForm = nullptr; modal = false; throw; }
    }

    void chooseFile(int index) {
        wchar_t selectedFile[32768]{};
        OPENFILENAMEW dialog{};
        dialog.lStructSize = sizeof(dialog);
        dialog.hwndOwner = window;
        dialog.lpstrFilter = L"PBsync 加密备份 (*.pbsync)\0*.pbsync\0";
        dialog.lpstrFile = selectedFile;
        dialog.nMaxFile = static_cast<DWORD>(std::size(selectedFile));
        dialog.Flags = OFN_FILEMUSTEXIST | OFN_PATHMUSTEXIST | OFN_NOCHANGEDIR;
        modal = true;
        bool accepted = GetOpenFileNameW(&dialog) != FALSE;
        modal = false;
        if (accepted) unlock(index, Path(selectedFile));
    }

    void unlock(int index, Path source) {
        std::vector<Field> fields{{L"主密码或恢复密钥", {}, true}};
        bool recovery{};
        if (!form(L"解锁保险库", L"解锁", fields, &recovery)) return;
        auto secret = std::make_shared<Secret>(fields[0].value);
        auto file = archive(index);
        begin(index, [index, file, source = std::move(source), secret, recovery] {
            auto vault = source.empty() ? Vault::open(file, secret->value, recovery, index == 0) :
                Vault::restore(file, readFile(source), secret->value, recovery, index == 0);
            return Result{vault, {}, L"已解锁 · " + wide(vault->name())};
        });
    }

    void useHello(int index) {
        auto file = archive(index);
        if (!spaces[index].vault) {
            auto quick = sessionKeys[index];
            if (!quick) return;
            begin(index, [this, quick, owner = window, file, index] {
                auto vault = quick->openAfterVerification(owner, file, index == 0, &helloCancelled);
                return Result{vault, {}, L"已用 Windows Hello 解锁"};
            });
            return;
        }
        if (sessionKeys[index]) {
            sessionKeys[index].reset();
            spaces[index].status = L"已关闭 Windows Hello 解锁";
            refresh();
            return;
        }
        std::vector<Field> fields{{L"主密码 · 仅在本次运行期间启用", {}, true}};
        if (!form(L"启用 Windows Hello", L"验证并启用", fields)) return;
        auto secret = std::make_shared<Secret>(fields[0].value);
        begin(index, [this, owner = window, file, index, secret] {
            auto vault = Vault::open(file, secret->value, false, index == 0);
            if (!verifyWindowsHello(owner, L"为本次 PBsync 运行启用 Windows Hello 解锁", &helloCancelled)) {
                throw Fault("Windows Hello 不可用或验证已取消。请检查 Windows 11 的登录选项。");
            }
            auto key = std::make_shared<SessionUnlockKey>(vault->deviceUnlockKey());
            return Result{{}, {}, L"已启用 Windows Hello · 本次运行有效", key};
        });
    }

    void connect(int index) {
        auto current = spaces[index].vault;
        if (!current && exists(index)) { unlock(index, {}); return; }
        std::vector<Field> fields{{L"HTTPS WebDAV 目录"}, {L"WebDAV 用户名"}, {L"WebDAV 密码", {}, true}};
        if (!current) fields.emplace_back(L"保险库主密码", L"", true);
        if (!form(index == 0 ? L"连接收藏夹" : L"连接密码库", L"连接", fields)) return;
        auto file = archive(index);
        auto authorization = std::make_shared<Secret>(fields[2].value);
        std::shared_ptr<Secret> master;
        if (!current) master = std::make_shared<Secret>(fields[3].value);
        begin(index, [index, file, current, address = fields[0].value, login = fields[1].value, authorization, master] {
            auto password = wide(authorization->value);
            std::shared_ptr<Storage> remote;
            try { remote = webdav(address, login, password); }
            catch (...) { SecureZeroMemory(password.data(), password.size() * sizeof(wchar_t)); throw; }
            SecureZeroMemory(password.data(), password.size() * sizeof(wchar_t));
            if (current) {
                current->sync(*remote);
                return Result{current, remote, L"WebDAV 已连接"};
            }
            return Result{Vault::connect(file, *remote, master->value, index == 0), remote, L"WebDAV 已连接"};
        });
    }

    void sync(int index, bool silent) {
        if (busy || !spaces[index].vault || !spaces[index].remote) return;
        auto vault = spaces[index].vault;
        auto remote = spaces[index].remote;
        begin(index, [vault, remote, silent] {
            auto result = vault->sync(*remote);
            return Result{{}, {}, silent && !result.downloaded && !result.uploaded ? L"" :
                L"同步完成 · 接收 " + std::to_wstring(result.downloaded) + L" · 上传 " + std::to_wstring(result.uploaded)};
        });
    }

    void begin(int index, std::function<Result()> action) {
        busy = true;
        helloCancelled = false;
        pendingGeneration = lockGeneration;
        pendingIndex = index;
        previousStatus = spaces[index].status;
        spaces[index].status = L"正在处理…";
        result = {};
        layout();
        worker = std::thread([this, action = std::move(action)] {
            try { result = action(); }
            catch (const Fault& error) { result.status = wide(error.what()); }
            catch (const std::exception&) { result.status = L"操作失败，请检查保险库文件或连接。"; }
            PostMessageW(window, finished, 0, 0);
        });
    }

    void lockSpace(int index) {
        if (index == 0) browserNotice.clear();
        locking = false;
        spaces[index] = {};
        clearDetail();
        refresh();
    }

    void openFolder() {
        auto& space = spaces[0];
        if (selectedKind() != "folder") return;
        space.folder = space.selected;
        space.selected.clear();
        SetWindowTextW(control(searchBox), L"");
        refresh();
    }

    void edit(std::string kind, bool fresh) {
        auto index = dataIndex();
        auto& space = spaces[index];
        if (!space.vault || kind.empty()) return;
        Entry value;
        if (fresh) { value.kind = kind; value.parent = space.folder; }
        else value = space.vault->detail(space.selected);

        std::vector<Field> fields{{L"标题", wide(value.title)}};
        if (kind != "folder") fields.emplace_back(L"网址", wide(value.url));
        if (kind == "login") {
            fields.emplace_back(L"用户名", wide(value.username));
            fields.emplace_back(L"密码", wide(value.password), true);
        }
        fields.emplace_back(L"备注", wide(value.notes));
        std::vector<std::string> destinations;
        if (index == 0) {
            Field parent(L"所在目录");
            parent.choices.push_back(L"全部收藏");
            destinations.push_back({});
            for (const auto& folder : folders) if (!folder.id.empty() && folder.id != value.id) {
                parent.choices.push_back(std::wstring(folder.indent * 2, L' ') + folder.title);
                destinations.push_back(folder.id);
                if (folder.id == value.parent) parent.index = static_cast<int>(destinations.size()) - 1;
            }
            fields.push_back(std::move(parent));
        }
        if (!value.editable()) {
            MessageBoxW(window, (wide(value.title) + L"\n\n" + wide(value.notes)).c_str(), L"条目详情", MB_OK);
            return;
        }
        bool accepted = form(fresh ? L"新建条目" : L"编辑条目", L"保存", fields);
        if (accepted) {
            size_t field = 0;
            value.title = utf8(fields[field++].value);
            if (kind != "folder") value.url = utf8(fields[field++].value);
            if (kind == "login") {
                value.username = utf8(fields[field++].value);
                Secret password(fields[field++].value);
                value.password = password.value;
            }
            value.notes = utf8(fields[field++].value);
            if (index == 0 && fields[field].index >= 0)
                value.parent = destinations.at(static_cast<size_t>(fields[field].index));
            space.selected = space.vault->save(value);
            saved(index);
        }
        if (!value.password.empty()) SecureZeroMemory(value.password.data(), value.password.size());
        for (auto& field : fields) if (field.secret && !field.value.empty())
            SecureZeroMemory(field.value.data(), field.value.size() * sizeof(wchar_t));
    }

    void saved(int index) {
        spaces[index].status = L"已保存到本机";
        refresh();
        if (spaces[index].remote) sync(index, true);
    }
};

LRESULT CALLBACK mainProc(HWND window, UINT message, WPARAM w, LPARAM l) {
    auto app = reinterpret_cast<App*>(GetWindowLongPtrW(window, GWLP_USERDATA));
    if (message == WM_NCCREATE) {
        app = static_cast<App*>(reinterpret_cast<CREATESTRUCTW*>(l)->lpCreateParams);
        app->window = window;
        SetWindowLongPtrW(window, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(app));
    }
    if (!app) return DefWindowProcW(window, message, w, l);
    try {
        switch (message) {
        case WM_CREATE: app->initialize(); return 0;
        case WM_SIZE: app->layout(); return 0;
        case WM_GETMINMAXINFO: {
            auto lengths = reinterpret_cast<MINMAXINFO*>(l);
            lengths->ptMinTrackSize = {app->px(minWidth), app->px(minHeight)};
            return 0;
        }
        case WM_DPICHANGED: {
            app->fonts.set(LOWORD(w));
            EnumChildWindows(window, [](HWND child, LPARAM l) -> BOOL {
                send(child, WM_SETFONT, reinterpret_cast<WPARAM>(reinterpret_cast<Fonts*>(l)->body), TRUE);
                return TRUE;
            }, reinterpret_cast<LPARAM>(&app->fonts));
            const auto* bounds = reinterpret_cast<RECT*>(l);
            SetWindowPos(window, nullptr, bounds->left, bounds->top, bounds->right-bounds->left,
                bounds->bottom-bounds->top, SWP_NOACTIVATE | SWP_NOZORDER);
            app->refresh();
            return 0;
        }
        case WM_PAINT: app->paint(); return 0;
        case WM_PRINTCLIENT: app->background(reinterpret_cast<HDC>(w)); return 0;
        case WM_ERASEBKGND: return 1;
        case WM_COMMAND: app->onCommand(LOWORD(w), HIWORD(w)); return 0;
        case WM_DRAWITEM: return app->ownerDraw(*reinterpret_cast<DRAWITEMSTRUCT*>(l));
        case WM_MEASUREITEM:
            reinterpret_cast<MEASUREITEMSTRUCT*>(l)->itemHeight = app->px(48);
            return TRUE;
        case WM_CTLCOLORLISTBOX:
            SetBkColor(reinterpret_cast<HDC>(w), paper);
            SetTextColor(reinterpret_cast<HDC>(w), ink);
            return reinterpret_cast<LRESULT>(app->theme.canvas);
        case WM_CTLCOLOREDIT:
            SetTextColor(reinterpret_cast<HDC>(w), ink);
            SetBkColor(reinterpret_cast<HDC>(w), white);
            return reinterpret_cast<LRESULT>(app->theme.input);
        case WM_TIMER: app->tick(); return 0;
        case WM_WTSSESSION_CHANGE:
            if (w == WTS_SESSION_LOCK || w == WTS_SESSION_LOGOFF ||
                w == WTS_CONSOLE_DISCONNECT || w == WTS_REMOTE_DISCONNECT) app->lockAll();
            return 0;
        case WM_POWERBROADCAST:
            if (w == PBT_APMSUSPEND) app->lockAll();
            return TRUE;
        case finished: app->complete(); return 0;
        case browserMessage: app->receiveBrowser(); return 0;
#ifdef PBSYNC_UI_CAPTURE
        case WM_APP + 17: return app->capture();
#endif
        case WM_CLOSE: app->requestClose(); return 0;
        case WM_DESTROY:
            WTSUnRegisterSessionNotification(window);
            PostQuitMessage(0);
            return 0;
        }
    } catch (const Fault& error) {
        if (message == WM_CREATE) {
            MessageBoxW(window, wide(error.what()).c_str(), L"PBsync", MB_OK | MB_ICONERROR);
            return -1;
        }
        app->error(wide(error.what()));
    } catch (const std::exception&) {
        app->error(L"操作未完成，请检查文件或网络。");
    }
    return DefWindowProcW(window, message, w, l);
}
}

int WINAPI wWinMain(HINSTANCE instance, HINSTANCE, PWSTR, int show) {
    if (isBrowserHost()) {
        const wchar_t* local = _wgetenv(L"LOCALAPPDATA");
        if (!local || !*local) return 1;
        try { return runBrowserHost(Path(local) / L"PBsync"); }
        catch (...) { return 1; }
    }
    SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
    INITCOMMONCONTROLSEX controls{sizeof(controls), ICC_STANDARD_CLASSES};
    InitCommonControlsEx(&controls);
    WNDCLASSW cls{};
    cls.lpfnWndProc = mainProc;
    cls.hInstance = instance;
    cls.hCursor = LoadCursorW(nullptr, IDC_ARROW);
    cls.hIcon = LoadIconW(nullptr, IDI_APPLICATION);
    cls.lpszClassName = L"PBsyncMainWindow";
    if (!RegisterClassW(&cls)) return 1;

    App app;
    auto window = CreateWindowExW(WS_EX_CONTROLPARENT, cls.lpszClassName, L"PBsync", WS_OVERLAPPEDWINDOW | WS_CLIPCHILDREN,
        CW_USEDEFAULT, CW_USEDEFAULT, 1160, 742, nullptr, nullptr, instance, &app);
    if (!window) return 1;
    ShowWindow(window, show == SW_HIDE ? SW_SHOWNORMAL : show);
    // 系统可以用启动信息覆盖第一次显示请求。
    if (!IsWindowVisible(window)) ShowWindow(window, SW_SHOWNORMAL);
    UpdateWindow(window);
    MSG message{};
    int result;
    while ((result = GetMessageW(&message, nullptr, 0, 0)) > 0) {
        if (!IsDialogMessageW(window, &message)) {
            TranslateMessage(&message);
            DispatchMessageW(&message);
        }
    }
    return result < 0 ? 1 : static_cast<int>(message.wParam);
}
