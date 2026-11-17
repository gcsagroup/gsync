import Foundation
import CryptoKit
#if os(macOS)
import Darwin
#endif

public struct BridgeWire: Codable, Sendable {
    public let id: UUID
    public let issuedAt: Int64
    public let sealed: Data
    public init(id: UUID, issuedAt: Int64, sealed: Data) { self.id = id; self.issuedAt = issuedAt; self.sealed = sealed }
    public func context(response: Bool) -> Data { Data("PBsync-bridge|1|\(response ? "resp" : "req")|\(id.uuidString.lowercased())|\(issuedAt)".utf8) }
    public static func make(payload: Data, token: Data, responseTo: BridgeWire? = nil) throws -> Self {
        guard token.count == 32 else { throw PBError.unauthorized }
        let base = BridgeWire(id: responseTo?.id ?? UUID(), issuedAt: responseTo?.issuedAt ?? Int64(Date().timeIntervalSince1970), sealed: Data())
        return BridgeWire(id: base.id, issuedAt: base.issuedAt, sealed: try Crypto.seal(payload, key: SymmetricKey(data: token), context: base.context(response: responseTo != nil)))
    }
    public func open(token: Data, response: Bool = false, now: Date = Date()) throws -> Data {
        guard token.count == 32, abs(now.timeIntervalSince1970 - Double(issuedAt)) <= 120, sealed.count <= 1_048_576 else { throw PBError.unauthorized }
        return try Crypto.open(sealed, key: SymmetricKey(data: token), context: context(response: response))
    }
}

#if os(macOS)
public final class NativeBridgeServer: @unchecked Sendable {
    private var descriptor: Int32 = -1
    private let path: String
    private let handler: @Sendable (Data) async -> Data
    private let queue = DispatchQueue(label: "com.gcsa.pbsync.native-listener")
    public static func socketPath(root: URL) -> String { "/tmp/pbsync-\(getuid())-\(Crypto.digest(Data(root.path.utf8)).prefix(12)).sock" }
    public init(root: URL, handler: @escaping @Sendable (Data) async -> Data) {
        path = Self.socketPath(root: root); self.handler = handler
    }
    public func start() throws {
        descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw PBError.unavailable }
        if FileManager.default.fileExists(atPath: path) {
            // 活跃的同一配置不可抢占；失效套接字才移除。
            if (try? Self.send(Data(), path: path)) != nil { close(descriptor); descriptor = -1; throw PBError.conflict }
            unlink(path)
        }
        var address = Self.address(path)
        let result = withUnsafePointer(to: &address) { pointer in pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        guard result == 0, chmod(path, S_IRUSR | S_IWUSR) == 0, listen(descriptor, 4) == 0 else { close(descriptor); descriptor = -1; throw PBError.unavailable }
        let fd = descriptor, handler = handler
        queue.async {
            while true {
                let client = accept(fd, nil, nil); if client < 0 { return }
                var uid: uid_t = 0, gid: gid_t = 0
                guard getpeereid(client, &uid, &gid) == 0, uid == getuid() else { close(client); continue }
                Task {
                    defer { close(client) }
                    do {
                        var timeout = timeval(tv_sec: 120, tv_usec: 0)
                        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
                        let data = try Self.receiveFrame(client)
                        let output = await handler(data); try Self.sendFrame(output, client)
                    } catch { /* 不记录密文、明文或来源标识。 */ }
                }
            }
        }
    }
    private static func address(_ path: String) -> sockaddr_un {
        var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            let bytes = Array(path.utf8) + [0]; raw.copyBytes(from: bytes.prefix(raw.count))
        }; return address
    }
    public static func send(_ data: Data, root: URL) throws -> Data { try send(data, path: socketPath(root: root)) }
    private static func send(_ data: Data, path: String) throws -> Data {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0); guard fd >= 0 else { throw PBError.unavailable }; defer { close(fd) }
        var address = address(path)
        let result = withUnsafePointer(to: &address) { pointer in pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        guard result == 0 else { throw PBError.unavailable }
        if data.isEmpty { return Data() }
        var timeout = timeval(tv_sec: 120, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        try sendFrame(data, fd); return try receiveFrame(fd)
    }
    private static func receiveFrame(_ fd: Int32) throws -> Data {
        func exact(_ count: Int) throws -> Data {
            var result = Data(count: count), offset = 0
            while offset < count {
                let size = result.withUnsafeMutableBytes { read(fd, $0.baseAddress!.advanced(by: offset), count - offset) }
                guard size > 0 else { throw PBError.unavailable }; offset += size
            }; return result
        }
        let header = try exact(4); let count = header.enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element) << (8 * $1.offset) }
        guard count > 0, count <= 1_048_576 else { throw PBError.invalid("浏览器消息大小超限。") }; return try exact(Int(count))
    }
    private static func sendFrame(_ data: Data, _ fd: Int32) throws {
        guard data.count <= 1_048_576 else { throw PBError.invalid("浏览器消息大小超限。") }
        var length = UInt32(data.count).littleEndian
        let frame = withUnsafeBytes(of: &length) { Data($0) } + data
        var offset = 0
        while offset < frame.count {
            let size = frame.withUnsafeBytes { Darwin.send(fd, $0.baseAddress!.advanced(by: offset), frame.count - offset, 0) }
            guard size > 0 else { throw PBError.unavailable }; offset += size
        }
    }
    deinit { if descriptor >= 0 { close(descriptor); unlink(path) } }
}
#endif
