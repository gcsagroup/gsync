#include "vault.hpp"
#include <windows.h>
#include <winhttp.h>
#include <shlwapi.h>
#include <xmllite.h>

namespace pb {
namespace {
struct Http {
    HINTERNET value{};
    explicit Http(HINTERNET handle) : value(handle) {
        if (!value) throw Fault("无法连接 WebDAV。");
    }
    ~Http() { WinHttpCloseHandle(value); }
    Http(const Http&) = delete;
    Http& operator=(const Http&) = delete;
};

template<class T> struct Com {
    T* value{};
    ~Com() { if (value) value->Release(); }
    T* operator->() const { return value; }
};

struct Address {
    std::wstring host, path;
    INTERNET_PORT port{};
    bool secure{};
};

Address parseURL(const std::wstring& url) {
    URL_COMPONENTS c{};
    c.dwStructSize = sizeof(c);
    c.dwSchemeLength = c.dwHostNameLength = c.dwUserNameLength = c.dwPasswordLength =
        c.dwUrlPathLength = c.dwExtraInfoLength = DWORD(-1);
    if (!WinHttpCrackUrl(url.c_str(), static_cast<DWORD>(url.size()), 0, &c) ||
        (c.nScheme != INTERNET_SCHEME_HTTPS && c.nScheme != INTERNET_SCHEME_HTTP) ||
        !c.dwHostNameLength || c.dwUserNameLength || c.dwPasswordLength || c.dwExtraInfoLength) {
        throw Fault("请输入完整的 HTTPS WebDAV 目录。");
    }
    Address address{std::wstring(c.lpszHostName, c.dwHostNameLength),
        c.dwUrlPathLength ? std::wstring(c.lpszUrlPath, c.dwUrlPathLength) : L"/",
        c.nPort, c.nScheme == INTERNET_SCHEME_HTTPS};
    if (!address.secure && address.host != L"127.0.0.1" && _wcsicmp(address.host.c_str(), L"localhost") != 0 &&
        address.host != L"[::1]" && address.host != L"::1") throw Fault("WebDAV 需要 HTTPS。");
    return address;
}

std::wstring trim(std::wstring_view value) {
    auto first = value.find_first_not_of(L" \r\n\t");
    return first == std::wstring_view::npos ? L"" :
        std::wstring(value.substr(first, value.find_last_not_of(L" \r\n\t") - first + 1));
}

std::wstring decodePath(const std::wstring& path) {
    wchar_t buffer[8192]{};
    DWORD length = static_cast<DWORD>(std::size(buffer));
    if (FAILED(UrlUnescapeW(const_cast<wchar_t*>(path.c_str()), buffer, &length, URL_UNESCAPE_AS_UTF8)) ||
        std::wstring_view(buffer, length).find(L'\0') != std::wstring_view::npos) throw Fault("WebDAV 目录格式无效。");
    return {buffer, length};
}

struct Response { DWORD code; Bytes data; };

class Dav final : public Storage {
public:
    Dav(std::wstring_view address, std::wstring_view user, std::wstring_view password)
        : address_(parseURL(trim(address))), session_(WinHttpOpen(L"PBsync/5 Windows",
            address_.secure ? WINHTTP_ACCESS_TYPE_AUTOMATIC_PROXY : WINHTTP_ACCESS_TYPE_NO_PROXY,
            WINHTTP_NO_PROXY_NAME, WINHTTP_NO_PROXY_BYPASS, 0)),
          server_(WinHttpConnect(session_.value, address_.host.c_str(), address_.port, 0)) {
        if (!address_.path.ends_with(L'/')) address_.path += L'/';
        decodedRoot_ = decodePath(address_.path);
        auto credentials = utf8(user) + ":" + utf8(password);
        Bytes raw(credentials.begin(), credentials.end());
        auto encoded = base64(raw);
        authorization_ = L"Authorization: Basic " + wide(encoded) + L"\r\n";
        if (!raw.empty()) SecureZeroMemory(raw.data(), raw.size());
        SecureZeroMemory(credentials.data(), credentials.size());
        SecureZeroMemory(encoded.data(), encoded.size());
        if (!WinHttpSetTimeouts(session_.value, 10000, 10000, 15000, 20000)) throw Fault("WebDAV 连接初始化失败。");
    }

    ~Dav() override {
        if (!authorization_.empty()) SecureZeroMemory(authorization_.data(), authorization_.size() * sizeof(wchar_t));
    }

    Bytes read(std::string_view name) override {
        auto response = send(L"GET", name, {}, {}, maxObject);
        check(response.code);
        return std::move(response.data);
    }

    bool create(std::string_view name, const Bytes& data) override {
        auto response = send(L"PUT", name, L"If-None-Match: *\r\nContent-Type: application/octet-stream\r\n", data, 65536);
        if (response.code == 409 || response.code == 412) return false;
        check(response.code);
        if (read(name) != data) throw Fault("WebDAV 写入回读校验失败。");
        return true;
    }

    std::set<std::string> list() override {
        const std::string body = R"(<d:propfind xmlns:d="DAV:"><d:prop><d:resourcetype/></d:prop></d:propfind>)";
        auto response = send(L"PROPFIND", "", L"Depth: 1\r\nContent-Type: application/xml; charset=utf-8\r\n",
            Bytes(body.begin(), body.end()), 8 * 1024 * 1024);
        check(response.code);

        Com<IStream> stream;
        stream.value = SHCreateMemStream(response.data.data(), static_cast<UINT>(response.data.size()));
        Com<IXmlReader> reader;
        if (!stream.value || FAILED(CreateXmlReader(__uuidof(IXmlReader), reinterpret_cast<void**>(&reader.value), nullptr)) ||
            FAILED(reader->SetProperty(XmlReaderProperty_DtdProcessing, DtdProcessing_Prohibit)) ||
            FAILED(reader->SetProperty(XmlReaderProperty_MaxElementDepth, 32)) ||
            FAILED(reader->SetInput(stream.value))) throw Fault("WebDAV 目录清单无效。");

        std::set<std::string> names;
        XmlNodeType type{};
        HRESULT result;
        bool href = false;
        std::wstring text;
        while ((result = reader->Read(&type)) == S_OK) {
            if (type == XmlNodeType_Element) {
                const wchar_t *name{}, *ns{};
                if (SUCCEEDED(reader->GetLocalName(&name, nullptr)) && SUCCEEDED(reader->GetNamespaceUri(&ns, nullptr)) &&
                    std::wstring_view(name) == L"href" && std::wstring_view(ns) == L"DAV:" && !reader->IsEmptyElement()) {
                    href = true;
                    text.clear();
                }
            } else if (href && (type == XmlNodeType_Text || type == XmlNodeType_CDATA)) {
                const wchar_t* value{};
                UINT length{};
                if (SUCCEEDED(reader->GetValue(&value, &length))) text.append(value, length);
            } else if (href && type == XmlNodeType_EndElement) {
                href = false;
                auto name = child(trim(text));
                if (objectName(name)) names.insert(std::move(name));
            }
        }
        if (result != S_FALSE) throw Fault("WebDAV 目录清单无效。");
        return names;
    }

private:
    static void check(DWORD code) {
        if (code < 200 || code >= 300) throw Fault("WebDAV 请求失败（" + std::to_string(code) + "）。");
    }

    std::string child(const std::wstring& href) const {
        if (href.empty() || href.find_first_of(L"?#\\") != std::wstring::npos) return {};
        std::wstring path = href;
        if (href.find(L"://") != std::wstring::npos) {
            try {
                auto item = parseURL(href);
                if (item.port != address_.port || item.secure != address_.secure ||
                    _wcsicmp(item.host.c_str(), address_.host.c_str()) != 0) return {};
                path = item.path;
            } catch (const Fault&) { return {}; }
        } else if (href.starts_with(L"//")) return {};
        else if (!href.starts_with(L'/')) path = address_.path + href;
        auto decoded = decodePath(path);
        if (!decoded.starts_with(decodedRoot_)) return {};
        return utf8(std::wstring_view(decoded).substr(decodedRoot_.size()));
    }

    Response send(LPCWSTR method, std::string_view name, std::wstring_view extra, const Bytes& body, size_t limit) {
        if (!name.empty() && !objectName(name)) throw Fault("WebDAV 对象名称无效。");
        auto path = address_.path + wide(name);
        Http request(WinHttpOpenRequest(server_.value, method, path.c_str(), nullptr, WINHTTP_NO_REFERER,
            WINHTTP_DEFAULT_ACCEPT_TYPES, address_.secure ? WINHTTP_FLAG_SECURE : 0));
        DWORD disabled = WINHTTP_DISABLE_REDIRECTS | WINHTTP_DISABLE_COOKIES | WINHTTP_DISABLE_AUTHENTICATION;
        auto headers = authorization_ + std::wstring(extra);
        DWORD size = static_cast<DWORD>(body.size());
        BOOL sent = WinHttpSetOption(request.value, WINHTTP_OPTION_DISABLE_FEATURE, &disabled, sizeof(disabled)) &&
            WinHttpSendRequest(request.value, headers.c_str(), static_cast<DWORD>(headers.size()), const_cast<PUCHAR>(body.data()), size, size, 0);
        SecureZeroMemory(headers.data(), headers.size() * sizeof(wchar_t));
        if (!sent || !WinHttpReceiveResponse(request.value, nullptr)) throw Fault("WebDAV 连接失败，请检查网络或证书。");

        Response response{};
        DWORD length = sizeof(response.code);
        if (!WinHttpQueryHeaders(request.value, WINHTTP_QUERY_STATUS_CODE | WINHTTP_QUERY_FLAG_NUMBER,
            WINHTTP_HEADER_NAME_BY_INDEX, &response.code, &length, WINHTTP_NO_HEADER_INDEX)) throw Fault("WebDAV 响应无效。");
        if (response.code < 200 || response.code >= 300) return response;
        unsigned char buffer[16384];
        for (;;) {
            DWORD read{};
            if (!WinHttpReadData(request.value, buffer, sizeof(buffer), &read)) throw Fault("WebDAV 读取失败。");
            if (!read) break;
            if (read > limit - response.data.size()) throw Fault("WebDAV 对象超过大小上限。");
            response.data.insert(response.data.end(), buffer, buffer + read);
        }
        return response;
    }

    Address address_;
    Http session_, server_;
    std::wstring decodedRoot_, authorization_;
};
}

std::shared_ptr<Storage> webdav(std::wstring_view address, std::wstring_view user, std::wstring_view password) {
    return std::make_shared<Dav>(address, user, password);
}
}
