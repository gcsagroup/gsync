#include "browser_bridge.hpp"
#include <shellapi.h>
#include <algorithm>
#include <array>
#include <ctime>
#include <map>
#include <mutex>
#include <thread>

namespace pb {
namespace {
constexpr size_t requestLimit = 8 * 1024 * 1024;
constexpr int64_t tokenLifetime = 120;
constexpr DWORD ioTimeout = 8000;

struct WinHandle {
    HANDLE handle{};
    explicit WinHandle(HANDLE value) : handle(value) {}
    ~WinHandle() { if (valid()) CloseHandle(handle); }
    WinHandle(const WinHandle&) = delete;
    WinHandle& operator=(const WinHandle&) = delete;
    bool valid() const { return handle && handle != INVALID_HANDLE_VALUE; }
};

Bytes packBytes(std::string_view value) { return Bytes(value.begin(), value.end()); }

std::wstring pipeName(const Path& profile) {
    auto location = profile.lexically_normal().wstring();
    CharLowerBuffW(location.data(), static_cast<DWORD>(location.size()));
    auto hash = sha256(packBytes(utf8(location)));
    std::wstring pipe = LR"(\\.\pipe\GCSA.PBsync.Bookmarks.)";
    for (auto byte : hash) {
        pipe += L"0123456789abcdef"[byte >> 4];
        pipe += L"0123456789abcdef"[byte & 15];
    }
    return pipe;
}

bool await(HANDLE pipe, OVERLAPPED& operation, BOOL complete, DWORD& moved, HANDLE stop, DWORD timeout) {
    if (complete) return GetOverlappedResult(pipe, &operation, &moved, FALSE);
    if (GetLastError() != ERROR_IO_PENDING) return false;
    std::array<HANDLE, 2> tokens{operation.hEvent, stop};
    if (WaitForMultipleObjects(stop ? 2 : 1, tokens.data(), FALSE, timeout) == WAIT_OBJECT_0) {
        return GetOverlappedResult(pipe, &operation, &moved, FALSE);
    }
    CancelIoEx(pipe, &operation);
    GetOverlappedResult(pipe, &operation, &moved, TRUE);
    return false;
}

bool exact(HANDLE handle, void* raw, size_t size, bool write, bool overlapped, HANDLE stop) {
    if (!handle || handle == INVALID_HANDLE_VALUE) return false;
    auto buffer = static_cast<PUCHAR>(raw);
    WinHandle event(overlapped ? CreateEventW(nullptr, TRUE, FALSE, nullptr) : nullptr);
    if (overlapped && !event.valid()) return false;
    while (size) {
        const auto count = static_cast<DWORD>(std::min(size, size_t(65536)));
        OVERLAPPED operation{};
        operation.hEvent = event.handle;
        if (overlapped) ResetEvent(event.handle);
        DWORD moved{};
        bool done = write ? WriteFile(handle, buffer, count, &moved, overlapped ? &operation : nullptr) :
            ReadFile(handle, buffer, count, &moved, overlapped ? &operation : nullptr);
        if (overlapped) done = await(handle, operation, done, moved, stop, ioTimeout);
        if (!done || !moved || moved > count) return false;
        buffer += moved;
        size -= moved;
    }
    return true;
}

Bytes receiveFrame(HANDLE pipe, size_t limit, bool overlapped, HANDLE stop = nullptr) {
    uint32_t length{};
    if (!exact(pipe, &length, sizeof(length), false, overlapped, stop) || !length || length > limit) return {};
    Bytes message(length);
    if (!exact(pipe, message.data(), length, false, overlapped, stop)) return {};
    return message;
}

bool sendFrame(HANDLE pipe, Bytes& data, size_t limit, bool overlapped, HANDLE stop = nullptr) {
    if (data.empty() || data.size() > limit) return false;
    auto length = static_cast<uint32_t>(data.size());
    return exact(pipe, &length, sizeof(length), true, overlapped, stop) &&
        exact(pipe, data.data(), data.size(), true, overlapped, stop);
}

Json textError(std::string_view error) { return Json{{"error", error}}; }
Bytes report(std::string_view error) { return packBytes(textError(error).dump()); }

Json wireJSON(const Bytes& input) {
    return Json::parse(input, [](int depth, Json::parse_event_t, Json&) {
        if (depth > 32) throw Fault("浏览器请求的结构超过上限。");
        return true;
    });
}

std::string nonce(std::string value) {
    if (value.size() != 36) throw Fault("浏览器请求身份无效。");
    for (size_t i = 0; i < value.size(); ++i) {
        auto& c = value[i];
        if (c >= 'A' && c <= 'F') c += 'a' - 'A';
        bool dash = i == 8 || i == 13 || i == 18 || i == 23;
        if (dash ? c != '-' : !((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f'))) throw Fault("浏览器请求身份无效。");
    }
    return value;
}

std::string wireContext(bool response, std::string_view id, int64_t issued) {
    return std::string(response ? "PBsync-bridge|1|resp|" : "PBsync-bridge|1|req|") +
        std::string(id) + "|" + std::to_string(issued);
}

struct KeyWipe {
    Bytes& value;
    ~KeyWipe() { if (!value.empty()) SecureZeroMemory(value.data(), value.size()); }
};

struct Pending {
    Bytes request, response;
    WinHandle done{CreateEventW(nullptr, TRUE, FALSE, nullptr)};
};

bool chromiumOrigin(std::wstring_view value) {
    constexpr std::wstring_view prefix = L"chrome-extension://";
    if (!value.starts_with(prefix)) return false;
    value.remove_prefix(prefix.size());
    if (value.ends_with(L'/')) value.remove_suffix(1);
    return value.size() == 32 && std::ranges::all_of(value, [](auto c) { return c >= L'a' && c <= L'p'; });
}
}

struct BrowserBridge::Impl {
    HWND app;
    Path pairingFile;
    WinHandle stop{CreateEventW(nullptr, TRUE, FALSE, nullptr)};
    WinHandle pipe;
    std::thread worker;
    std::mutex mutex;
    std::shared_ptr<Pending> pending;
    std::map<std::string, int64_t> seen;

    Impl(HWND window, const Path& profile)
        : app(window), pairingFile(profile / L"bookmarks-pairing.grant"),
          pipe(CreateNamedPipeW(pipeName(profile).c_str(),
            PIPE_ACCESS_DUPLEX | FILE_FLAG_OVERLAPPED | FILE_FLAG_FIRST_PIPE_INSTANCE,
            PIPE_TYPE_BYTE | PIPE_READMODE_BYTE | PIPE_WAIT | PIPE_REJECT_REMOTE_CLIENTS, 1, 65536, 65536, 0, nullptr)) {
        if (!stop.valid() || !pipe.valid()) throw Fault("无法启动浏览器连接，请检查是否已有 PBsync 窗口。");
        worker = std::thread([this] { accept(); });
    }

    ~Impl() {
        SetEvent(stop.handle);
        if (worker.joinable()) worker.join();
    }

    void accept() {
        WinHandle event(CreateEventW(nullptr, TRUE, FALSE, nullptr));
        if (!event.valid()) return;
        while (WaitForSingleObject(stop.handle, 0) != WAIT_OBJECT_0) {
            ResetEvent(event.handle);
            OVERLAPPED process{};
            process.hEvent = event.handle;
            DWORD count{};
            bool connected = ConnectNamedPipe(pipe.handle, &process);
            if (!connected && GetLastError() == ERROR_PIPE_CONNECTED) connected = true;
            else connected = await(pipe.handle, process, connected, count, stop.handle, INFINITE);
            if (!connected) break;
            try {
                auto request = receiveFrame(pipe.handle, requestLimit, true, stop.handle);
                if (!request.empty()) {
                    auto response = dispatch(std::move(request));
                    sendFrame(pipe.handle, response, browserResponseLimit, true, stop.handle);
                }
            } catch (...) {
                auto error = report("本机浏览器连接失败。");
                sendFrame(pipe.handle, error, browserResponseLimit, true, stop.handle);
            }
            // 等浏览器读完最后一个请求的响应。客户端关闭连接后才断开服务实例。
            if (WaitForSingleObject(stop.handle, 0) != WAIT_OBJECT_0) {
                unsigned char close{};
                exact(pipe.handle, &close, 1, false, true, stop.handle);
            }
            DisconnectNamedPipe(pipe.handle);
        }
    }

    Bytes dispatch(Bytes request) {
        auto job = std::make_shared<Pending>();
        job->request = std::move(request);
        if (!job->done.valid()) return report("本机浏览器连接失败。");
        {
            std::scoped_lock guard(mutex);
            pending = job;
        }
        HANDLE tokens[]{job->done.handle, stop.handle};
        bool sent = PostMessageW(app, browserMessage, 0, 0);
        bool replied = sent && WaitForMultipleObjects(2, tokens, FALSE, ioTimeout) == WAIT_OBJECT_0;
        std::scoped_lock guard(mutex);
        if (pending == job) pending.reset();
        return replied ? std::move(job->response) : report("PBsync 正在处理，请稍后再试。");
    }

    Bytes answer(const Bytes& request, const std::function<Bytes()>& pairingKey,
        const std::function<Json(const Json&)>& action) {
        try {
            auto wire = wireJSON(request);
            Bytes secret;
            try { secret = pairingKey(); }
            catch (const Fault& error) { return report(error.what()); }
            if (secret.size() != 32) return report("请在 PBsync 同步页复制收藏夹配对密钥。");
            KeyWipe clearKey{secret};
            auto id = nonce(wire.at("id").get<std::string>());
            if (!wire.at("issuedAt").is_number_integer()) return report("浏览器请求时间无效。");
            auto issued = wire.at("issuedAt").get<int64_t>();
            auto now = static_cast<int64_t>(std::time(nullptr));
            if (issued < now - tokenLifetime || issued > now + tokenLifetime) return report("浏览器请求已超时。");
            auto clear = decryptAuthenticated(secret, decode64(wire.at("sealed").get<std::string>()), wireContext(false, id, issued));
            Json result;
            try {
                std::erase_if(seen, [&](const auto& entry) { return entry.second < now - tokenLifetime; });
                if (seen.size() >= 4096 || !seen.emplace(id, issued).second) throw Fault("浏览器请求已经处理。");
                result = Json{{"ok", true}, {"payload", action(wireJSON(clear))}};
            } catch (const Fault& error) { result = Json{{"ok", false}, {"error", error.what()}}; }
            catch (...) { result = Json{{"ok", false}, {"error", "浏览器收藏夹请求无效。"}}; }
            SecureZeroMemory(clear.data(), clear.size());
            auto pack = [&](const Json& value) {
                return packBytes(Json{{"id", id}, {"issuedAt", issued},
                    {"sealed", base64(encryptAuthenticated(secret, packBytes(value.dump()), wireContext(true, id, issued)))}}.dump());
            };
            auto response = pack(result);
            if (response.size() > browserResponseLimit) {
                response = pack(Json{{"ok", false}, {"error", "收藏夹超过浏览器单次响应上限。"}});
            }
            return response;
        } catch (...) { return report("浏览器配对密钥无效，请重新核对。"); }
    }
};

BrowserBridge::BrowserBridge(HWND window, const Path& profile) : impl_(std::make_unique<Impl>(window, profile)) {}
BrowserBridge::~BrowserBridge() = default;

bool BrowserBridge::paired() const {
    std::error_code error;
    return std::filesystem::is_regular_file(impl_->pairingFile, error);
}

void BrowserBridge::receive(const std::function<Bytes()>& pairingKey, const std::function<Json(const Json&)>& action) {
    std::shared_ptr<Pending> job;
    {
        std::scoped_lock guard(impl_->mutex);
        job = std::exchange(impl_->pending, {});
    }
    if (!job) return;
    auto response = impl_->answer(job->request, pairingKey, action);
    {
        std::scoped_lock guard(impl_->mutex);
        job->response = std::move(response);
    }
    SetEvent(job->done.handle);
}

bool isBrowserHost() {
    int count{};
    auto argv = CommandLineToArgvW(GetCommandLineW(), &count);
    if (!argv) return false;
    bool browser = count >= 2 && chromiumOrigin(argv[1]);
    if (!browser && count == 3) {
        browser = std::wstring_view(argv[1]).ends_with(L".json") &&
            std::wstring_view(argv[2]) == L"pbsync-bookmarks@gcsa.local";
    }
    LocalFree(argv);
    return browser;
}

int runBrowserHost(const Path& profile) {
    auto in = GetStdHandle(STD_INPUT_HANDLE), out = GetStdHandle(STD_OUTPUT_HANDLE);
    const auto address = pipeName(profile);
    for (;;) {
        auto request = receiveFrame(in, requestLimit, false);
        if (request.empty()) break;
        Bytes response;
        try {
            auto value = wireJSON(request);
            if (value.contains("nativeBookmarkRoute")) response = packBytes(Json{{"outcome", "unsupported"}}.dump());
            else {
                if (!WaitNamedPipeW(address.c_str(), 2000)) throw Fault("请先打开并解锁 Windows PBsync。");
                WinHandle pipe(CreateFileW(address.c_str(), GENERIC_READ | GENERIC_WRITE, 0, nullptr,
                    OPEN_EXISTING, FILE_FLAG_OVERLAPPED | SECURITY_SQOS_PRESENT | SECURITY_IDENTIFICATION, nullptr));
                if (!pipe.valid() || !sendFrame(pipe.handle, request, requestLimit, true)) throw Fault("PBsync 正在处理，请稍后再试。");
                response = receiveFrame(pipe.handle, browserResponseLimit, true);
            }
        } catch (const Fault& error) { response = report(error.what()); }
        catch (...) { response = report("浏览器请求无效。"); }
        if (response.empty()) response = report("没有收到 PBsync 的响应。");
        if (!sendFrame(out, response, browserResponseLimit, false)) return 1;
    }
    return 0;
}
}
