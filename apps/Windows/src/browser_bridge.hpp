#pragma once
#include <windows.h>
#include <functional>
#include "vault.hpp"

namespace pb {
constexpr UINT browserMessage = WM_APP + 2;
constexpr size_t browserResponseLimit = 1024 * 1024;

class BrowserBridge {
public:
    BrowserBridge(HWND app, const Path& profile);
    ~BrowserBridge();
    BrowserBridge(const BrowserBridge&) = delete;
    BrowserBridge& operator=(const BrowserBridge&) = delete;

    void receive(const std::function<Bytes()>& pairingKey, const std::function<Json(const Json&)>& action);
    bool paired() const;
private:
    struct Impl;
    std::unique_ptr<Impl> impl_;
};

// 浏览器用同一个 EXE 启动本机消息宿主，参数由浏览器提供。
bool isBrowserHost();
int runBrowserHost(const Path& profile);
}
