import Foundation
import CryptoKit

/// 配对文件仅含临时公钥。双方必须在可信界面核对指纹，过期后重新开始。
public struct PairingInvitation: Codable, Equatable, Sendable {
    public let id: UUID
    public let publicKey: Data
    public let expiresAt: Date
    public init(id: UUID = UUID(), publicKey: Data, expiresAt: Date = Date().addingTimeInterval(300)) {
        self.id = id; self.publicKey = publicKey; self.expiresAt = expiresAt
    }
}
public struct PairingResponse: Codable, Sendable {
    public let invitationID: UUID
    public let senderPublicKey: Data
    public let sealed: Data
}
public final class PairingSession {
    private let key = Curve25519.KeyAgreement.PrivateKey()
    public let invitation: PairingInvitation
    private var consumed = false
    public init() { invitation = PairingInvitation(publicKey: key.publicKey.rawRepresentation) }
    public static func fingerprint(_ invite: PairingInvitation) throws -> String {
        String(Crypto.digest(try Coding.encode(invite)).prefix(24)).uppercased()
    }
    private static func context(_ invite: PairingInvitation, sender: Data) throws -> Data { try Coding.encode(invite) + sender }
    public static func respond(to invite: PairingInvitation, payload: Data, confirmedFingerprint: String, now: Date = Date()) throws -> PairingResponse {
        guard invite.expiresAt > now, invite.expiresAt.timeIntervalSince(now) <= 300,
              confirmedFingerprint == (try fingerprint(invite)) else { throw PBError.unauthorized }
        let key = Curve25519.KeyAgreement.PrivateKey()
        let shared = try key.sharedSecretFromKeyAgreement(with: Curve25519.KeyAgreement.PublicKey(rawRepresentation: invite.publicKey))
        let context = try context(invite, sender: key.publicKey.rawRepresentation)
        let wrapping = shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: Data(invite.id.uuidString.utf8), sharedInfo: context, outputByteCount: 32)
        return PairingResponse(invitationID: invite.id, senderPublicKey: key.publicKey.rawRepresentation, sealed: try Crypto.seal(payload, key: wrapping, context: context))
    }
    public func receive(_ response: PairingResponse, now: Date = Date()) throws -> Data {
        guard !consumed, invitation.expiresAt > now, response.invitationID == invitation.id else { throw PBError.unauthorized }
        let context = try Self.context(invitation, sender: response.senderPublicKey)
        let shared = try key.sharedSecretFromKeyAgreement(with: Curve25519.KeyAgreement.PublicKey(rawRepresentation: response.senderPublicKey))
        let wrapping = shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: Data(invitation.id.uuidString.utf8), sharedInfo: context, outputByteCount: 32)
        let payload = try Crypto.open(response.sealed, key: wrapping, context: context)
        consumed = true; return payload
    }
}
