import Foundation
import CryptoKit

public struct OTPConfiguration: Codable, Equatable, Sendable {
    public var secret: String
    public var algorithm: String
    public var digits: Int
    public var period: Int
    public init(secret: String, algorithm: String = "SHA1", digits: Int = 6, period: Int = 30) {
        self.secret = secret; self.algorithm = algorithm.uppercased(); self.digits = digits; self.period = period
    }
    public init(uri: String) throws {
        guard let parts = URLComponents(string: uri), parts.scheme == "otpauth", parts.host == "totp" else { throw PBError.invalid("请输入 TOTP 密钥或 otpauth://totp 地址。") }
        let pairs = parts.queryItems ?? []
        guard Set(pairs.map(\.name)).count == pairs.count else { throw PBError.invalid("验证码地址含重复参数。") }
        let values = Dictionary(uniqueKeysWithValues: pairs.map { ($0.name, $0.value ?? "") })
        guard let secret = values["secret"] else { throw PBError.invalid("验证码地址缺少密钥。") }
        self.init(secret: secret, algorithm: values["algorithm"] ?? "SHA1", digits: Int(values["digits"] ?? "6") ?? 0, period: Int(values["period"] ?? "30") ?? 0)
    }
    public func code(at time: TimeInterval = Date().timeIntervalSince1970) throws -> String {
        guard (6...8).contains(digits), (15...120).contains(period), time >= 0,
              ["SHA1", "SHA256", "SHA512"].contains(algorithm) else { throw PBError.invalid("验证码算法、位数或周期无效。") }
        let bytes = try Self.base32(secret); let key = SymmetricKey(data: bytes)
        var counter = UInt64(time / Double(period)).bigEndian
        let message = withUnsafeBytes(of: &counter) { Data($0) }
        let hash: [UInt8]
        switch algorithm {
        case "SHA256": hash = Array(HMAC<SHA256>.authenticationCode(for: message, using: key))
        case "SHA512": hash = Array(HMAC<SHA512>.authenticationCode(for: message, using: key))
        default: hash = Array(HMAC<Insecure.SHA1>.authenticationCode(for: message, using: key))
        }
        let offset = Int(hash.last! & 0x0f)
        let value = (UInt32(hash[offset]) & 0x7f) << 24 | UInt32(hash[offset + 1]) << 16 | UInt32(hash[offset + 2]) << 8 | UInt32(hash[offset + 3])
        return String(format: "%0*u", digits, value % UInt32(pow(10.0, Double(digits))))
    }
    public static func base32(_ text: String) throws -> Data {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")
        var buffer: UInt32 = 0, bits = 0, result = Data(), padding = false
        for character in text.uppercased().filter({ !$0.isWhitespace }) {
            if character == "=" { padding = true; continue }
            guard !padding, let value = alphabet.firstIndex(of: character) else { throw PBError.invalid("验证码密钥不是有效的 Base32。") }
            buffer = (buffer << 5) | UInt32(value); bits += 5
            if bits >= 8 { bits -= 8; result.append(UInt8((buffer >> bits) & 0xff)) }
        }
        guard result.count >= 10, result.count <= 128, bits == 0 || buffer & ((1 << bits) - 1) == 0 else { throw PBError.invalid("验证码密钥长度或末尾编码无效。") }
        return result
    }
}

public struct PasskeyMaterial: Codable, Equatable, Sendable {
    public var relyingParty: String
    public var userName: String
    public var userHandle: Data
    public var credentialID: Data
    public var privateKey: Data
    public init(relyingParty: String, userName: String, userHandle: Data) throws {
        guard !relyingParty.isEmpty, !relyingParty.contains("/"), !relyingParty.contains(":"), !userHandle.isEmpty, userHandle.count <= 64 else { throw PBError.invalid("通行密钥身份参数无效。") }
        self.relyingParty = relyingParty.lowercased(); self.userName = userName; self.userHandle = userHandle
        credentialID = try Crypto.random(32); privateKey = P256.Signing.PrivateKey().rawRepresentation
    }
    private func authenticatorData(registration: Bool) throws -> Data {
        var data = Data(SHA256.hash(data: Data(relyingParty.utf8)))
        // 已验证用户存在及身份；可备份并已纳入加密同步。签名计数为 0。
        data.append(registration ? 0x5d : 0x1d); data.append(contentsOf: [0, 0, 0, 0])
        if registration {
            guard (1...1023).contains(credentialID.count) else { throw PBError.damaged }
            data.append(Data(repeating: 0, count: 16))
            data.append(contentsOf: [UInt8(credentialID.count >> 8), UInt8(truncatingIfNeeded: credentialID.count)])
            data.append(credentialID)
            let publicKey = try P256.Signing.PrivateKey(rawRepresentation: privateKey).publicKey.x963Representation
            data.append(contentsOf: [0xa5, 0x01, 0x02, 0x03, 0x26, 0x20, 0x01, 0x21, 0x58, 0x20])
            data.append(publicKey[1..<33]); data.append(contentsOf: [0x22, 0x58, 0x20]); data.append(publicKey[33..<65])
        }
        return data
    }
    /// 仅在系统已核实 RP 身份且用户通过解锁确认后调用。
    public func registration() throws -> (authenticatorData: Data, attestationObject: Data) {
        let auth = try authenticatorData(registration: true)
        func text(_ value: String) -> Data { Data([0x60 | UInt8(value.utf8.count)]) + Data(value.utf8) }
        var cbor = Data([0xa3]); cbor += text("fmt"); cbor += text("none"); cbor += text("attStmt"); cbor.append(0xa0)
        cbor += text("authData"); if auth.count <= 255 { cbor.append(contentsOf: [0x58, UInt8(auth.count)]) }
        else { cbor.append(contentsOf: [0x59, UInt8(auth.count >> 8), UInt8(truncatingIfNeeded: auth.count)]) }
        cbor += auth
        return (auth, cbor)
    }
    public func assertion(clientDataHash: Data) throws -> (authenticatorData: Data, signature: Data) {
        guard clientDataHash.count == 32 else { throw PBError.invalid("通行密钥挑战摘要长度无效。") }
        let auth = try authenticatorData(registration: false)
        let signature = try P256.Signing.PrivateKey(rawRepresentation: privateKey).signature(for: auth + clientDataHash).derRepresentation
        return (auth, signature)
    }
    public func item() throws -> Item {
        Item(kind: .passkey, title: relyingParty + " · " + userName, urls: ["https://" + relyingParty], fields: ["username": userName], sourceData: ["pbsync.passkey.v1": try Coding.encode(self)])
    }
}
