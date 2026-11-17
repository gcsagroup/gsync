#pragma once
#include <windows.h>
#include <atomic>
#include "vault.hpp"

namespace pb {
bool verifyWindowsHello(HWND window, const wchar_t* reason, const std::atomic_bool* cancelled = nullptr);

class SessionUnlockKey {
public:
    explicit SessionUnlockKey(Bytes key);
    ~SessionUnlockKey();
    SessionUnlockKey(const SessionUnlockKey&) = delete;
    SessionUnlockKey& operator=(const SessionUnlockKey&) = delete;
    std::shared_ptr<Vault> openAfterVerification(HWND window, const Path& file, bool bookmarks,
                                                const std::atomic_bool* cancelled = nullptr) const;

private:
    Bytes protectedKey;
};
}
