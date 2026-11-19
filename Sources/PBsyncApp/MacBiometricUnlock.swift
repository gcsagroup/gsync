#if os(macOS)
import CryptoKit
import Darwin
import Foundation
import LocalAuthentication
import PBsyncCore
import Security

/// 本机文件只保存 Secure Enclave 封装数据与密文，不保存可直接使用的私钥或解锁密钥。
enum MacBiometricUnlock {
    struct Envelope: Codable {
        var version = 1
        var binding: String
        var handle: Data
        var peer: Data
        var salt: Data
        var sealed: Data

        func validate(for file: URL) throws {
            guard version == 1, binding == MacBiometricUnlock.binding(file),
                  !handle.isEmpty, handle.count <= 16_384, peer.count == 65,
                  salt.count == 32, sealed.count == 60 else { throw PBError.damaged }
            _ = try P256.KeyAgreement.PublicKey(x963Representation: peer)
        }
    }

    static func checkAvailability() throws {
        guard SecureEnclave.isAvailable else {
            throw PBError.invalid("这台 Mac 无法使用 Secure Enclave，请使用主密码解锁。")
        }
    }

    private static func binding(_ file: URL) -> String {
        Crypto.digest(Data(file.standardizedFileURL.path.utf8))
    }

    static func storageURL(_ file: URL) -> URL {
        file.deletingLastPathComponent().appendingPathComponent("device-unlock", isDirectory: true)
            .appendingPathComponent(binding(file) + ".json")
    }

    private static func context(_ file: URL) -> Data {
        Data("PBsync|mac-device-unlock|1|\(binding(file))".utf8)
    }

    /// 公钥封装不需要指纹；真正解封装必须在安全硬件中完成私钥运算。
    static func makeEnvelope(_ key: Data, file: URL, authentication: LAContext) throws -> Envelope {
        try checkAvailability()
        guard key.count == 32,
              let access = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
                                                          [.privateKeyUsage, .biometryCurrentSet], nil) else {
            throw PBError.damaged
        }
        let hardware = try SecureEnclave.P256.KeyAgreement.PrivateKey(accessControl: access,
                                                                     authenticationContext: authentication)
        let ephemeral = P256.KeyAgreement.PrivateKey()
        let salt = try Crypto.random(32)
        let shared = try ephemeral.sharedSecretFromKeyAgreement(with: hardware.publicKey)
        let wrapping = shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: salt,
                                                      sharedInfo: context(file), outputByteCount: 32)
        return Envelope(binding: binding(file), handle: hardware.dataRepresentation,
                        peer: ephemeral.publicKey.x963Representation, salt: salt,
                        sealed: try Crypto.seal(key, key: wrapping, context: context(file)))
    }

    static func open(_ envelope: Envelope, file: URL, authentication: LAContext) throws -> Data {
        try envelope.validate(for: file)
        let hardware = try SecureEnclave.P256.KeyAgreement.PrivateKey(dataRepresentation: envelope.handle,
                                                                     authenticationContext: authentication)
        let peer = try P256.KeyAgreement.PublicKey(x963Representation: envelope.peer)
        let shared = try hardware.sharedSecretFromKeyAgreement(with: peer)
        let wrapping = shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: envelope.salt,
                                                      sharedInfo: context(file), outputByteCount: 32)
        return try Crypto.open(envelope.sealed, key: wrapping, context: context(file))
    }

    static func save(_ key: Data, file: URL, authentication: LAContext) throws {
        let envelope = try makeEnvelope(key, file: file, authentication: authentication)
        // 保存前实际验证硬件权限与密文，失败时保留此前有效的本机解锁记录。
        var checked = try open(envelope, file: file, authentication: authentication)
        defer { checked.resetBytes(in: 0..<checked.count) }
        guard checked == key else { throw PBError.damaged }
        let url = storageURL(file), directory = url.deletingLastPathComponent()
        try SafeFile.privateDirectory(directory)
        guard try directory.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else {
            throw PBError.invalid("本机解锁目录不能是符号链接。")
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        var localDirectory = directory; try localDirectory.setResourceValues(values)
        try SafeFile.write(JSONEncoder().encode(envelope), to: url)
    }

    static func load(_ file: URL) throws -> Envelope {
        let url = storageURL(file)
        guard try url.deletingLastPathComponent().resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else {
            throw PBError.damaged
        }
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { throw PBError.damaged }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var attributes = stat()
        guard fstat(descriptor, &attributes) == 0,
              attributes.st_mode & S_IFMT == S_IFREG, attributes.st_uid == geteuid(),
              attributes.st_mode & 0o077 == 0, (1...65_536).contains(attributes.st_size) else {
            throw PBError.damaged
        }
        let data = try handle.read(upToCount: 65_537) ?? Data()
        guard data.count <= 65_536 else { throw PBError.damaged }
        let envelope = try JSONDecoder().decode(Envelope.self, from: data)
        try envelope.validate(for: file)
        return envelope
    }

    static func configured(_ file: URL) -> Bool { SecureEnclave.isAvailable && (try? load(file)) != nil }

    static func read(_ file: URL, authentication: LAContext) throws -> Data? {
        do { return try open(load(file), file: file, authentication: authentication) }
        catch let error as LAError where [.userCancel, .systemCancel, .appCancel].contains(error.code) { return nil }
        catch {
            throw PBError.invalid("本机指纹解锁记录不可用。请用主密码打开资料，在设置中关闭后重新启用 Touch ID。")
        }
    }

    static func remove(_ file: URL) throws {
        let url = storageURL(file)
        if FileManager.default.fileExists(atPath: url.path) {
            guard try url.deletingLastPathComponent().resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else {
                throw PBError.damaged
            }
            try FileManager.default.removeItem(at: url)
        }
    }
}
#endif
