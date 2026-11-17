import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif
import Darwin

public struct StoredBlob: Sendable {
    public var data: Data
    public var version: String?
    public init(data: Data, version: String? = nil) { self.data = data; self.version = version }
}

public protocol ObjectStorage: Sendable {
    func list() async throws -> [String]
    func read(_ name: String) async throws -> StoredBlob
    func create(_ name: String, data: Data) async throws
    func replace(_ name: String, data: Data, version: String) async throws
}

public enum SafeFile {
    public static func validName(_ name: String) -> Bool {
        name == "space.pbsync" || (name.hasSuffix(".pbatt") && UUID(uuidString: String(name.dropLast(6))) != nil) || (name.hasSuffix(".pbop") && UUID(uuidString: String(name.dropLast(5))) != nil)
    }
    public static func privateDirectory(_ directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }
    public static func write(_ data: Data, to url: URL) throws {
        try privateDirectory(url.deletingLastPathComponent())
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        #if os(iOS)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: url.path)
        #endif
    }
    /// 进程锁防止 App 与凭据扩展同时提交本地文件时相互覆盖。
    public static func withLock<T>(at url: URL, _ body: () throws -> T) throws -> T {
        try privateDirectory(url.deletingLastPathComponent())
        let fd = open(url.path, O_CREAT | O_RDWR | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw PBError.unavailable }
        defer { close(fd) }
        guard flock(fd, LOCK_EX) == 0 else { throw PBError.unavailable }
        defer { flock(fd, LOCK_UN) }; return try body()
    }
}

public struct FolderStorage: ObjectStorage, @unchecked Sendable {
    public let directory: URL
    public init(directory: URL) { self.directory = directory }
    private func coordinated<T>(name: String? = nil, writing: Bool, _ body: (URL) throws -> T) throws -> T {
        if let name, !SafeFile.validName(name) { throw PBError.invalid("无效的存储对象名称。") }
        let access = directory.startAccessingSecurityScopedResource()
        defer { if access { directory.stopAccessingSecurityScopedResource() } }
        let url = name.map { directory.appendingPathComponent($0) } ?? directory
        if FileManager.default.fileExists(atPath: url.path) {
            let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey])
            guard values.isSymbolicLink != true else { throw PBError.invalid("存储对象不能是符号链接。") }
        }
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var error: NSError?
        var outcome: Result<T, Error>?
        if writing {
            coordinator.coordinate(writingItemAt: url, options: [], error: &error) { coordinated in outcome = Result { try body(coordinated) } }
        } else {
            coordinator.coordinate(readingItemAt: url, options: [], error: &error) { coordinated in outcome = Result { try body(coordinated) } }
        }
        if let error { throw error }
        guard let outcome else { throw PBError.unavailable }; return try outcome.get()
    }
    public func list() async throws -> [String] {
        try coordinated(writing: false) { root in
            try FileManager.default.contentsOfDirectory(atPath: root.path).filter(SafeFile.validName).sorted()
        }
    }
    public func read(_ name: String) async throws -> StoredBlob {
        try coordinated(name: name, writing: false) { url in
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= 128 * 1024 * 1024 else { throw PBError.invalid("远端对象超过大小上限。") }
            let data = try Data(contentsOf: url)
            return StoredBlob(data: data, version: Crypto.digest(data))
        }
    }
    public func create(_ name: String, data: Data) async throws {
        try coordinated(name: name, writing: true) { url in
            try SafeFile.withLock(at: directory.appendingPathComponent(".write-lock")) {
                guard !FileManager.default.fileExists(atPath: url.path) else { throw PBError.conflict }
                try SafeFile.write(data, to: url)
            }
        }
    }
    public func replace(_ name: String, data: Data, version: String) async throws {
        try coordinated(name: name, writing: true) { url in
            try SafeFile.withLock(at: directory.appendingPathComponent(".write-lock")) {
                guard Crypto.digest(try Data(contentsOf: url)) == version else { throw PBError.conflict }
                try SafeFile.write(data, to: url)
            }
        }
    }
}

/// 默认系统 TLS 校验；仅本机开发服务允许明文 HTTP。
public final class WebDAVStorage: NSObject, ObjectStorage, URLSessionTaskDelegate, @unchecked Sendable {
    public let baseURL: URL
    private let authorization: String
    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20; config.timeoutIntervalForResource = 60
        config.httpCookieStorage = nil; config.urlCredentialStorage = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()
    public init(url: URL, username: String, password: String) throws {
        try Self.validate(url)
        baseURL = url.hasDirectoryPath ? url : url.appendingPathComponent("")
        authorization = "Basic " + Data("\(username):\(password)".utf8).base64EncodedString()
    }
    public init(localCloudURL url: URL, token: String) throws {
        try Self.validate(url)
        guard ["127.0.0.1", "localhost", "::1"].contains(url.host ?? "") else { throw PBError.invalid("官方云当前仅允许本机验证地址。") }
        baseURL = url.hasDirectoryPath ? url : url.appendingPathComponent("")
        authorization = "Bearer " + token
    }
    private static func validate(_ url: URL) throws {
        let loopback = ["127.0.0.1", "localhost", "::1"].contains(url.host ?? "")
        guard url.host != nil, url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              url.scheme == "https" || (url.scheme == "http" && loopback) else { throw PBError.invalid("请输入 HTTPS 存储目录地址，凭据请填写在独立输入框。") }
    }
    public func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil) // 不把授权头带到重定向目标，也不在跳转后提交写入。
    }
    private func request(_ method: String, name: String? = nil, body: Data? = nil, headers: [String: String] = [:]) async throws -> StoredBlob {
        if let name, !SafeFile.validName(name) { throw PBError.invalid("无效的存储对象名称。") }
        var request = URLRequest(url: name.map { baseURL.appendingPathComponent($0) } ?? baseURL)
        request.httpMethod = method; request.httpBody = body
        request.setValue(authorization, forHTTPHeaderField: "Authorization")
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        let data: Data; let response: URLResponse
        do { (data, response) = try await session.data(for: request) }
        catch { throw PBError.unavailable }
        guard let response = response as? HTTPURLResponse else { throw PBError.unavailable }
        switch response.statusCode {
        case 200...299: break
        case 401,403: throw PBError.unauthorized
        case 409,412: throw PBError.conflict
        case 507: throw PBError.quota
        case 404: throw PBError.invalid("存储目录或对象不存在，请检查位置和文件下载状态。")
        default: throw PBError.unavailable
        }
        guard data.count <= 128 * 1024 * 1024 else { throw PBError.invalid("远端对象超过大小上限。") }
        return StoredBlob(data: data, version: response.value(forHTTPHeaderField: "ETag"))
    }
    public func list() async throws -> [String] {
        let blob = try await request("PROPFIND", body: Data("<?xml version=\"1.0\"?><d:propfind xmlns:d=\"DAV:\"><d:prop><d:resourcetype/><d:getetag/></d:prop></d:propfind>".utf8), headers: ["Depth": "1", "Content-Type": "application/xml"])
        guard blob.data.count <= 8 * 1024 * 1024 else { throw PBError.invalid("远端目录清单过大。") }
        let delegate = DAVListing(base: baseURL)
        let parser = XMLParser(data: blob.data); parser.shouldProcessNamespaces = true
        parser.shouldResolveExternalEntities = false; parser.delegate = delegate
        guard parser.parse(), !delegate.invalid else { throw PBError.damaged }
        return Array(Set(delegate.names)).sorted()
    }
    public func read(_ name: String) async throws -> StoredBlob { try await request("GET", name: name) }
    public func create(_ name: String, data: Data) async throws {
        _ = try await request("PUT", name: name, body: data, headers: ["If-None-Match": "*", "Content-Type": "application/octet-stream"])
        let readback = try await read(name)
        guard readback.data == data else { throw PBError.damaged }
    }
    public func replace(_ name: String, data: Data, version: String) async throws {
        guard version.hasPrefix("\""), version.hasSuffix("\""), !version.hasPrefix("W/") else { throw PBError.invalid("此服务器没有可用的强版本标识，已拒绝覆盖。") }
        _ = try await request("PUT", name: name, body: data, headers: ["If-Match": version, "Content-Type": "application/octet-stream"])
        guard try await read(name).data == data else { throw PBError.damaged }
    }
}

private final class DAVListing: NSObject, XMLParserDelegate {
    let base: URL
    var names: [String] = []; var text = ""; var href = false; var invalid = false
    init(base: URL) { self.base = base }
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String]) {
        if elementName == "href" { href = true; text = "" }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) { if href { text += string } }
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        guard elementName == "href" else { return }; href = false
        guard let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines), relativeTo: base)?.absoluteURL,
              url.scheme == base.scheme, url.host == base.host, url.port == base.port else { invalid = true; return }
        let prefix = base.path.hasSuffix("/") ? base.path : base.path + "/"
        guard url.path.hasPrefix(prefix) else { if url.path != base.path { invalid = true }; return }
        let name = String(url.path.dropFirst(prefix.count))
        if SafeFile.validName(name) { names.append(name) }
    }
    func parser(_ parser: XMLParser, foundExternalEntityDeclarationWithName name: String, publicID: String?, systemID: String?) { invalid = true; parser.abortParsing() }
}
