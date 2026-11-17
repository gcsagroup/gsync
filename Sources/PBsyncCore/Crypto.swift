import Foundation
import CryptoKit
import CommonCrypto
import Security

public struct SpaceHeader: Codable, Equatable, Sendable {
    public var format: Int = 1
    public var spaceID: UUID
    public var keyEpoch: Int = 1
    public var salt: Data
    public var iterations: UInt32
    public var passwordSlot: Data
    public var recoverySlot: Data
    public func context(_ purpose: String) -> Data {
        Data("PBsync|\(format)|\(spaceID.uuidString.lowercased())|\(keyEpoch)|\(purpose)".utf8)
    }
    public func validate() throws {
        guard format == 1, keyEpoch > 0, salt.count == 32, (600_000...2_000_000).contains(iterations),
              passwordSlot.count == 60, recoverySlot.count == 60 else { throw PBError.unsupported }
    }
}

public struct EncryptedObject: Codable, Equatable, Sendable {
    public var id: UUID
    public var spaceID: UUID
    public var keyEpoch: Int
    public var sealed: Data
}

public struct Archive: Codable, Equatable, Sendable {
    public var header: SpaceHeader
    public var sealedState: Data
    public init(header: SpaceHeader, sealedState: Data) { self.header = header; self.sealedState = sealedState }
}

public enum Crypto {
    public static let passwordIterations: UInt32 = 600_000
    public static func random(_ count: Int) throws -> Data {
        var data = Data(count: count)
        let status = data.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, count, $0.baseAddress!) }
        guard status == errSecSuccess else { throw PBError.unavailable }; return data
    }
    public static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    public static func derive(password: String, salt: Data, iterations: UInt32) throws -> SymmetricKey {
        guard password.utf8.count <= 4096, salt.count >= 16, (1...2_000_000).contains(iterations) else { throw PBError.invalid("口令派生参数无效。") }
        let passwordBytes = Array(password.utf8)
        var output = [UInt8](repeating: 0, count: 32)
        let status = passwordBytes.withUnsafeBytes { passwordPtr in
            salt.withUnsafeBytes { saltPtr in
                CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2),
                    passwordPtr.bindMemory(to: Int8.self).baseAddress, passwordBytes.count,
                    saltPtr.bindMemory(to: UInt8.self).baseAddress, salt.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), iterations, &output, output.count)
            }
        }
        guard status == kCCSuccess else { throw PBError.unavailable }
        defer { output.withUnsafeMutableBytes { $0.initializeMemory(as: UInt8.self, repeating: 0) } }
        return SymmetricKey(data: output)
    }
    public static func seal(_ data: Data, key: SymmetricKey, context: Data) throws -> Data {
        guard let combined = try AES.GCM.seal(data, using: key, authenticating: context).combined else { throw PBError.damaged }
        return combined
    }
    public static func open(_ data: Data, key: SymmetricKey, context: Data) throws -> Data {
        do { return try AES.GCM.open(AES.GCM.SealedBox(combined: data), using: key, authenticating: context) }
        catch { throw PBError.damaged }
    }
    public static func create(password: String, spaceID: UUID = UUID(), epoch: Int = 1) throws -> (header: SpaceHeader, key: SymmetricKey, recovery: String) {
        guard password.count >= 12 else { throw PBError.invalid("主密码至少需要 12 个字符。") }
        let rawKey = try random(32), recoveryBytes = try random(32)
        var header = SpaceHeader(spaceID: spaceID, keyEpoch: epoch, salt: try random(32), iterations: passwordIterations, passwordSlot: Data(), recoverySlot: Data())
        header.passwordSlot = try seal(rawKey, key: derive(password: password, salt: header.salt, iterations: header.iterations), context: header.context("password"))
        header.recoverySlot = try seal(rawKey, key: SymmetricKey(data: recoveryBytes), context: header.context("recovery"))
        return (header, SymmetricKey(data: rawKey), recoveryBytes.base64EncodedString())
    }
    public static func unlock(_ header: SpaceHeader, password: String) throws -> SymmetricKey {
        try header.validate()
        do {
            let key = try derive(password: password, salt: header.salt, iterations: header.iterations)
            return SymmetricKey(data: try open(header.passwordSlot, key: key, context: header.context("password")))
        } catch { throw PBError.wrongSecret }
    }
    public static func recover(_ header: SpaceHeader, recovery: String) throws -> SymmetricKey {
        try header.validate()
        guard let bytes = Data(base64Encoded: recovery.trimmingCharacters(in: .whitespacesAndNewlines)), bytes.count == 32 else { throw PBError.wrongSecret }
        do { return SymmetricKey(data: try open(header.recoverySlot, key: SymmetricKey(data: bytes), context: header.context("recovery"))) }
        catch { throw PBError.wrongSecret }
    }
    public static func rewrap(_ header: SpaceHeader, key: SymmetricKey, newPassword: String) throws -> SpaceHeader {
        guard newPassword.count >= 12 else { throw PBError.invalid("主密码至少需要 12 个字符。") }
        var result = header; result.salt = try random(32); result.iterations = passwordIterations
        result.passwordSlot = try seal(key.withUnsafeBytes { Data($0) }, key: derive(password: newPassword, salt: result.salt, iterations: result.iterations), context: result.context("password"))
        return result
    }
    public static func encrypt(_ revision: Revision, header: SpaceHeader, key: SymmetricKey) throws -> EncryptedObject {
        EncryptedObject(id: revision.id, spaceID: header.spaceID, keyEpoch: header.keyEpoch,
                        sealed: try seal(Coding.encode(revision), key: key, context: header.context("operation:\(revision.id.uuidString.lowercased())")))
    }
    public static func decrypt(_ object: EncryptedObject, header: SpaceHeader, key: SymmetricKey) throws -> Revision {
        guard object.spaceID == header.spaceID, object.keyEpoch == header.keyEpoch else { throw PBError.damaged }
        let revision = try Coding.decode(Revision.self, from: open(object.sealed, key: key, context: header.context("operation:\(object.id.uuidString.lowercased())")))
        guard revision.id == object.id else { throw PBError.damaged }; return revision
    }
    public static func archive(_ state: SpaceState, header: SpaceHeader, key: SymmetricKey) throws -> Archive {
        Archive(header: header, sealedState: try seal(Coding.encode(state), key: key, context: header.context("state")))
    }
    public static func restore(_ archive: Archive, key: SymmetricKey) throws -> SpaceState {
        try archive.header.validate()
        let state = try Coding.decode(SpaceState.self, from: open(archive.sealedState, key: key, context: archive.header.context("state")))
        var checked = SpaceState(name: state.name, kind: state.kind, generation: state.generation, retired: state.retired)
        try checked.merge(state.revisions); return checked
    }
}
