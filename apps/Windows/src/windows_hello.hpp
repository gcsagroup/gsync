#pragma once
#include <windows.h>
#include "vault.hpp"

namespace pb {
bool verifyWindowsHello(HWND window, const wchar_t* reason);

class SessionUnlockKey {
public:
    explicit SessionUnlockKey(Bytes key);
    ~SessionUnlockKey();
    SessionUnlockKey(const SessionUnlockKey&) = delete;
    SessionUnlockKey& operator=(const SessionUnlockKey&) = delete;
    std::shared_ptr<Vault> openAfterVerification(HWND window, const Path& file, bool bookmarks) const;

private:
    Bytes protectedKey;
};
}
