import AuthenticationServices
import CryptoKit
import XCTest
@testable import PBsyncCore

final class CredentialExchangeTests: XCTestCase {
    func testMigratedKeyAnswersOriginalRegistration() throws {
        guard #available(macOS 26, iOS 26, *) else { throw XCTSkip("需要系统凭据交换框架") }
        let original = try PasskeyMaterial(relyingParty:"example.invalid",userName:"demo",userHandle:Data([1,2]))
        let registered = try P256.Signing.PrivateKey(rawRepresentation:original.privateKey).publicKey
        let now = Date()
        let row = ASImportableItem(id:Data([1]),created:now,lastModified:now,title:"验收",credentials:[try CredentialExchange.credential(original)])
        let account = ASImportableAccount(id:Data([2]),userName:"demo",email:"",collections:[],items:[row])
        let packet = ASExportedCredentialData(accounts:[account],formatVersion:.v1,exporterRelyingPartyIdentifier:"example.invalid",exporterDisplayName:"合成来源",timestamp:now)
        let preview = try CredentialExchange.preview(packet)
        let key = try Coding.decode(PasskeyMaterial.self,from:XCTUnwrap(preview.items.first?.sourceData["pbsync.passkey.v1"]))
        XCTAssertEqual(key.credentialID,original.credentialID)
        let challenge = try Crypto.random(32)
        let answer = try key.assertion(clientDataHash:challenge)
        XCTAssertTrue(try registered.isValidSignature(.init(derRepresentation:answer.signature),for:answer.authenticatorData + challenge))
        XCTAssertFalse(try registered.isValidSignature(.init(derRepresentation:answer.signature),for:answer.authenticatorData + Crypto.random(32)))
    }
}
