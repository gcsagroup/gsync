#include "vault.hpp"
#include <windows.h>
#include <algorithm>
#include <iostream>

using namespace pb;

namespace {
void check(bool value, const char* label) {
    if (!value) throw std::runtime_error(label);
}

bool contains(const std::vector<Entry>& rows, std::string_view title) {
    return std::ranges::any_of(rows, [&](const Entry& row) { return row.title == title; });
}

std::string readSecret(const Path& path) {
    auto raw = readFile(path);
    std::string value(raw.begin(), raw.end());
    value.erase(value.find_last_not_of(" \r\n\t") + 1);
    return value;
}

void verifyVault(const Path& fixture, const Path& profile, std::wstring_view endpoint) {
    const auto password = readSecret(fixture / L"vault-master");
    const auto recovery = readSecret(fixture / L"vault-recovery");
    const auto data = readFile(fixture / L"seed" / L"vault" / L"space.pbsync");
    auto file = profile / L"vault.pbsync";
    std::filesystem::create_directories(profile);

    bool rejected = false;
    try { auto invalid = Vault::restore(file, data, "SYNTHETIC-wrong-secret", false, false); }
    catch (const Fault&) { rejected = true; }
    check(rejected && !std::filesystem::exists(file), "wrong secret must not create a local copy");

    auto altered = Json::parse(data);
    auto ciphertext = decode64(altered["sealedState"].get<std::string>());
    ciphertext.back() ^= 1;
    altered["sealedState"] = base64(ciphertext);
    auto text = altered.dump();
    rejected = false;
    try { auto invalid = Vault::restore(file, Bytes(text.begin(), text.end()), password, false, false); }
    catch (const Fault&) { rejected = true; }
    check(rejected && !std::filesystem::exists(file), "altered data must not create a local copy");

    auto vault = Vault::restore(file, data, recovery, true, false);
    check(vault->entries().size() == 12, "restore v1 by recovery key");
    const auto fingerprint = readFile(file);
    rejected = false;
    try { auto other = Vault::restore(file, data, password, false, false); }
    catch (const Fault&) { rejected = true; }
    check(rejected && readFile(file) == fingerprint, "restore must not replace an existing backup");
    vault.reset();

    auto remote = webdav(std::wstring(endpoint) + L"vault/", L"qa", L"SYNTHETIC-webdav-secret");
    vault = Vault::open(file, password, false, false);
    check(vault->sync(*remote).uploaded == 0, "identical encrypted revisions must not upload");
    Entry item;
    item.kind = "login";
    item.title = "Windows Native Test Login";
    item.url = "https://test.example.invalid/";
    item.username = "native-test";
    item.password = "SYNTHETIC-native-password";
    auto id = vault->save(item);
    check(vault->sync(*remote).uploaded == 1, "publish one login revision");
    auto other = Vault::connect(profile / L"other-vault.pbsync", *remote, password, false);
    check(other->detail(id).password == item.password && other->entries().size() >= 13, "read back encrypted login");
    item.id = id;
    item.password = "SYNTHETIC-edited-password";
    other->save(item);
    check(other->sync(*remote).uploaded == 1 && vault->sync(*remote).downloaded == 1 &&
        vault->detail(id).password == item.password, "read back encrypted password edit");
}

void verifyBookmarks(const Path& fixture, const Path& profile, std::wstring_view endpoint) {
    const auto password = readSecret(fixture / L"bookmark-master");
    auto remote = webdav(std::wstring(endpoint) + L"bookmarks/", L"qa", L"SYNTHETIC-webdav-secret");
    auto file = profile / L"bookmarks.pbsync";
    auto bookmarks = Vault::connect(file, *remote, password, true);
    auto other = Vault::connect(profile / L"other-bookmarks.pbsync", *remote, password, true);
    if (contains(bookmarks->entries(), "Apple Native Test Bookmark"))
        std::cout << "Apple-origin bookmark read on Windows\n";
    Entry folder;
    folder.kind = "folder";
    folder.title = "Native Test Folder";
    auto folderID = bookmarks->save(folder);
    Entry first, second;
    first.kind = second.kind = "bookmark";
    first.title = "Windows Native First";
    second.title = "Windows Native Second";
    first.url = "https://first.example.invalid/";
    second.url = "https://second.example.invalid/";
    first.parent = second.parent = folderID;
    auto firstID = bookmarks->save(first), secondID = bookmarks->save(second);
    bookmarks->move(secondID, -1);
    check(bookmarks->sync(*remote).uploaded >= 3 && other->sync(*remote).downloaded >= 3,
        "publish bookmarks, folder and reordering");
    check(other->detail(secondID).order < other->detail(firstID).order, "read back folder order");
    bookmarks->remove(folderID);
    check(bookmarks->sync(*remote).uploaded == 3 && other->sync(*remote).downloaded == 3 &&
        contains(other->entries(true), first.title) && contains(other->entries(true), second.title), "folder cascade delete");
    bookmarks->recover(folderID);
    bookmarks->recover(secondID);
    check(bookmarks->sync(*remote).uploaded == 2 && other->sync(*remote).downloaded == 2 &&
        other->detail(secondID).parent == folderID && !other->detail(secondID).deleted, "recover folder and item");
    check(other->sync(*remote).uploaded == 0, "empty sync after convergence");
}
}

int wmain(int argc, wchar_t** argv) {
    try {
        check(argc == 4, "usage: VaultCheck <fixture-root> <profile-root> <webdav-base>");
        verifyVault(argv[1], argv[2], argv[3]);
        verifyBookmarks(argv[1], argv[2], argv[3]);
        std::cout << "Windows native AES-GCM, recovery, negative archive checks, WebDAV, order and tombstones passed\n";
        return 0;
    } catch (const std::exception& error) {
        std::cerr << error.what() << '\n';
        return 1;
    }
}
