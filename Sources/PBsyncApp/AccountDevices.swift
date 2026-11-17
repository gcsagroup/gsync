import SwiftUI
import PBsyncCore

/// 此入口仅连接固定的本机验证服务，不能把账号密码重定向到外部。
private final class LocalRequests: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    static let shared = LocalRequests()
    lazy var session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: nil)
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

struct AccountDevicesView: View {
    @EnvironmentObject var model: AppModel
    @State private var action = "登录"
    @State private var name = ""
    @State private var password = ""
    @State private var recovery = ""
    @State private var owner = ""
    @State private var encoded = ""
    @State private var fingerprint = ""
    @State private var outgoing = ""
    @State private var space = "personal"
    @State private var invitation: PairingSession?
    @State private var devices: [[String:String]] = []
    @State private var working = false
    private let base = "http://127.0.0.1:47852"
    var body: some View {
        DisclosureGroup("本地账号与设备") {
            if owner.isEmpty {
                Picker("账号操作", selection: $action) { ForEach(["登录","注册","重置密码"], id: \.self) { Text($0) } }
                TextField("本地账号", text: $name)
                SecureField("账号密码（至少 12 个字符）", text: $password)
                if action == "重置密码" { SecureField("账号恢复码", text: $recovery) }
                Button(action) { perform {
                    let route = action == "注册" ? "register" : action == "登录" ? "login" : "reset"
                    let response = try await call(route, ["name":name,"password":password,"recovery":recovery])
                    owner = try string(response,"token"); invitation = nil; encoded = ""; fingerprint = ""; outgoing = ""; password = ""; recovery = response["recovery"] as? String ?? ""
                } }.disabled(name.isEmpty || password.count < 12)
                Button("新设备：生成邀请") { perform {
                    let session = PairingSession(); invitation = session
                    outgoing = try Coding.encode(session.invitation).base64EncodedString()
                    fingerprint = try PairingSession.fingerprint(session.invitation)
                } }
                if invitation != nil {
                    Text("请在另一台设备上核对指纹：\(fingerprint)").textSelection(.enabled)
                    TextField("粘贴批准回执", text: $encoded)
                    Button("接收此空间的访问权限") { perform {
                        guard let invitation else { throw PBError.unauthorized }
                        let reply: PairingResponse = try decode(encoded)
                        let grant = try Coding.decode([String:String].self, from: invitation.receive(reply))
                        try configure(grant)
                        self.invitation = nil; encoded = ""; outgoing = ""; fingerprint = ""
                    } }
                }
            } else {
                if !recovery.isEmpty {
                    Text("请单独保管账号恢复码。它只能重置账号，不能解密保险库。")
                    Button("复制账号恢复码") { model.copy(recovery) }
                }
                TextField("空间目录名", text: $space)
                Button("授权本机访问此空间") { perform {
                    let grant = try await call("approve",["space":space])
                    try configure(["space":space,"token":try string(grant,"token")]); try await refreshDevices()
                } }
                TextField("粘贴新设备邀请", text: $encoded)
                TextField("输入从新设备独立核对的指纹", text: $fingerprint)
                Button("批准此设备访问上述空间") { perform {
                    let invite: PairingInvitation = try decode(encoded)
                    guard try PairingSession.fingerprint(invite) == fingerprint.uppercased(), invite.publicKey.count == 32, (0...300).contains(invite.expiresAt.timeIntervalSinceNow) else { throw PBError.unauthorized }
                    let reply = try await call("approve",["space":space])
                    let grant = ["space":space,"token":try string(reply,"token")]
                    do {
                        let sealed = try PairingSession.respond(to: invite, payload: Coding.encode(grant), confirmedFingerprint: fingerprint.uppercased())
                        outgoing = try Coding.encode(sealed).base64EncodedString()
                    } catch {
                        if let device = reply["device"] as? String { _ = try? await call("revoke",["device":device]) }
                        throw error
                    }
                    try await refreshDevices()
                } }
                Button("刷新已批准设备") { perform { try await refreshDevices() } }
                ForEach(devices, id: \.self) { d in
                    Button("撤销 \(d["space"] ?? "") · \(d["device"] ?? "")", role: .destructive) {
                        perform { _ = try await call("revoke",d); try await refreshDevices() }
                    }
                }
                Button("退出账号会话") { perform { _ = try await call("logout",[:]); owner = ""; recovery = ""; devices = []; outgoing = ""; model.settings.secret = "" } }
            }
            if !outgoing.isEmpty { Button(invitation == nil ? "复制加密回执给新设备" : "复制邀请给批准设备") { model.copy(outgoing) } }
            Text("批准仅提供同步目录访问权；保险库仍需单独解锁。撤销不会擦除设备已下载的副本。配置填入下方表单后，请核对再保存或连接。").font(.caption)
        }.disabled(working)
    }
    private func perform(_ work: @escaping @MainActor () async throws -> Void) {
        guard !working else { return }; working = true
        Task { @MainActor in defer { working = false }; do { try await work() } catch { model.report(error) } }
    }
    private func configure(_ grant: [String:String]) throws {
        guard let scope = grant["space"], scope.range(of: "^[a-zA-Z0-9_-]{1,64}$", options:.regularExpression) != nil, let token = grant["token"] else { throw PBError.damaged }
        model.settings.kind = .localCloud; model.settings.endpoint = base + "/account/" + scope + "/"; model.settings.secret = token
    }
    private func decode<T: Decodable>(_ s: String) throws -> T {
        guard s.count <= 8192, let data = Data(base64Encoded:s) else { throw PBError.damaged }
        return try Coding.decode(T.self, from:data)
    }
    private func string(_ d: [String:Any], _ k: String) throws -> String {
        guard let v = d[k] as? String else { throw PBError.damaged }; return v
    }
    private func refreshDevices() async throws { devices = try await call("devices",[:])["devices"] as? [[String:String]] ?? [] }
    private func call(_ route: String, _ fields: [String:String]) async throws -> [String:Any] {
        let epoch = model.sensitivePresentationID
        var req = URLRequest(url:URL(string:base + "/auth/" + route)!)
        req.httpMethod = "POST"; req.timeoutInterval = 8; req.setValue("application/json", forHTTPHeaderField:"Content-Type")
        if !owner.isEmpty { req.setValue("Bearer " + owner, forHTTPHeaderField:"Authorization") }
        req.httpBody = try Coding.encode(fields)
        let (data,response) = try await LocalRequests.shared.session.data(for:req)
        guard epoch == model.sensitivePresentationID else { throw PBError.locked }
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw PBError.invalid("本地账号请求未通过。请检查账号、恢复码、空间名称或会话有效期。") }
        guard let object = try JSONSerialization.jsonObject(with:data) as? [String:Any] else { throw PBError.damaged }
        return object
    }
}
