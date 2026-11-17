#pragma once
#include <filesystem>
#include <memory>
#include <optional>
#include <set>
#include <stdexcept>
#include <string>
#include <string_view>
#include <vector>
#include "json.hpp"

namespace pb {
using Json = nlohmann::json;
using Bytes = std::vector<unsigned char>;
using Path = std::filesystem::path;

struct Fault : std::runtime_error { using std::runtime_error::runtime_error; };
constexpr size_t maxObject = 128 * 1024 * 1024;
std::wstring wide(std::string_view value);
std::string utf8(std::wstring_view value);
std::string base64(const Bytes& value);
Bytes decode64(std::string_view value);
Bytes readFile(const Path& path);
bool objectName(std::string_view value);
Bytes sha256(const Bytes& data);
Bytes encryptAuthenticated(const Bytes& key, Bytes clear, std::string_view context);
Bytes decryptAuthenticated(const Bytes& key, Bytes sealed, std::string_view context);

class Storage {
public:
    virtual ~Storage() = default;
    virtual Bytes read(std::string_view name) = 0;
    virtual std::set<std::string> list() = 0;
    virtual bool create(std::string_view name, const Bytes& data) = 0;
};

std::shared_ptr<Storage> webdav(std::wstring_view address, std::wstring_view user, std::wstring_view password);

struct Entry {
    std::string id, kind, title, parent, url, username, notes, password;
    int64_t order{};
    bool deleted{};
    bool editable() const { return kind == "bookmark" || kind == "folder" || kind == "login"; }
};

struct SyncResult { size_t downloaded{}, uploaded{}; };

class Vault {
public:
    static std::shared_ptr<Vault> open(const Path& file, std::string_view secret, bool recovery, bool bookmarks);
    static std::shared_ptr<Vault> openWithDeviceKey(const Path& file, const Bytes& key, bool bookmarks);
    static std::shared_ptr<Vault> restore(const Path& file, const Bytes& backup, std::string_view secret, bool recovery, bool bookmarks);
    static std::shared_ptr<Vault> connect(const Path& file, Storage& storage, std::string_view secret, bool bookmarks);
    ~Vault();
    Vault(const Vault&) = delete;
    Vault& operator=(const Vault&) = delete;

    std::string name() const;
    std::vector<Entry> entries(bool trash = false) const;
    Entry detail(std::string_view id) const;
    std::string save(const Entry& draft);
    void remove(std::string_view id);
    void recover(std::string_view id);
    void move(std::string_view id, int offset);
    SyncResult sync(Storage& storage);
    Bytes deviceUnlockKey() const;
    Bytes browserPairingKey(bool authorize) const;
    Json browserSnapshot() const;
    std::pair<Json, bool> browserApply(const Json& updates, const Json& removed);

private:
    Vault(Path file, const Bytes& data, bool local, std::string_view secret, bool recovery, bool bookmarks,
          const Bytes* localKey = nullptr);
    void persist(Json next);
    std::string append(Json& target, const Json& item, const Json* parent, bool deleted);
    Json state(const Bytes& data) const;
    Json operation(const Bytes& data, std::string_view name) const;
    SyncResult exchange(Storage& storage, bool upload);
    void writable() const;

    Path file_;
    Json header_, state_;
    std::string context_, device_;
    Bytes key_;
    std::optional<Bytes> localDigest_;
};
}
