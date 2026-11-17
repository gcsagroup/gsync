import AuthenticationServices
import SwiftUI
import PBsyncCore

struct ExchangeReceiver: ViewModifier {
    @EnvironmentObject var model: AppModel
    @State private var token: UUID?
    func body(content: Content) -> some View {
        if #available(macOS 26, iOS 26, *) {
            content.onContinueUserActivity(ASCredentialExchangeActivity) { activity in
                token = activity.userInfo?[ASCredentialImportToken] as? UUID
            }.safeAreaInset(edge: .bottom) {
                if let token {
                    HStack {
                        Text("选择并解锁接收凭据的保险库。")
                        Button("预览系统凭据") {
                            guard let id = model.selectedID, model.current?.kind == .vault else { return }
                            let session = model.spaceSession(id)
                            self.token = nil
                            Task {
                                do {
                                    let data = try await ASCredentialImportManager().importCredentials(token: token)
                                    guard model.selectedID == id, model.current?.kind == .vault,
                                          model.spaceSession(id) == session else { throw PBError.locked }
                                    model.preview = try CredentialExchange.preview(data)
                                    model.importTarget = id
                                } catch { model.report(error) }
                            }
                        }.disabled(model.current?.kind != .vault)
                        Button("取消") { self.token = nil }
                    }.padding(8)
                }
            }
        } else { content }
    }
}

@available(macOS 26, iOS 26, *)
struct ExportPasskey: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.credentialExportManager) private var manager
    let id: UUID
    var body: some View {
        Button("通过系统转移此通行密钥…") {
            guard let target = model.selectedID else { return }
            let session = model.spaceSession(target)
            Task {
                do {
                    let options = try await manager.requestExport()
                    guard model.selectedID == target, model.spaceSession(target) == session,
                          let state = model.current, let row = state.current[id], !row.deleted,
                          let bytes = row.item.sourceData["pbsync.passkey.v1"] else { throw PBError.locked }
                    let material = try Coding.decode(PasskeyMaterial.self, from: bytes)
                    let now = Date()
                    let entry = ASImportableItem(id: Data(id.uuidString.utf8), created: now, lastModified: now,
                                                 title: row.item.title, credentials: [try CredentialExchange.credential(material)])
                    let account = ASImportableAccount(id: Data(target.uuidString.utf8), userName: state.name,
                                                      email: "", collections: [], items: [entry])
                    try await manager.exportCredentials(.init(accounts: [account], formatVersion: options.formatVersion,
                                                              exporterRelyingPartyIdentifier: "com.gcsa.pbsync",
                                                              exporterDisplayName: "PBsync", timestamp: now))
                } catch { model.report(error) }
            }
        }
    }
}
