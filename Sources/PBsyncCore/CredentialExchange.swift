import AuthenticationServices
import CryptoKit
import Foundation

@available(macOS 26, iOS 26, *)
public enum CredentialExchange {
    public static func credential(_ material: PasskeyMaterial) throws -> ASImportableCredential {
        let key = try P256.Signing.PrivateKey(rawRepresentation: material.privateKey)
        return .passkey(.init(credentialID: material.credentialID, relyingPartyIdentifier: material.relyingParty,
                              userName: material.userName, userDisplayName: material.userName,
                              userHandle: material.userHandle, key: key.derRepresentation))
    }

    public static func preview(_ data: ASExportedCredentialData) throws -> ImportPreview {
        guard data.accounts.count == 1, let account = data.accounts.first, account.items.count <= 100_000 else {
            throw PBError.invalid("请每次从一个来源账户选择要迁移的凭据。")
        }
        let source = "exchange:" + data.exporterRelyingPartyIdentifier + ":" + account.id.base64EncodedString()
        var items: [Item] = []
        var warnings = Set<String>()
        if !account.collections.isEmpty { warnings.insert("来源集合层级暂未迁入。") }
        for row in account.items {
            let raw = try Coding.encode(row)
            for (index, credential) in row.credentials.enumerated() {
                var item = Item(kind: .note, title: row.title, urls: row.scope?.urls.map(\.absoluteString) ?? [], tags: row.tags)
                let prefix = source + ":" + row.id.base64EncodedString()
                item.id = Coding.stableID(prefix + ":" + String(index))
                switch credential {
                case .basicAuthentication(let login):
                    item.kind = .login
                    item.fields["username"] = login.userName?.value
                    item.fields["password"] = login.password?.value
                case .passkey(let passkey):
                    if #available(iOS 26.4, macOS 26.4, *), passkey.fido2Extensions != nil {
                        throw PBError.invalid("此通行密钥包含暂不支持的 FIDO 扩展，已停止导入。")
                    }
                    guard (1...1023).contains(passkey.credentialID.count) else { throw PBError.damaged }
                    let key = try P256.Signing.PrivateKey(derRepresentation: passkey.key)
                    var material = try PasskeyMaterial(relyingParty: passkey.relyingPartyIdentifier,
                                                       userName: passkey.userName, userHandle: passkey.userHandle)
                    material.privateKey = key.rawRepresentation
                    material.credentialID = passkey.credentialID
                    item.kind = .passkey
                    item.id = Coding.stableID("passkey:" + material.relyingParty + ":" + material.credentialID.base64EncodedString())
                    item.fields["username"] = material.userName
                    item.sourceData["pbsync.passkey.v1"] = try Coding.encode(material)
                case .note(let note): item.notes = note.content.value
                case .creditCard(let card):
                    item.kind = .card
                    item.fields["number"] = card.number?.value
                    item.fields["cardholder"] = card.fullName?.value
                    item.fields["expiry"] = card.expiryDate?.value
                    item.fields["cvv"] = card.verificationNumber?.value
                default: warnings.insert("部分类型仅保留加密原始数据，暂不支持直接使用。")
                }
                item.sourceData[source] = raw
                try item.validate(in: .vault)
                items.append(item)
            }
            guard !row.credentials.isEmpty else { throw PBError.invalid("来源包含空凭据，已停止导入。") }
        }
        guard Set(items.map(\.id)).count == items.count else { throw PBError.conflict }
        return ImportPreview(items: items, warnings: warnings.sorted(), source: source)
    }
}
