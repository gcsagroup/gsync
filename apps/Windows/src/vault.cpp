#include "vault.hpp"
#include <windows.h>
#include <bcrypt.h>
#include <wincrypt.h>
#include <objbase.h>
#include <algorithm>
#include <array>
#include <chrono>
#include <fstream>
#include <limits>
#include <map>
#include <tuple>

namespace pb {
namespace {
constexpr size_t attachmentLimit = 10 * 1024 * 1024;
using Records = std::map<std::string, Json>;

void require(bool valid, const char* error = "保险库校验失败。") {
    if (!valid) throw Fault(error);
}

template<class T> void wipe(T& value) {
    if (!value.empty()) SecureZeroMemory(value.data(), value.size() * sizeof(typename T::value_type));
}
template<class T> struct Wipe {
    T& value;
    ~Wipe() { wipe(value); }
};

struct Handle {
    HANDLE value;
    explicit Handle(HANDLE handle) : value(handle) {
        require(handle != INVALID_HANDLE_VALUE, "无法访问本机保险库，可能有另一窗口正在写入。");
    }
    ~Handle() { CloseHandle(value); }
};

struct Algorithm {
    BCRYPT_ALG_HANDLE value{};
    explicit Algorithm(LPCWSTR name, ULONG flags = 0) {
        require(BCryptOpenAlgorithmProvider(&value, name, nullptr, flags) >= 0);
    }
    ~Algorithm() { BCryptCloseAlgorithmProvider(value, 0); }
};

struct Key {
    BCRYPT_KEY_HANDLE value{};
    ~Key() { if (value) BCryptDestroyKey(value); }
};

Bytes bytes(std::string_view input) { return Bytes(input.begin(), input.end()); }

Bytes digest(const Bytes& data) {
    Algorithm algorithm(BCRYPT_SHA256_ALGORITHM);
    Bytes result(32);
    require(BCryptHash(algorithm.value, nullptr, 0, const_cast<PUCHAR>(data.data()),
        static_cast<ULONG>(data.size()), result.data(), 32) >= 0);
    return result;
}

std::string hex(const Bytes& data) {
    std::string result;
    result.reserve(data.size() * 2);
    for (unsigned char byte : data) {
        result += "0123456789abcdef"[byte >> 4];
        result += "0123456789abcdef"[byte & 15];
    }
    return result;
}

std::string id(std::string_view value) {
    require(value.size() == 36);
    std::string result(value);
    for (size_t i = 0; i < result.size(); ++i) {
        char& c = result[i];
        if (i == 8 || i == 13 || i == 18 || i == 23) { require(c == '-'); continue; }
        if (c >= 'A' && c <= 'F') c += 'a' - 'A';
        require((c >= 'a' && c <= 'f') || (c >= '0' && c <= '9'));
    }
    return result;
}

std::string newID() {
    GUID guid{};
    require(SUCCEEDED(CoCreateGuid(&guid)));
    wchar_t value[40]{};
    require(StringFromGUID2(guid, value, 40) == 39);
    return utf8(std::wstring_view(value + 1, 36));
}

std::string str(const Json& parent, const char* field) { return parent.at(field).get<std::string>(); }
bool optional(const Json& parent, const char* field) { return parent.contains(field) && !parent[field].is_null(); }
std::string parentID(const Json& item) { return optional(item, "parentID") ? id(str(item, "parentID")) : ""; }

int64_t signedNumber(const Json& value) {
    require(value.is_number_integer());
    if (value.is_number_unsigned()) require(value.get<uint64_t>() <= INT64_MAX);
    return value.get<int64_t>();
}

uint64_t nonnegative(const Json& value) {
    require(value.is_number_integer());
    if (!value.is_number_unsigned()) require(value.get<int64_t>() >= 0);
    return value.get<uint64_t>();
}

auto timestamp(const Json& revision) {
    const auto& time = revision.at("time");
    return std::pair(signedNumber(time.at("milliseconds")), nonnegative(time.at("counter")));
}

auto priority(const Json& revision) {
    return std::tuple(timestamp(revision), id(str(revision, "deviceID")), id(str(revision, "id")));
}

Json parse(const Bytes& data) {
    require(data.size() <= maxObject);
    // Swift JSONDecoder 能处理的对象远浅于此限制。限制深度避免恶意备份耗尽栈。
    auto limit = [](int depth, Json::parse_event_t, Json&) {
        require(depth <= 64);
        return true;
    };
    return Json::parse(data, limit);
}

Bytes serialized(const Json& value) {
    std::string encoded = value.dump();
    Wipe clear{encoded};
    require(encoded.size() <= maxObject, "保险库超过大小上限。");
    return bytes(encoded);
}

Bytes binary(const Json& object, const char* field) { return decode64(str(object, field)); }

Bytes derive(std::string_view password, Bytes salt, uint64_t count) {
    require(password.size() <= 4096 && salt.size() == 32 && count >= 600000 && count <= 2000000);
    Algorithm hmac(BCRYPT_SHA256_ALGORITHM, BCRYPT_ALG_HANDLE_HMAC_FLAG);
    Bytes result(32);
    require(BCryptDeriveKeyPBKDF2(hmac.value, reinterpret_cast<PUCHAR>(const_cast<char*>(password.data())),
        static_cast<ULONG>(password.size()), salt.data(), 32, count, result.data(), 32, 0) >= 0);
    return result;
}

Bytes crypt(bool seal, const Bytes& key, Bytes input, std::string_view context) {
    Wipe clear{input};
    require(key.size() == 32 && (seal || input.size() >= 28));
    Algorithm aes(BCRYPT_AES_ALGORITHM);
    require(BCryptSetProperty(aes.value, BCRYPT_CHAINING_MODE,
        reinterpret_cast<PUCHAR>(const_cast<wchar_t*>(BCRYPT_CHAIN_MODE_GCM)), sizeof(BCRYPT_CHAIN_MODE_GCM), 0) >= 0);
    Key secret;
    require(BCryptGenerateSymmetricKey(aes.value, &secret.value, nullptr, 0, const_cast<PUCHAR>(key.data()), 32, 0) >= 0);
    std::array<unsigned char, 12> nonce{};
    std::array<unsigned char, 16> tag{};
    if (seal) require(BCryptGenRandom(nullptr, nonce.data(), 12, BCRYPT_USE_SYSTEM_PREFERRED_RNG) >= 0);
    else {
        std::copy_n(input.begin(), 12, nonce.begin());
        std::copy_n(input.end() - 16, 16, tag.begin());
    }

    BCRYPT_AUTHENTICATED_CIPHER_MODE_INFO info;
    BCRYPT_INIT_AUTH_MODE_INFO(info);
    info.pbNonce = nonce.data();
    info.cbNonce = 12;
    info.pbAuthData = reinterpret_cast<PUCHAR>(const_cast<char*>(context.data()));
    info.cbAuthData = static_cast<ULONG>(context.size());
    info.pbTag = tag.data();
    info.cbTag = 16;
    ULONG written{}, size = static_cast<ULONG>(seal ? input.size() : input.size() - 28);
    Bytes output(seal ? size + 28 : size);
    auto method = seal ? BCryptEncrypt : BCryptDecrypt;
    if (method(secret.value, input.data() + (seal ? 0 : 12), size, &info, nullptr, 0,
        output.data() + (seal ? 12 : 0), size, &written, 0) < 0 || written != size) {
        wipe(output);
        throw Fault("解锁材料错误，或保险库密文已损坏。");
    }
    if (seal) {
        std::copy(nonce.begin(), nonce.end(), output.begin());
        std::copy(tag.begin(), tag.end(), output.end() - 16);
    }
    return output;
}

Json unseal(const Bytes& key, Bytes ciphertext, const std::string& context) {
    auto clear = crypt(false, key, std::move(ciphertext), context);
    Wipe erase{clear};
    return parse(clear);
}

void bounded(const Json& text, size_t limit) {
    require(text.is_string() && text.get_ref<const std::string&>().size() <= limit);
}

void validate(const Json& revision, bool bookmarks) {
    id(str(revision, "id"));
    id(str(revision, "deviceID"));
    require(revision.at("deleted").is_boolean());
    auto [time, counter] = timestamp(revision);
    require(time >= 0 && counter < UINT64_MAX - 1);
    const auto& parents = revision.at("parents");
    require(parents.is_array() && parents.size() <= 10000);

    const auto& item = revision.at("item");
    auto itemID = id(str(item, "id"));
    const auto kind = str(item, "kind");
    const std::set<std::string_view> vaultTypes{"login", "totp", "passkey", "recoveryCodes", "card", "identity", "note"};
    require(itemID != parentID(item));
    require(bookmarks ? kind == "bookmark" || kind == "folder" : vaultTypes.contains(kind));
    signedNumber(item.at("order"));
    bounded(item.at("title"), 8192);
    bounded(item.at("notes"), 1048576);

    const auto& fields = item.at("fields");
    const auto& urls = item.at("urls");
    const auto& attachments = item.at("attachments");
    require(fields.is_object() && fields.size() <= 256 && urls.is_array() && urls.size() <= 100 &&
        attachments.is_array() && attachments.size() <= 100);
    for (const auto& field : fields) bounded(field, 1048576);
    for (const auto& url : urls) bounded(url, 32768);

    std::set<std::string> seen;
    for (const auto& ref : attachments) {
        require(seen.insert(id(str(ref, "id"))).second);
        bounded(ref.at("name"), 1024);
        str(ref, "mediaType");
        auto hash = str(ref, "digest");
        require(hash.size() == 64 && hash.find_first_not_of("0123456789abcdef") == std::string::npos);
        auto data = binary(ref, "data");
        Wipe clear{data};
        if (optional(ref, "remoteSize")) {
            auto length = nonnegative(ref.at("remoteSize"));
            require(data.empty() && length > 0 && length <= attachmentLimit);
        } else require(data.size() <= attachmentLimit && hex(digest(data)) == hash);
    }

    const auto& tags = item.at("tags");
    const auto& source = item.at("sourceData");
    require(tags.is_array() && source.is_object());
    for (const auto& tag : tags) require(tag.is_string());
    for (const auto& field : source) require(field.is_string());
}

bool equivalent(const Json& current, Json incoming) {
    if (current == incoming) return true;
    const auto& a = current.at("item").at("attachments");
    auto& b = incoming.at("item").at("attachments");
    if (a.size() != b.size()) return false;
    for (size_t i = 0; i < a.size(); ++i) {
        bool remoteA = optional(a[i], "remoteSize"), remoteB = optional(b[i], "remoteSize");
        if (remoteA == remoteB) continue;
        const auto lengthA = remoteA ? nonnegative(a[i].at("remoteSize")) : binary(a[i], "data").size();
        const auto lengthB = remoteB ? nonnegative(b[i].at("remoteSize")) : binary(b[i], "data").size();
        if (lengthA != lengthB) return false;
        if (remoteA) b[i]["remoteSize"] = lengthA;
        else b[i].erase("remoteSize");
        b[i]["data"] = a[i]["data"];
    }
    return current == incoming;
}

void add(Records& records, const Json& value) {
    auto [found, inserted] = records.try_emplace(id(str(value, "id")), value);
    require(inserted || equivalent(found->second, value));
}

Records records(const Json& state) {
    Records result;
    for (const auto& revision : state.at("revisions")) add(result, revision);
    return result;
}

void chain(const Records& revisions, bool bookmarks) {
    for (const auto& [_, revision] : revisions) {
        validate(revision, bookmarks);
        const auto itemID = id(str(revision.at("item"), "id"));
        std::set<std::string> seen;
        for (const auto& raw : revision.at("parents")) {
            auto parent = id(raw.get<std::string>());
            auto found = revisions.find(parent);
            require(found != revisions.end() && seen.insert(parent).second &&
                id(str(found->second.at("item"), "id")) == itemID && timestamp(found->second) < timestamp(revision));
        }
    }
}

using Current = std::map<std::string, const Json*>;
Current latest(const Json& state) {
    Current result;
    for (const auto& revision : state.at("revisions")) {
        auto& winner = result[id(str(revision.at("item"), "id"))];
        if (!winner || priority(*winner) < priority(revision)) winner = &revision;
    }
    return result;
}

std::string visibleParent(const Json& item, const Current& current) {
    const auto parent = parentID(item);
    std::set<std::string> seen{id(str(item, "id"))};
    for (auto cursor = parent; !cursor.empty();) {
        auto found = current.find(cursor);
        if (found == current.end() || !seen.insert(cursor).second || found->second->at("deleted") == true ||
            found->second->at("item").at("kind") != "folder") return {};
        cursor = parentID(found->second->at("item"));
    }
    return parent;
}

Entry entry(const Json& revision, const Current& current, bool secret) {
    const auto& item = revision.at("item");
    const auto& urls = item.at("urls");
    const auto& fields = item.at("fields");
    return {id(str(item, "id")), str(item, "kind"), str(item, "title"), visibleParent(item, current),
        urls.empty() ? "" : urls.front().get<std::string>(), fields.value("username", ""),
        secret ? str(item, "notes") : "", secret ? fields.value("password", "") : "",
        signedNumber(item.at("order")), revision.at("deleted").get<bool>()};
}

void writeAtomic(const Path& file, const Bytes& data) {
    auto temp = file;
    temp += L"." + wide(newID()) + L".tmp";
    try {
        {
            Handle handle(CreateFileW(temp.c_str(), GENERIC_WRITE, 0, nullptr, CREATE_NEW, FILE_ATTRIBUTE_NORMAL, nullptr));
            DWORD written{};
            require(WriteFile(handle.value, data.data(), static_cast<DWORD>(data.size()), &written, nullptr) &&
                written == data.size() && FlushFileBuffers(handle.value), "本机保险库写入失败。");
        }
        require(MoveFileExW(temp.c_str(), file.c_str(), MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH),
            "本机保险库替换失败，原文件已保留。");
    } catch (...) {
        DeleteFileW(temp.c_str());
        throw;
    }
}

Handle lock(const Path& path) {
    auto name = path;
    name += L".lock";
    return Handle(CreateFileW(name.c_str(), GENERIC_WRITE, 0, nullptr, OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr));
}

std::string device(const Path& root) {
    std::filesystem::create_directories(root);
    auto path = root / L"device-id";
    auto guard = lock(path);
    if (!std::filesystem::exists(path)) writeAtomic(path, bytes(newID()));
    auto data = readFile(path);
    return id(std::string(data.begin(), data.end()));
}

const Json* currentRevision(const Current& items, std::string_view identity) {
    const auto found = items.find(std::string(identity));
    require(found != items.end(), "该条目已变化，请重新选择。");
    return found->second;
}
}

std::wstring wide(std::string_view value) {
    if (value.empty()) return {};
    int size = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, value.data(), static_cast<int>(value.size()), nullptr, 0);
    require(size > 0);
    std::wstring result(size, L'\0');
    require(MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, value.data(), static_cast<int>(value.size()), result.data(), size) == size);
    return result;
}

std::string utf8(std::wstring_view value) {
    if (value.empty()) return {};
    int size = WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, value.data(), static_cast<int>(value.size()), nullptr, 0, nullptr, nullptr);
    require(size > 0);
    std::string result(size, '\0');
    require(WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, value.data(), static_cast<int>(value.size()), result.data(),
        size, nullptr, nullptr) == size);
    return result;
}

std::string base64(const Bytes& value) {
    if (value.empty()) return {};
    DWORD size{};
    constexpr DWORD flags = CRYPT_STRING_BASE64 | CRYPT_STRING_NOCRLF;
    require(CryptBinaryToStringA(value.data(), static_cast<DWORD>(value.size()), flags, nullptr, &size));
    std::string result(size, '\0');
    require(CryptBinaryToStringA(value.data(), static_cast<DWORD>(value.size()), flags, result.data(), &size));
    result.resize(size);
    return result;
}

Bytes decode64(std::string_view value) {
    if (value.empty()) return {};
    DWORD size{};
    constexpr DWORD flags = CRYPT_STRING_BASE64 | CRYPT_STRING_STRICT;
    require(CryptStringToBinaryA(value.data(), static_cast<DWORD>(value.size()), flags, nullptr, &size, nullptr, nullptr));
    Bytes result(size);
    require(CryptStringToBinaryA(value.data(), static_cast<DWORD>(value.size()), flags, result.data(), &size, nullptr, nullptr));
    result.resize(size);
    return result;
}

Bytes readFile(const Path& path) {
    std::ifstream in(path, std::ios::binary | std::ios::ate);
    require(bool(in), "无法打开本机保险库。");
    auto size = in.tellg();
    require(size >= 0 && size <= static_cast<std::streamoff>(maxObject), "保险库超过大小上限。");
    Bytes result(static_cast<size_t>(size));
    in.seekg(0);
    require(bool(in.read(reinterpret_cast<char*>(result.data()), size)), "读取本机保险库失败。");
    return result;
}

Bytes sha256(const Bytes& data) { return digest(data); }

Bytes encryptAuthenticated(const Bytes& key, Bytes clear, std::string_view context) {
    return crypt(true, key, std::move(clear), context);
}

Bytes decryptAuthenticated(const Bytes& key, Bytes sealed, std::string_view context) {
    return crypt(false, key, std::move(sealed), context);
}

bool objectName(std::string_view value) {
    if (value == "space.pbsync") return true;
    if (value.size() != 41 && value.size() != 42) return false;
    if (!value.ends_with(".pbop") && !value.ends_with(".pbatt")) return false;
    try { return id(value.substr(0, 36)) == value.substr(0, 36); }
    catch (const Fault&) { return false; }
}

Vault::Vault(Path file, const Bytes& data, bool local, std::string_view secret, bool recovery, bool bookmarks,
             const Bytes* localKey)
    : file_(std::move(file)) {
    auto archive = parse(data);
    header_ = archive.at("header");
    auto epoch = nonnegative(header_.at("keyEpoch"));
    auto count = nonnegative(header_.at("iterations"));
    auto salt = binary(header_, "salt");
    auto passwordSlot = binary(header_, "passwordSlot");
    auto recoverySlot = binary(header_, "recoverySlot");
    require(header_.at("format").is_number_integer() && header_["format"] == 1 && epoch > 0 &&
        epoch <= INT64_MAX && count >= 600000 && count <= 2000000 && salt.size() == 32 &&
        passwordSlot.size() == 60 && recoverySlot.size() == 60, "不支持此 PBsync 备份格式。");
    context_ = "PBsync|1|" + id(str(header_, "spaceID")) + "|" + std::to_string(epoch) + "|";
    if (localKey) {
        require(localKey->size() == 32, "本机解锁密钥无效。");
        key_ = *localKey;
    } else {
        if (recovery) {
            auto first = secret.find_first_not_of(" \r\n\t");
            require(first != std::string_view::npos, "恢复密钥无效。");
            secret = secret.substr(first, secret.find_last_not_of(" \r\n\t") - first + 1);
        }
        auto wrapping = recovery ? decode64(secret) : derive(secret, salt, count);
        Wipe clear{wrapping};
        require(wrapping.size() == 32, "恢复密钥无效。");
        key_ = crypt(false, wrapping, recovery ? std::move(recoverySlot) : std::move(passwordSlot),
            context_ + (recovery ? "recovery" : "password"));
    }
    try {
        state_ = state(data);
        require(state_["kind"] == (bookmarks ? "bookmarks" : "vault"), "请选择与此备份匹配的数据空间。");
        device_ = device(file_.parent_path());
        if (local) localDigest_ = digest(data);
    } catch (...) { wipe(key_); throw; }
}

Vault::~Vault() { wipe(key_); }

std::shared_ptr<Vault> Vault::open(const Path& file, std::string_view secret, bool recovery, bool bookmarks) {
    return std::shared_ptr<Vault>(new Vault(file, readFile(file), true, secret, recovery, bookmarks));
}
std::shared_ptr<Vault> Vault::openWithDeviceKey(const Path& file, const Bytes& key, bool bookmarks) {
    return std::shared_ptr<Vault>(new Vault(file, readFile(file), true, {}, false, bookmarks, &key));
}
Bytes Vault::deviceUnlockKey() const { return key_; }
std::shared_ptr<Vault> Vault::restore(const Path& file, const Bytes& data, std::string_view secret, bool recovery, bool bookmarks) {
    auto vault = std::shared_ptr<Vault>(new Vault(file, data, false, secret, recovery, bookmarks));
    vault->persist(vault->state_);
    return vault;
}
std::shared_ptr<Vault> Vault::connect(const Path& file, Storage& storage, std::string_view secret, bool bookmarks) {
    auto vault = std::shared_ptr<Vault>(new Vault(file, storage.read("space.pbsync"), false, secret, false, bookmarks));
    vault->exchange(storage, false);
    return vault;
}

Json Vault::state(const Bytes& data) const {
    auto archive = parse(data);
    require(archive.at("header") == header_, "远端密钥保护或空间身份已变更，请重新连接。");
    auto state = unseal(key_, binary(archive, "sealedState"), context_ + "state");
    auto kind = str(state, "kind");
    str(state, "name");
    require((kind == "bookmarks" || kind == "vault") && nonnegative(state.at("generation")) > 0 &&
        state.at("retired").is_boolean() && state.at("revisions").is_array());
    chain(records(state), kind == "bookmarks");
    return state;
}

Json Vault::operation(const Bytes& data, std::string_view name) const {
    auto object = parse(data);
    auto revisionID = id(str(object, "id"));
    require(revisionID + ".pbop" == name && id(str(object, "spaceID")) == id(str(header_, "spaceID")) &&
        object.at("keyEpoch") == header_.at("keyEpoch"));
    auto revision = unseal(key_, binary(object, "sealed"), context_ + "operation:" + revisionID);
    require(id(str(revision, "id")) == revisionID);
    validate(revision, state_["kind"] == "bookmarks");
    return revision;
}

void Vault::persist(Json next) {
    const auto encrypted = crypt(true, key_, serialized(next), context_ + "state");
    const auto data = serialized(Json{{"header", header_}, {"sealedState", base64(encrypted)}});
    auto guard = lock(file_);
    require(std::filesystem::exists(file_) == localDigest_.has_value() &&
        (!localDigest_ || digest(readFile(file_)) == *localDigest_), "本机保险库已变化，请重新打开。");
    writeAtomic(file_, data);
    localDigest_ = digest(data);
    state_ = std::move(next);
}

std::string Vault::name() const { return str(state_, "name"); }

std::vector<Entry> Vault::entries(bool trash) const {
    const auto current = latest(state_);
    std::vector<Entry> output;
    for (const auto& [_, value] : current) {
        if (value->at("deleted") == trash) output.push_back(entry(*value, current, false));
    }
    std::sort(output.begin(), output.end(), [](const Entry& a, const Entry& b) {
        return std::tie(a.order, a.id) < std::tie(b.order, b.id);
    });
    return output;
}

Entry Vault::detail(std::string_view identity) const {
    const auto current = latest(state_);
    return entry(*currentRevision(current, identity), current, true);
}

void Vault::writable() const { require(state_["retired"] == false, "此同步位置已冻结。"); }

std::string Vault::append(Json& target, const Json& item, const Json* parent, bool deleted) {
    std::pair<int64_t, uint64_t> last{};
    for (const auto& row : target["revisions"]) last = std::max(last, timestamp(row));
    const auto now = std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::system_clock::now().time_since_epoch()).count();
    if (now > last.first) last = {now, 0};
    else ++last.second;
    Json ancestry = Json::array();
    if (parent) ancestry.push_back(parent->at("id"));
    auto revisionID = newID();
    Json revision{{"id", revisionID}, {"deviceID", device_}, {"time", {{"milliseconds", last.first}, {"counter", last.second}}},
        {"parents", ancestry}, {"item", item}, {"deleted", deleted}};
    validate(revision, target["kind"] == "bookmarks");
    target["revisions"].push_back(revision);
    return revisionID;
}

std::string Vault::save(const Entry& draft) {
    writable();
    require(draft.title.find_first_not_of(" \r\n\t") != std::string::npos, "请输入条目标题。");
    auto next = state_;
    auto current = latest(state_);
    const Json* previous = draft.id.empty() ? nullptr : currentRevision(current, draft.id);
    Json item;
    if (previous) {
        require(previous->at("deleted") == false, "条目已在回收站，请先恢复。");
        item = previous->at("item");
    } else {
        int64_t order{};
        for (const auto& [_, value] : current) order = std::max(order, signedNumber(value->at("item").at("order")));
        require(order < INT64_MAX);
        item = {{"id", newID()}, {"kind", draft.kind}, {"order", order + 1}, {"urls", Json::array()},
            {"fields", Json::object()}, {"tags", Json::array()}, {"attachments", Json::array()}, {"sourceData", Json::object()}};
    }
    const auto kind = str(item, "kind");
    require(kind == "bookmark" || kind == "folder" || kind == "login", "此条目仅支持查看。");
    item["title"] = draft.title;
    item["notes"] = draft.notes;
    if (kind != "folder" && (!draft.url.empty() || !item["urls"].empty())) item["urls"][0] = draft.url;
    if (kind == "login") {
        item["fields"]["username"] = draft.username;
        item["fields"]["password"] = draft.password;
    }
    if (state_["kind"] == "bookmarks") {
        if (draft.parent.empty()) item.erase("parentID");
        else {
            item["parentID"] = id(draft.parent);
            require(!visibleParent(item, current).empty(), "目标目录无效。");
        }
    }
    append(next, item, previous, false);
    persist(std::move(next));
    return id(str(item, "id"));
}

void Vault::remove(std::string_view itemID) {
    writable();
    auto next = state_;
    auto current = latest(state_);
    auto target = currentRevision(current, itemID);
    require(target->at("deleted") == false);
    std::set<std::string> deleting{std::string(itemID)};
    if (target->at("item").at("kind") == "folder") {
        size_t count;
        do {
            count = deleting.size();
            for (const auto& [key, row] : current) {
                if (row->at("deleted") == false && deleting.contains(parentID(row->at("item")))) deleting.insert(key);
            }
        } while (count != deleting.size());
    }
    for (const auto& key : deleting) {
        const auto row = current.at(key);
        append(next, row->at("item"), row, true);
    }
    persist(std::move(next));
}

void Vault::recover(std::string_view itemID) {
    writable();
    auto next = state_;
    auto current = latest(state_);
    auto target = currentRevision(current, itemID);
    require(target->at("deleted") == true);
    append(next, target->at("item"), target, false);
    persist(std::move(next));
}

void Vault::move(std::string_view itemID, int offset) {
    writable();
    require(state_["kind"] == "bookmarks" && (offset == -1 || offset == 1));
    auto next = state_;
    const auto current = latest(state_);
    const auto target = detail(itemID);
    require(!target.deleted);
    auto siblings = entries();
    std::erase_if(siblings, [&](const Entry& row) { return row.parent != target.parent; });
    auto source = std::find_if(siblings.begin(), siblings.end(), [&](const Entry& row) { return row.id == itemID; });
    if ((offset < 0 && source == siblings.begin()) || (offset > 0 && source + 1 == siblings.end())) return;
    std::iter_swap(source, source + offset);
    int64_t order = 0;
    for (const auto& row : siblings) {
        if (row.order != order) {
            auto previous = current.at(row.id);
            Json item = previous->at("item");
            item["order"] = order;
            append(next, item, previous, false);
        }
        ++order;
    }
    persist(std::move(next));
}

namespace {
bool browserRoot(std::string_view identity) {
    return identity == "62b3a4bb-4826-4856-8fb2-cff155b7d801" ||
        identity == "62b3a4bb-4826-4856-8fb2-cff155b7d802" ||
        identity == "62b3a4bb-4826-4856-8fb2-cff155b7d803" ||
        identity == "62b3a4bb-4826-4856-8fb2-cff155b7d804";
}

Json browserProjection(const Json& state) {
    auto current = latest(state);
    Json items = Json::array(), removed = Json::array();
    for (const auto& [identity, revision] : current) {
        if (revision->at("deleted") == true) {
            if (!browserRoot(identity)) removed.push_back(identity);
            continue;
        }
        const auto& item = revision->at("item");
        auto order = signedNumber(item.at("order"));
        require(order >= -(1LL << 53) + 1 && order <= (1LL << 53) - 1, "收藏夹排序超过浏览器支持的范围。");
        const auto parent = visibleParent(item, current);
        // 扩展只需要书签结构和网址，不传备注、附件或来源附加数据。
        items.push_back(Json{{"id", identity}, {"kind", item.at("kind")}, {"title", item.at("title")},
            {"parentID", parent.empty() ? Json() : Json(parent)}, {"order", order}, {"urls", item.at("urls")}});
    }
    return Json{{"items", items}, {"deleted", removed}, {"name", state.at("name")}};
}

void checkBrowserSize(const Json& snapshot) {
    // Chromium 的本机消息响应上限为 1 MiB，给响应包装、认证标签和 Base64 留出空间。
    require(snapshot.dump().size() <= 760 * 1024, "收藏夹超过浏览器单次响应上限，本次没有写入。");
}
}

Bytes Vault::browserPairingKey(bool authorize) const {
    require(state_["kind"] == "bookmarks", "浏览器仅能配对收藏夹空间。");
    auto deriveLabel = [&](std::string_view label) {
        Algorithm hmac(BCRYPT_SHA256_ALGORITHM, BCRYPT_ALG_HANDLE_HMAC_FLAG);
        auto context = context_ + std::string(label) + "|" + device_;
        Bytes result(32);
        require(BCryptHash(hmac.value, const_cast<PUCHAR>(key_.data()), static_cast<ULONG>(key_.size()),
            reinterpret_cast<PUCHAR>(context.data()), static_cast<ULONG>(context.size()),
            result.data(), static_cast<ULONG>(result.size())) >= 0);
        return result;
    };
    auto file = file_.parent_path() / L"bookmarks-pairing.grant";
    auto grant = deriveLabel("browser-grant");
    Wipe clear{grant};
    if (authorize) {
        auto guard = lock(file);
        writeAtomic(file, grant);
    } else {
        std::error_code error;
        require(std::filesystem::file_size(file, error) == grant.size() && !error && readFile(file) == grant,
            "请在 PBsync 同步页复制收藏夹配对密钥。");
    }
    // 授权文件和配对密钥使用不同域。授权文件无法用来算出配对密钥。
    return deriveLabel("browser-pairing");
}

Json Vault::browserSnapshot() const {
    require(state_["kind"] == "bookmarks", "浏览器仅能读取收藏夹空间。");
    auto snapshot = browserProjection(state_);
    checkBrowserSize(snapshot);
    return snapshot;
}

std::pair<Json, bool> Vault::browserApply(const Json& updates, const Json& removed) {
    writable();
    require(state_["kind"] == "bookmarks", "浏览器仅能写入收藏夹空间。");
    require(updates.is_array() && removed.is_array() && updates.size() <= 50000 && removed.size() <= 50000,
        "收藏夹更新格式无效。");
    auto next = state_;
    const auto current = latest(state_);
    std::set<std::string> seen, deleting;
    bool changed = false;

    for (const auto& update : updates) {
        const auto identity = id(str(update, "id"));
        require(seen.insert(identity).second, "收藏夹更新包含重复条目。");
        const auto kind = str(update, "kind");
        require(kind == "bookmark" || kind == "folder", "浏览器只能同步收藏和目录。");
        const auto& urls = update.at("urls");
        require(urls.is_array() && (kind == "folder" ? urls.empty() :
            (urls.size() == 1 && urls[0].is_string() && !urls[0].get_ref<const std::string&>().empty())),
            "收藏条目的网址无效。");
        auto found = current.find(identity);
        const Json* previous = found == current.end() ? nullptr : found->second;
        Json item = previous ? previous->at("item") : Json{
            {"id", identity}, {"kind", kind}, {"fields", Json::object()}, {"notes", ""},
            {"tags", Json::array()}, {"attachments", Json::array()}, {"sourceData", Json::object()}};
        require(item.at("kind") == kind, "条目类型已变化。");
        const auto parent = parentID(update);
        const auto order = signedNumber(update.at("order"));
        require(!browserRoot(identity) || (kind == "folder" && parent.empty()), "浏览器内置目录不能移动。");
        if (browserRoot(identity)) {
            const auto marker = str(update.at("fields"), "browserRoot");
            const std::string end = identity.substr(identity.size() - 1);
            const std::map<std::string, std::string> roles{{"1","toolbar"},{"2","other"},{"3","mobile"},{"4","menu"}};
            require(roles.at(end) == marker, "浏览器内置目录身份无效。");
            item["fields"]["browserRoot"] = marker;
        }
        item["title"] = update.at("title");
        item["order"] = order;
        if (urls.empty()) item["urls"] = urls;
        else {
            if (!item.contains("urls")) item["urls"] = Json::array();
            item["urls"][0] = urls[0];
        }
        if (parent != parentID(item)) {
            if (parent.empty()) item.erase("parentID");
            else item["parentID"] = parent;
        }
        if (!previous || previous->at("deleted") == true || item != previous->at("item")) {
            append(next, item, previous, false);
            changed = true;
        }
    }

    for (const auto& raw : removed) {
        auto identity = id(raw.get<std::string>());
        require(!seen.contains(identity) && deleting.insert(identity).second, "收藏夹更新同时包含不一致的删除记录。");
    }

    const auto proposed = latest(next);
    std::set<std::string> retain;
    for (const auto& [_, revision] : proposed) {
        if (revision->at("deleted") == false && !deleting.contains(id(str(revision->at("item"), "id")))) {
            auto parent = parentID(revision->at("item"));
            // 保留仍有未删除子项的目录，防止浏览器的旧快照吞掉另一端新增。
            while (deleting.contains(parent) && retain.insert(parent).second) {
                auto found = proposed.find(parent);
                if (found == proposed.end()) break;
                parent = parentID(found->second->at("item"));
            }
        }
    }
    for (const auto& identity : deleting) {
        if (browserRoot(identity) || retain.contains(identity)) continue;
        auto entry = current.find(identity);
        if (entry != current.end() && entry->second->at("deleted") == false) {
            append(next, entry->second->at("item"), entry->second, true);
            changed = true;
        }
    }

    auto snapshot = browserProjection(next);
    checkBrowserSize(snapshot);
    if (changed) persist(std::move(next));
    return {std::move(snapshot), changed};
}

SyncResult Vault::sync(Storage& storage) { return exchange(storage, true); }

SyncResult Vault::exchange(Storage& storage, bool upload) {
    writable();
    auto remote = state(storage.read("space.pbsync"));
    require(remote["retired"] == false && remote["kind"] == state_["kind"] && remote["generation"] == state_["generation"],
        "同步空间已冻结或版本已变化。");
    auto names = storage.list();
    auto incoming = records(remote);
    for (const auto& name : names) {
        if (name.ends_with(".pbop")) add(incoming, operation(storage.read(name), name));
    }
    for (const auto& [_, revision] : incoming) {
        for (const auto& ref : revision["item"]["attachments"]) {
            if (optional(ref, "remoteSize")) require(names.contains(id(str(ref, "id")) + ".pbatt"), "远端附件缺失。");
        }
    }

    auto merged = records(state_);
    auto count = merged.size();
    for (const auto& [_, revision] : incoming) add(merged, revision);
    chain(merged, state_["kind"] == "bookmarks");
    SyncResult result{merged.size() - count, 0};
    if (result.downloaded || !localDigest_) {
        auto next = state_;
        next["revisions"] = Json::array();
        for (const auto& [_, revision] : merged) next["revisions"].push_back(revision);
        persist(std::move(next));
    }
    if (!upload) return result;
    std::vector<const Json*> pending;
    for (const auto& [key, revision] : merged) if (!incoming.contains(key)) pending.push_back(&revision);
    std::sort(pending.begin(), pending.end(), [](const Json* a, const Json* b) { return priority(*a) < priority(*b); });

    for (const auto revision : pending) {
        for (const auto& ref : (*revision)["item"]["attachments"]) {
            if (!optional(ref, "remoteSize")) continue;
            auto name = id(str(ref, "id")) + ".pbatt";
            require(names.contains(name), "远端缺少附件，待上传修改仍保存在本机。");
            auto clear = crypt(false, key_, storage.read(name), context_ + name);
            Wipe erase{clear};
            require(clear.size() == nonnegative(ref.at("remoteSize")) && hex(digest(clear)) == str(ref, "digest"));
        }
        auto revisionID = id(str(*revision, "id"));
        auto name = revisionID + ".pbop";
        Json object{{"id", revision->at("id")}, {"spaceID", header_.at("spaceID")}, {"keyEpoch", header_.at("keyEpoch")},
            {"sealed", base64(crypt(true, key_, serialized(*revision), context_ + "operation:" + revisionID))}};
        if (!storage.create(name, serialized(object))) require(equivalent(*revision, operation(storage.read(name), name)));
        ++result.uploaded;
    }
    return result;
}
}
