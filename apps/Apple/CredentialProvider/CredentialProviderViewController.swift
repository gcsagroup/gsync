import AuthenticationServices
import SwiftUI
import PBsyncCore
#if os(macOS)
import AppKit
#else
import UIKit
#endif

@MainActor final class ProviderModel: ObservableObject {
    @Published var entries: [CatalogEntry] = []
    @Published var selectedID: UUID?
    @Published var password = ""
    @Published var state: SpaceState?
    @Published var error: String?
    @Published var busy = false
    @Published var services: [ASCredentialServiceIdentifier] = []
    @Published var registration: ASPasskeyCredentialRequest?
    @Published var assertion: ASPasskeyCredentialRequest?
    @Published var parameters: ASPasskeyCredentialRequestParameters?
    @Published var requestedRecord: String?
    @Published var oneTimeCode = false
    private var generation = UUID()
    var stores: [UUID: VaultStore] = [:]
    weak var controller: CredentialProviderViewController?
    var items: [Item] {
        guard let state else { return [] }
        return state.items.filter { item in
            if let record = requestedRecord {
                guard let vault = selectedID, record == vault.uuidString.lowercased()+":"+item.id.uuidString.lowercased() else { return false }
            }
            if item.kind == .passkey {
                guard let data = item.sourceData["pbsync.passkey.v1"], let material = try? Coding.decode(PasskeyMaterial.self, from: data) else { return false }
                if let identity = assertion?.credentialIdentity as? ASPasskeyCredentialIdentity {
                    return material.relyingParty == identity.relyingPartyIdentifier.lowercased() && material.credentialID == identity.credentialID
                }
                if let parameters {
                    return material.relyingParty == parameters.relyingPartyIdentifier.lowercased() && (parameters.allowedCredentials.isEmpty || parameters.allowedCredentials.contains(material.credentialID))
                }
                return false
            }
            guard item.kind == .login || (oneTimeCode && item.kind == .totp) else { return false }
            if oneTimeCode && item.fields["totp"] == nil { return false }
            // 系统没有提供可验证的服务身份时不猜测目标。
            return services.contains { service in
                service.type == .URL ? CredentialPolicy.matches(item: item, pageURL: service.identifier) : CredentialPolicy.matchesDomain(item: item, domain: service.identifier)
            }
        }
    }
    func load() {
        do {
            let root = try AppPaths.root(), device = try AppPaths.deviceID(at: root)
            entries = try Catalog.read(at: root).filter { $0.kind == .vault }
            for entry in entries { stores[entry.id] = try VaultStore(fileURL: root.appendingPathComponent(entry.filename), deviceID: device) }
            selectedID = entries.first?.id
        } catch { show(error) }
    }
    func show(_ error: Error) { self.error = (error as? PBError)?.localizedDescription ?? "凭据请求未完成，未提供秘密。" }
    func unlock() async {
        guard let id = selectedID, let store = stores[id] else { return }; busy = true; defer { busy = false; password = "" }
        let epoch = generation
        do {
            try await store.unlock(password: password)
            let snapshot = try await store.snapshot()
            guard generation == epoch, selectedID == id else { await store.lock(); return }
            state = snapshot
            let identities: [any ASCredentialIdentity] = (state?.items ?? []).flatMap { item -> [any ASCredentialIdentity] in
                if item.kind == .login {
                    return item.urls.compactMap { url in
                        guard let origin = CredentialPolicy.origin(url) else { return nil }
                        return ASPasswordCredentialIdentity(serviceIdentifier: ASCredentialServiceIdentifier(identifier: origin, type: .URL), user: item.fields["username"] ?? "", recordIdentifier: id.uuidString.lowercased() + ":" + item.id.uuidString.lowercased())
                    }
                }
                if item.kind == .passkey, let data = item.sourceData["pbsync.passkey.v1"], let material = try? Coding.decode(PasskeyMaterial.self, from: data) {
                    return [ASPasskeyCredentialIdentity(relyingPartyIdentifier: material.relyingParty, userName: material.userName, credentialID: material.credentialID, userHandle: material.userHandle, recordIdentifier: id.uuidString.lowercased() + ":" + item.id.uuidString.lowercased())]
                }
                return []
            }
            ASCredentialIdentityStore.shared.saveCredentialIdentities(identities) { _, _ in }
        } catch { show(error) }
    }
    func select(_ item: Item) async {
        guard let selectedID, let store = stores[selectedID], let controller else { return }
        do {
            let epoch = generation
            let snapshot = try await store.snapshot()
            guard epoch == generation else { return }
            state = snapshot
            guard let item = items.first(where: { $0.id == item.id }) else { throw PBError.unauthorized }
            if item.kind == .passkey {
                guard let data = item.sourceData["pbsync.passkey.v1"] else { throw PBError.damaged }
                let material = try Coding.decode(PasskeyMaterial.self, from: data)
                guard let hash = assertion?.clientDataHash ?? parameters?.clientDataHash else { throw PBError.unauthorized }
                let response = try material.assertion(clientDataHash: hash)
                let credential = ASPasskeyAssertionCredential(userHandle: material.userHandle, relyingParty: material.relyingParty, signature: response.signature, clientDataHash: hash, authenticatorData: response.authenticatorData, credentialID: material.credentialID)
                controller.extensionContext.completeAssertionRequest(using: credential, completionHandler: nil)
            } else if oneTimeCode {
                guard let seed = item.fields["totp"] else { throw PBError.damaged }
                let config = try seed.hasPrefix("otpauth:") ? OTPConfiguration(uri: seed) : OTPConfiguration(secret: seed)
                if #available(macOS 15, iOS 18, *) { controller.extensionContext.completeOneTimeCodeRequest(using: ASOneTimeCodeCredential(code: try config.code()), completionHandler: nil) }
                else { throw PBError.unsupported }
            } else {
                controller.extensionContext.completeRequest(withSelectedCredential: ASPasswordCredential(user: item.fields["username"] ?? "", password: item.fields["password"] ?? ""), completionHandler: nil)
            }
            invalidate()
        } catch { show(error) }
    }
    func register() async {
        guard let request = registration, let identity = request.credentialIdentity as? ASPasskeyCredentialIdentity,
              let id = selectedID, let store = stores[id], state != nil else { return }
        do {
            guard request.clientDataHash.count == 32, request.supportedAlgorithms.contains(where: { $0.rawValue == -7 }) else { throw PBError.unsupported }
            if #available(macOS 15, iOS 18, *), let excluded = request.excludedCredentials {
                for item in state?.items ?? [] {
                    if let data = item.sourceData["pbsync.passkey.v1"], let existing = try? Coding.decode(PasskeyMaterial.self, from: data), existing.relyingParty == identity.relyingPartyIdentifier.lowercased(), excluded.contains(where: { $0.credentialID == existing.credentialID }) { throw PBError.invalid("此账号已有被排除的通行密钥，未重复创建。") }
                }
            }
            let material = try PasskeyMaterial(relyingParty: identity.relyingPartyIdentifier, userName: identity.userName, userHandle: identity.userHandle)
            let response = try material.registration()
            let epoch = generation
            _ = try await store.save(material.item())
            guard epoch == generation else { return }
            let credential = ASPasskeyRegistrationCredential(relyingParty: material.relyingParty, clientDataHash: request.clientDataHash, credentialID: material.credentialID, attestationObject: response.attestationObject)
            controller?.extensionContext.completeRegistrationRequest(using: credential, completionHandler: nil)
            invalidate()
        } catch { show(error) }
    }
    func invalidate() {
        generation = UUID(); state = nil; password = ""; registration = nil; assertion = nil
        parameters = nil; requestedRecord = nil; services = []; oneTimeCode = false; error = nil
        let active = Array(stores.values)
        Task { for store in active { await store.lock() } }
    }
    func cancel() { invalidate(); controller?.extensionContext.cancelRequest(withError: NSError(domain: ASExtensionErrorDomain, code: ASExtensionError.userCanceled.rawValue)) }
}

struct ProviderView: View {
    @ObservedObject var model: ProviderModel
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("PBsync · 安全填充", systemImage: "lock.shield").font(.title2.bold())
            if let registration = model.registration, let identity = registration.credentialIdentity as? ASPasskeyCredentialIdentity {
                Text("为 \(identity.relyingPartyIdentifier) 创建通行密钥").font(.headline)
                Text(identity.userName).foregroundStyle(.secondary)
            } else { Text(model.services.map(\.identifier).joined(separator: "、")).font(.callout).foregroundStyle(.secondary) }
            if model.state == nil {
                Picker("保险库", selection: $model.selectedID) { ForEach(Array(model.entries.enumerated()), id: \.element.id) { index, entry in Text("保险库 \(index + 1)").tag(Optional(entry.id)) } }
                SecureField("主密码", text: $model.password).textFieldStyle(.roundedBorder).onSubmit { Task { await model.unlock() } }
                Button("解锁并核对网站") { Task { await model.unlock() } }.buttonStyle(.borderedProminent).disabled(model.password.isEmpty || model.busy)
                if model.entries.isEmpty { Text("请先在 PBsync App 创建保险库并确认共享容器已获签名授权。").font(.caption) }
            } else if model.registration != nil { Button("确认创建通行密钥") { Task { await model.register() } }.buttonStyle(.borderedProminent) }
            else {
                if model.items.isEmpty { Text("没有精确匹配此服务的凭据。未获得服务身份时不会猜测。").foregroundStyle(.secondary) }
                List(model.items) { item in Button { Task { await model.select(item) } } label: { VStack(alignment: .leading) { Text(item.title); Text(item.fields["username"] ?? item.kind.label).font(.caption).foregroundStyle(.secondary) } } }
            }
            if let error = model.error { Text(error).foregroundStyle(.red).font(.callout) }
            Spacer();Button("取消") { model.cancel() }
        }.padding(24).frame(minWidth: 320, minHeight: 400)
    }
}

@MainActor final class CredentialProviderViewController: ASCredentialProviderViewController {
    private let model = ProviderModel()
    override func viewDidLoad() {
        super.viewDidLoad(); model.controller = self; model.load()
        #if os(macOS)
        view = NSHostingView(rootView: ProviderView(model: model))
        #else
        let host = UIHostingController(rootView: ProviderView(model: model));addChild(host)
        host.view.translatesAutoresizingMaskIntoConstraints = false;view.addSubview(host.view)
        NSLayoutConstraint.activate([host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),host.view.topAnchor.constraint(equalTo: view.topAnchor),host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)])
        host.didMove(toParent: self)
        #endif
    }
    #if os(macOS)
    override func viewDidDisappear() { super.viewDidDisappear(); model.invalidate() }
    #else
    override func viewDidDisappear(_ animated: Bool) { super.viewDidDisappear(animated); model.invalidate() }
    #endif
    override func prepareCredentialList(for serviceIdentifiers: [ASCredentialServiceIdentifier]) { model.services = serviceIdentifiers }
    override func prepareCredentialList(for serviceIdentifiers: [ASCredentialServiceIdentifier], requestParameters: ASPasskeyCredentialRequestParameters) { model.services = serviceIdentifiers; model.parameters = requestParameters }
    override func provideCredentialWithoutUserInteraction(for credentialRequest: any ASCredentialRequest) { extensionContext.cancelRequest(withError: NSError(domain: ASExtensionErrorDomain, code: ASExtensionError.userInteractionRequired.rawValue)) }
    override func prepareInterfaceToProvideCredential(for credentialRequest: any ASCredentialRequest) {
        model.requestedRecord = credentialRequest.credentialIdentity.recordIdentifier
        if let record = model.requestedRecord, let part = record.split(separator:":").first,
           let vault = UUID(uuidString:String(part)), model.entries.contains(where:{$0.id == vault}) { model.selectedID = vault }
        if let password = credentialRequest.credentialIdentity as? ASPasswordCredentialIdentity { model.services = [password.serviceIdentifier] }
        if let request = credentialRequest as? ASPasskeyCredentialRequest { model.assertion = request }
    }
    override func prepareInterface(forPasskeyRegistration registrationRequest: any ASCredentialRequest) {
        guard let request = registrationRequest as? ASPasskeyCredentialRequest else { extensionContext.cancelRequest(withError: NSError(domain: ASExtensionErrorDomain, code: ASExtensionError.failed.rawValue)); return }
        model.registration = request
    }
    @available(macOS 15, iOS 18, *)
    override func prepareOneTimeCodeCredentialList(for serviceIdentifiers: [ASCredentialServiceIdentifier]) { model.services = serviceIdentifiers; model.oneTimeCode = true }
    override func prepareInterfaceForExtensionConfiguration() { extensionContext.completeExtensionConfigurationRequest() }
}
