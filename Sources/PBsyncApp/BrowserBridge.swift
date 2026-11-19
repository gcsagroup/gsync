import SwiftUI
import PBsyncCore
#if os(macOS)
import AppKit
#endif

struct CredentialApproval: Identifiable {
    var id = UUID()
    let spaceID: UUID
    let title: String
    let origin: String
    let username: String
    let completion: (Bool) -> Void
}

#if os(macOS)
struct FillPermit {
    let key = UUID()
    let item: UUID
    let revision: UUID
    let url: String
    let session: String
    let expires = Date().addingTimeInterval(15)
}
private struct BridgeAuthorization: Codable { var token: String; var bookmarks: UUID?; var vault: UUID?; var autoOrigins: [String]; var savePages: [String: String]?; var backgroundBookmarks: Bool? }

extension AppModel {
    private var bridgeAccount: String { Crypto.digest(Data(root.path.utf8)) + ".browser-bridge" }
    func startBridge() {
        do {
            bridgeServer = NativeBridgeServer(root: root) { [weak self] data in
                guard let self else { return Data() }; return await self.handleBridge(data)
            }
            try bridgeServer?.start()
            // 钥匙串可能等待系统验证，不能在 App 初始化主线程同步读取。
            Task { await restoreBrowserAuthorization(interactive: false) }
        } catch { report(error) }
    }
    func restoreBrowserAuthorization(interactive: Bool) async {
        guard !restoringBridgeAuthorization else { return }
        restoringBridgeAuthorization = true
        defer { restoringBridgeAuthorization = false }
        let account = bridgeAccount, epoch = bridgeAuthorizationEpoch
        do {
            let bytes = try await Task.detached { try Keychain.read(account: account, allowInteraction: interactive) }.value
            guard epoch == bridgeAuthorizationEpoch else { return }
            if let bytes {
                let auth = try Coding.decode(BridgeAuthorization.self, from: bytes)
                bridgeToken = auth.token; bridgeBookmarkID = auth.bookmarks; bridgeVaultID = auth.vault
                bridgeActiveBookmarkID = auth.bookmarks; bridgeActiveVaultID = auth.vault
                backgroundBookmarks = auth.backgroundBookmarks == true
                backgroundBookmarkID = backgroundBookmarks ? auth.bookmarks : nil
                bridgeSavePages = auth.savePages ?? [:]
                autoSavePages = bridgeSavePages.values.sorted().joined(separator: "\n")
                bridgeActiveOrigins = Set(auth.autoOrigins); autoFillOrigins = auth.autoOrigins.joined(separator: "\n")
            }
            bridgeAuthorizationNeedsUnlock = false
        } catch {
            guard epoch == bridgeAuthorizationEpoch else { return }
            bridgeAuthorizationNeedsUnlock = true
            if interactive { report(error) }
        }
    }
    var pairableSpacesUnlocked: Bool {
        let ids = [bridgeBookmarkID,bridgeVaultID].compactMap { $0 }
        return !ids.isEmpty && ids.allSatisfy { states[$0] != nil }
    }
    var canCopyBridgeToken: Bool {
        let ids = [bridgeActiveBookmarkID,bridgeActiveVaultID].compactMap { $0 }
        return !ids.isEmpty && ids.allSatisfy { states[$0] != nil }
    }
    func pairBrowser() {
        do {
            guard pairableSpacesUnlocked else { throw PBError.invalid("请先选择并解锁要授权的空间。") }
            let token = try Crypto.random(32).base64EncodedString()
            let requested = autoFillOrigins.split(separator: "\n").map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            let origins = requested.compactMap(CredentialPolicy.origin)
            guard origins.count == requested.count else { throw PBError.invalid("自动填充范围仅允许有效 HTTPS 网站。") }
            var pages: [String: String] = [:]
            for line in autoSavePages.split(separator: "\n") {
                let text = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard let origin = CredentialPolicy.origin(text), let url = URLComponents(string: text),
                      !url.percentEncodedPath.isEmpty, url.percentEncodedPath != "/", url.query == nil, url.fragment == nil,
                      pages[origin] == nil, bridgeVaultID != nil else {
                    throw PBError.invalid("请指定授权保险库，并为每个网站填写一个固定的 HTTPS 登录成功页地址（含路径，无查询或片段）。")
                }
                pages[origin] = origin + url.percentEncodedPath
            }
            let authorization = BridgeAuthorization(token: token, bookmarks: bridgeBookmarkID, vault: bridgeVaultID, autoOrigins: origins, savePages: pages, backgroundBookmarks: backgroundBookmarks)
            try Keychain.save(Coding.encode(authorization), account: bridgeAccount)
            bridgeAuthorizationEpoch = UUID(); bridgeAuthorizationNeedsUnlock = false
            bridgeToken = token; bridgeSeen = [:]; fillPermit = nil; lastBookmarkBridgeExchange = [:]
            backgroundBookmarkID = backgroundBookmarks ? bridgeBookmarkID : nil
            bridgeActiveBookmarkID = bridgeBookmarkID; bridgeActiveVaultID = bridgeVaultID; bridgeActiveOrigins = Set(origins); bridgeSavePages = pages
        } catch { report(error) }
    }
    func revokeBrowsers() {
        do { try Keychain.remove(account: bridgeAccount); bridgeAuthorizationEpoch = UUID(); bridgeAuthorizationNeedsUnlock = false; bridgeToken = ""; backgroundBookmarkID = nil; bridgeSeen = [:]; fillPermit = nil; lastBookmarkBridgeExchange = [:] }
        catch { report(error) }
    }
    func handleBridge(_ bytes: Data) async -> Data {
        guard let token = Data(base64Encoded: bridgeToken), token.count == 32,
              let wire = try? Coding.decode(BridgeWire.self, from: bytes) else { return Data("{\"error\":\"连接未配对\"}".utf8) }
        do {
            let raw = try wire.open(token: token)
            bridgeSeen = bridgeSeen.filter { $0.value > Int64(Date().timeIntervalSince1970) - 120 }
            guard bridgeSeen[wire.id] == nil else { throw PBError.unauthorized }
            bridgeSeen[wire.id] = wire.issuedAt
            guard let request = try JSONSerialization.jsonObject(with: raw) as? [String: Any], let command = request["command"] as? String else { throw PBError.invalid("无效的扩展请求。") }
            let result = try await dispatchBridge(command, request: request)
            return try Coding.encode(BridgeWire.make(payload: JSONSerialization.data(withJSONObject: ["ok": true, "payload": result]), token: token, responseTo: wire))
        } catch {
            let message = (error as? PBError)?.localizedDescription ?? "扩展操作失败，未返回凭据。"
            let response = (try? JSONSerialization.data(withJSONObject: ["ok": false, "error": message])) ?? Data()
            return (try? Coding.encode(BridgeWire.make(payload: response, token: token, responseTo: wire))) ?? Data()
        }
    }
    private func dispatchBridge(_ command: String, request: [String: Any]) async throws -> Any {
        if command.hasPrefix("bookmarks.") {
            guard let id = bridgeActiveBookmarkID, let store = stores[id] else { throw PBError.invalid("请在 App 中授权一个收藏夹空间。") }
            let authorization = bridgeAuthorizationEpoch, session = spaceSession(id)
            let state = try await store.snapshot(); guard state.kind == .bookmarks else { throw PBError.unauthorized }
            guard authorization == bridgeAuthorizationEpoch, session == spaceSession(id), states[id] != nil else { throw PBError.locked }
            if command == "bookmarks.apply" {
                guard let values = request["items"] as? [[String: Any]], values.count <= 50_000,
                      let deleted = request["deleted"] as? [String], deleted.count <= 50_000 else { throw PBError.invalid("收藏夹同步请求格式无效。") }
                let items = try Coding.decode([Item].self, from: JSONSerialization.data(withJSONObject: values))
                let rawBaselines = request["baselines"] as? [String: Any]
                guard items.isEmpty && deleted.isEmpty || rawBaselines != nil else {
                    throw PBError.invalid("请更新浏览器扩展后同步，旧版扩展无法安全合并并发修改。")
                }
                let decoded = try Coding.decode([String: BrowserBookmarkBaseline].self,
                    from: JSONSerialization.data(withJSONObject: rawBaselines ?? [:]))
                guard decoded.count <= 50_000 else { throw PBError.quota }
                var baselines: [String: BrowserBookmarkBaseline] = [:]
                for (key, value) in decoded {
                    guard let uuid = UUID(uuidString: key),
                          baselines.updateValue(value, forKey: uuid.uuidString.lowercased()) == nil else { throw PBError.damaged }
                }
                var changed = items.isEmpty ? 0 : try await store.importItems(items, bookmarkBaselines: baselines)
                for text in deleted {
                    guard let itemID = UUID(uuidString: text) else { throw PBError.invalid("删除记录无效。") }
                    if let old = (try await store.snapshot()).current[itemID], !old.deleted { changed += try await store.delete(itemID) }
                }
                if changed > 0 {
                    try await refresh(id, userActivity: false)
                    status[id] = "已与浏览器合并 · 待同步到其他设备"
                    requestSync(id)
                }
            } else if command != "bookmarks.pull" { throw PBError.unsupported }
            let current = try await store.snapshot()
            guard authorization == bridgeAuthorizationEpoch, session == spaceSession(id), states[id] != nil else { throw PBError.locked }
            lastBookmarkBridgeExchange[id] = .now
            let items = try JSONSerialization.jsonObject(with: Coding.encode(current.items))
            let deleted = current.current.values.filter(\.deleted).map { $0.item.id.uuidString.lowercased() }
            return ["items": items, "deleted": deleted, "name": current.name]
        }
        if command == "credential.saveSites" {
            guard let id = bridgeActiveVaultID, states[id] != nil else { throw PBError.locked }
            return ["vaultID": id.uuidString, "pages": bridgeSavePages] as [String: Any]
        }
        guard let id = bridgeActiveVaultID, let store = stores[id], let page = request["url"] as? String, let origin = CredentialPolicy.origin(page) else { throw PBError.unauthorized }
        let session = spaceSession(id), authorization = bridgeToken
        let state = try await store.snapshot(); guard state.kind == .vault else { throw PBError.unauthorized }
        guard states[id] != nil, spaceSession(id) == session, authorization == bridgeToken else { throw PBError.locked }
        let matching = state.items.filter { CredentialPolicy.matches(item: $0, pageURL: page) }
        if command == "credential.list" {
            return matching.map { ["id": $0.id.uuidString.lowercased(), "title": $0.title, "username": $0.fields["username"] ?? ""] }
        }
        if command == "credential.capture" {
            guard let user = request["username"] as? String else { throw PBError.invalid("缺少账号") }
            let same = matching.filter { $0.fields["username"] == user }
            guard same.count <= 1 else { throw PBError.conflict }
            let revision = same.first.flatMap { state.current[$0.id]?.id.uuidString } ?? "new"
            return ["vaultID": id.uuidString, "session": session, "expected": revision,
                    "successURL": matching.count == same.count && !user.isEmpty ? (bridgeSavePages[origin] ?? "") : ""]
        }
        guard pendingCredential == nil else { throw PBError.invalid("请先处理 App 中已有的填充或保存请求。") }
        if command == "credential.redeemFill" {
            guard let permit = fillPermit, request["permit"] as? String == permit.key.uuidString else { throw PBError.unauthorized }
            fillPermit = nil
            guard permit.session == session, permit.url == page, permit.expires > Date(),
                  let item = matching.first(where: { $0.id == permit.item }),
                  state.current[item.id]?.id == permit.revision else { throw PBError.unauthorized }
            return ["username": item.fields["username"] ?? "", "password": item.fields["password"] ?? "", "origin": origin]
        }
        if command == "credential.fill" || command == "credential.prepareFill" {
            guard let itemID = request["itemID"] as? String, let uuid = UUID(uuidString: itemID), let candidate = matching.first(where: { $0.id == uuid }) else { throw PBError.unauthorized }
            let autoAllowed = request["auto"] as? Bool == true && bridgeActiveOrigins.contains(origin) && matching.count == 1
            let previous = NSWorkspace.shared.frontmostApplication
            let accepted = autoAllowed ? true : await withCheckedContinuation { continuation in
                pendingCredential = CredentialApproval(spaceID: id, title: "允许向此网站填充？", origin: origin, username: candidate.fields["username"] ?? "") { continuation.resume(returning: $0) }
                NSApp.activate(ignoringOtherApps: true)
            }
            guard accepted else { throw PBError.unauthorized }
            if !autoAllowed, let previous, previous.processIdentifier != ProcessInfo.processInfo.processIdentifier,
               NSApp.isActive {
                NSApp.yieldActivation(to: previous)
                _ = previous.activate(options: [])
            }
            let latest = try await store.snapshot()
            guard spaceSession(id) == session, authorization == bridgeToken, states[id] != nil, let item = latest.items.first(where: { $0.id == uuid }), CredentialPolicy.matches(item: item, pageURL: page) else { throw PBError.unauthorized }
            if command == "credential.prepareFill" {
                guard let current = latest.current[item.id], current.id == state.current[item.id]?.id else { throw PBError.conflict }
                let permit = FillPermit(item:item.id, revision:current.id, url:page, session:session)
                fillPermit = permit
                return ["permit":permit.key.uuidString, "origin":origin]
            }
            return ["username": item.fields["username"] ?? "", "password": item.fields["password"] ?? "", "origin": origin]
        }
        if command == "credential.save" || command == "credential.autoSave" {
            guard let username = request["username"] as? String, let password = request["password"] as? String,
                  let expected = request["expected"] as? String, request["vaultID"] as? String == id.uuidString,
                  request["session"] as? String == session, !password.isEmpty,
                  password.utf8.count <= 4096, username.utf8.count <= 4096 else { throw PBError.unauthorized }
            let automatic = command == "credential.autoSave"
            if automatic {
                guard !username.isEmpty, let success = bridgeSavePages[origin], success != page,
                      request["landedURL"] as? String == success else { throw PBError.unauthorized }
            } else {
                let accepted = await withCheckedContinuation { continuation in
                    pendingCredential = CredentialApproval(spaceID: id, title: "确认保存此网站的登录账号？", origin: origin, username: username) { continuation.resume(returning: $0) }
                    NSApp.activate(ignoringOtherApps: true)
                }
                guard accepted else { throw PBError.unauthorized }
            }
            guard authorization == bridgeToken, session == spaceSession(id), states[id] != nil else { throw PBError.locked }
            let changed = try await store.saveWebsiteLogin(origin: origin, username: username, password: password, expected: expected, automatic: automatic)
            if changed { try await refresh(id, userActivity: !automatic); requestSync(id) }
            return ["saved": true, "changed": changed]
        }
        throw PBError.unsupported
    }
}
#endif

struct CredentialApprovalView: View {
    @EnvironmentObject var model: AppModel
    let approval: CredentialApproval
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Label(approval.title, systemImage: "lock.shield").font(.title2.bold())
            Text(approval.origin).font(.title3.monospaced()).textSelection(.enabled)
            LabeledContent("账号", value: approval.username)
            Text("请核对网址和账号。填充只提供当前条目，不会提交登录。").foregroundStyle(.secondary)
            HStack { Button("拒绝") { complete(false) }; Spacer(); Button("允许") { complete(true) }.buttonStyle(.borderedProminent) }
        }.padding(28).frame(minWidth: 380, idealWidth: 520).interactiveDismissDisabled()
    }
    private func complete(_ accepted: Bool) { model.finishCredentialApproval(approval.id, accepted: accepted); model.touch() }
}
