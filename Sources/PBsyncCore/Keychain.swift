import Foundation
import Security

public enum Keychain {
    private static let service = "com.gcsa.pbsync.local-settings"
    #if os(macOS)
    private static let accessLock = NSLock()
    #endif

    private static func withAccess<T>(allowInteraction: Bool, _ body: () throws -> T) throws -> T {
        #if os(macOS)
        // 已有项目保存在传统登录钥匙串。该类型需要通过进程级开关禁止授权面板。
        if allowInteraction { accessLock.lock() }
        else if !accessLock.try() { throw PBError.unavailable }
        defer { accessLock.unlock() }
        guard !allowInteraction else { return try body() }
        var previous: DarwinBoolean = false
        guard SecKeychainGetUserInteractionAllowed(&previous) == errSecSuccess,
              SecKeychainSetUserInteractionAllowed(false) == errSecSuccess else { throw PBError.unauthorized }
        defer { SecKeychainSetUserInteractionAllowed(previous.boolValue) }
        #endif
        return try body()
    }

    public static func save(_ data: Data, account: String, allowInteraction: Bool = true) throws {
        try withAccess(allowInteraction: allowInteraction) { try write(data, account: account) }
    }
    private static func write(_ data: Data, account: String) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
        let attributes: [String: Any] = [kSecValueData as String: data, kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        let update = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if update == errSecItemNotFound {
            let add = SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil)
            guard add == errSecSuccess else { throw PBError.invalid("无法保存到系统钥匙串。") }
        } else if update != errSecSuccess { throw PBError.invalid("无法更新系统钥匙串。") }
    }
    public static func read(account: String, allowInteraction: Bool = true) throws -> Data? {
        try withAccess(allowInteraction: allowInteraction) { try readItem(account: account, allowInteraction: allowInteraction) }
    }
    private static func readItem(account: String, allowInteraction: Bool) throws -> Data? {
        var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        if !allowInteraction { query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail }
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw PBError.unauthorized }; return data
    }
    public static func remove(account: String) throws {
        try withAccess(allowInteraction: true) { try removeItem(account: account) }
    }
    private static func removeItem(account: String) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
        let result = SecItemDelete(query as CFDictionary)
        guard result == errSecSuccess || result == errSecItemNotFound else { throw PBError.unauthorized }
    }
}

public struct StorageConfiguration: Codable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Sendable { case local, folder, webdav, localCloud }
    public var kind: Kind
    public var folderBookmark: Data?
    public var endpoint: String
    public var username: String
    public var secret: String
    public init(kind: Kind = .local, folderBookmark: Data? = nil, endpoint: String = "", username: String = "", secret: String = "") {
        self.kind = kind; self.folderBookmark = folderBookmark; self.endpoint = endpoint; self.username = username; self.secret = secret
    }
    public func storage() throws -> any ObjectStorage {
        switch kind {
        case .local: throw PBError.invalid("请先选择主要同步位置。")
        case .folder:
            guard let folderBookmark else { throw PBError.unauthorized }
            var stale = false
            #if os(macOS)
            let url = try URL(resolvingBookmarkData: folderBookmark, options: [.withSecurityScope, .withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale)
            #else
            let url = try URL(resolvingBookmarkData: folderBookmark, options: [.withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale)
            #endif
            guard !stale else { throw PBError.invalid("目录授权已失效，请重新选择同一目录。") }
            return FolderStorage(directory: url)
        case .webdav:
            guard let url = URL(string: endpoint) else { throw PBError.invalid("存储地址无效。") }
            return try WebDAVStorage(url: url, username: username, password: secret)
        case .localCloud:
            guard let url = URL(string: endpoint) else { throw PBError.invalid("本地云地址无效。") }
            return try WebDAVStorage(localCloudURL: url, token: secret)
        }
    }
    public static func bookmark(for url: URL) throws -> Data {
        #if os(macOS)
        return try url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
        #else
        return try url.bookmarkData(options: [.minimalBookmark], includingResourceValuesForKeys: nil, relativeTo: nil)
        #endif
    }
}
