#include "windows_hello.hpp"
#include <roapi.h>
#include <wincrypt.h>
#include <winstring.h>
// MinGW 14 将 boolean 与 BYTE 声明为同一类型，避免生成重复且未用到的 IReference。
#ifdef __MINGW32__
#define ____FIReference_1_boolean_INTERFACE_DEFINED__
#endif
#include <windows.security.credentials.ui.h>

namespace pb {
namespace {
using namespace ABI::Windows::Foundation;
using namespace ABI::Windows::Security::Credentials::UI;

// MinGW 尚未提供此桌面互操作头文件。接口定义与 Windows SDK 保持一致。
struct ConsentForWindow : IInspectable {
    virtual HRESULT STDMETHODCALLTYPE RequestVerificationForWindowAsync(
        HWND window, HSTRING message, REFIID resultInterface, void** operation) = 0;
};
constexpr GUID consentForWindowID{0x39e050c3, 0x4e74, 0x441a, {0x8d, 0xc0, 0xb8, 0x11, 0x04, 0xdf, 0x94, 0x9c}};

template<class I> struct ComRelease {
    void operator()(I* value) const { value->Release(); }
};
template<class I> using Com = std::unique_ptr<I, ComRelease<I>>;

struct Apartment {
    HRESULT status = RoInitialize(RO_INIT_MULTITHREADED);
    ~Apartment() { if (SUCCEEDED(status)) RoUninitialize(); }
};

template<class Result>
std::optional<Result> awaitResult(IAsyncOperation<Result>* raw, DWORD timeout) {
    Com<IAsyncOperation<Result>> operation(raw);
    if (!operation) return {};
    IAsyncInfo* rawInfo{};
    if (FAILED(operation->QueryInterface(__uuidof(IAsyncInfo), reinterpret_cast<void**>(&rawInfo)))) return {};
    Com<IAsyncInfo> info(rawInfo);
    const auto started = GetTickCount64();
    AsyncStatus status{};
    while (SUCCEEDED(info->get_Status(&status)) && status == Started) {
        if (GetTickCount64() - started >= timeout) {
            info->Cancel();
            return {};
        }
        Sleep(50);
    }
    Result result{};
    if (status == Completed && SUCCEEDED(operation->GetResults(&result))) return result;
    return {};
}
}

bool verifyWindowsHello(HWND window, const wchar_t* reason) {
    Apartment apartment;
    if (FAILED(apartment.status)) return false;
    constexpr wchar_t verifier[] = L"Windows.Security.Credentials.UI.UserConsentVerifier";
    HSTRING_HEADER classHeader{}, reasonHeader{};
    HSTRING className{}, message{};
    if (FAILED(WindowsCreateStringReference(verifier, std::size(verifier) - 1, &classHeader, &className)) ||
        FAILED(WindowsCreateStringReference(reason, static_cast<UINT32>(wcslen(reason)), &reasonHeader, &message))) {
        return false;
    }
    IUserConsentVerifierStatics* rawStatics{};
    if (FAILED(RoGetActivationFactory(className, __uuidof(IUserConsentVerifierStatics),
                                       reinterpret_cast<void**>(&rawStatics)))) return false;
    Com<IUserConsentVerifierStatics> statics(rawStatics);
    IAsyncOperation<UserConsentVerifierAvailability>* availability{};
    if (FAILED(statics->CheckAvailabilityAsync(&availability)) ||
        awaitResult(availability, 5000) != UserConsentVerifierAvailability_Available) return false;
    ConsentForWindow* rawConsent{};
    if (FAILED(statics->QueryInterface(consentForWindowID, reinterpret_cast<void**>(&rawConsent)))) return false;
    Com<ConsentForWindow> consent(rawConsent);
    using Operation = IAsyncOperation<UserConsentVerificationResult>;
    Operation* result{};
    if (FAILED(consent->RequestVerificationForWindowAsync(window, message, __uuidof(Operation),
                                                           reinterpret_cast<void**>(&result)))) return false;
    return awaitResult(result, 90000) == UserConsentVerificationResult_Verified;
}

SessionUnlockKey::SessionUnlockKey(Bytes key) : protectedKey(std::move(key)) {
    if (protectedKey.size() == 32 &&
        CryptProtectMemory(protectedKey.data(), static_cast<DWORD>(protectedKey.size()), CRYPTPROTECTMEMORY_SAME_PROCESS)) {
        return;
    }
    SecureZeroMemory(protectedKey.data(), protectedKey.size());
    throw Fault("无法保存本次运行的 Windows Hello 解锁密钥。");
}

SessionUnlockKey::~SessionUnlockKey() { SecureZeroMemory(protectedKey.data(), protectedKey.size()); }

std::shared_ptr<Vault> SessionUnlockKey::openAfterVerification(HWND window, const Path& file, bool bookmarks) const {
    if (!verifyWindowsHello(window, L"解锁 PBsync 当前空间")) {
        throw Fault("Windows Hello 未完成，可使用主密码或恢复密钥。");
    }
    auto clear = protectedKey;
    struct Wipe { Bytes& data; ~Wipe() { SecureZeroMemory(data.data(), data.size()); } } wipe{clear};
    if (!CryptUnprotectMemory(clear.data(), static_cast<DWORD>(clear.size()), CRYPTPROTECTMEMORY_SAME_PROCESS)) {
        throw Fault("本次运行的解锁密钥不可用，请使用主密码。");
    }
    return Vault::openWithDeviceKey(file, clear, bookmarks);
}
}
