import XCTest
import PBsyncCore
@testable import PBsyncApp

@MainActor final class PasswordSyncTests: XCTestCase {
    // 两个独立 App 配置经过真实密文目录同步；不代表 iPhone 或浏览器内置密码库。
    func testTwoClientsPropagateLoginCreationUpdateDeletionAndFillEligibility() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let shared = root.appendingPathComponent("shared")
        try SafeFile.privateDirectory(shared)
        defer { try? fm.removeItem(at: root) }
        let a = AppModel(root: root.appendingPathComponent("A"), startBrowserBridge: false)
        let b = AppModel(root: root.appendingPathComponent("B"), startBrowserBridge: false)
        let master = "Synthetic-Password-Sync-Only"
        await a.create(name: "独立密码同步验收", kind: .vault, password: master)
        let aid = try XCTUnwrap(a.selectedID)
        defer { try? Keychain.remove(account: a.settingsAccount(aid)) }
        await a.setFolder(shared)
        await a.saveSettings()
        try await wait { fm.fileExists(atPath: shared.appendingPathComponent("space.pbsync").path) }
        await b.setFolder(shared)
        await b.connectRemote(password: master)
        let bid = try XCTUnwrap(b.selectedID)
        defer { try? Keychain.remove(account: b.settingsAccount(bid)) }

        let origin = "https://password-sync.example.invalid"
        var first = Item(kind: .login, title: "Mac 新建", urls: [origin], fields: ["username": "qa-mac", "password": "Synthetic-First-Only"])
        await a.save(first)
        try await wait { b.pollSync(); return b.states[bid]?.items.contains(first) == true }

        var second = Item(kind: .login, title: "对端新建", urls: [origin], fields: ["username": "qa-peer", "password": "Synthetic-Peer-Only"])
        await b.save(second)
        try await wait { a.pollSync(); return a.states[aid]?.items.contains(second) == true }

        // 对端修改账号和密码，原条目身份不变，同网站的另一个账号保持原值。
        first.fields["username"] = "qa-mac-updated"
        first.fields["password"] = "Synthetic-Updated-Only"
        await b.save(first)
        try await wait { a.pollSync(); return a.states[aid]?.items.contains(first) == true }
        XCTAssertTrue(a.states[aid]?.items.contains(second) == true)
        second.fields["password"] = "Synthetic-Peer-Updated-Only"
        await a.save(second)
        try await wait { b.pollSync(); return b.states[bid]?.items.contains(second) == true }

        // 同站多账号应由用户选择；先验证反向删除，再测试单账号自动填充。
        await a.delete(second)
        try await wait { b.pollSync(); return b.states[bid]?.current[second.id]?.deleted == true }

        // 使用真实桥接命令核对更新后的填充内容；不绕过匹配规则。
        let token = try Crypto.random(32)
        a.bridgeToken = token.base64EncodedString()
        a.bridgeActiveVaultID = aid
        a.bridgeActiveOrigins = [origin]
        func request(_ fields: [String: Any]) async throws -> [String: Any] {
            let wire = try BridgeWire.make(payload: JSONSerialization.data(withJSONObject: fields), token: token)
            let response = try await a.handleBridge(Coding.encode(wire))
            let plain = try Coding.decode(BridgeWire.self, from: response).open(token: token, response: true)
            return try XCTUnwrap(JSONSerialization.jsonObject(with: plain) as? [String: Any])
        }
        func permit(_ item: Item) async throws -> String {
            let response = try await request(["command": "credential.prepareFill", "url": origin, "itemID": item.id.uuidString, "auto": true])
            let payload = try XCTUnwrap(response["payload"] as? [String: String])
            return try XCTUnwrap(payload["permit"])
        }
        let currentPermit = try await permit(first)
        let filled = try await request(["command": "credential.redeemFill", "url": origin, "permit": currentPermit])
        let values = try XCTUnwrap(filled["payload"] as? [String: String])
        XCTAssertEqual(values["username"], first.fields["username"])
        XCTAssertEqual(values["password"], first.fields["password"])

        let beforeDelete = try await permit(first)
        await b.delete(first)
        try await wait { a.pollSync(); return a.states[aid]?.current[first.id]?.deleted == true }
        let staleFill = try await request(["command": "credential.redeemFill", "url": origin, "permit": beforeDelete])
        XCTAssertEqual(staleFill["ok"] as? Bool, false)
        XCTAssertEqual(a.states[aid]?.items.count, 0)

        await b.lockAll()
        await b.unlock(password: master)
        b.resumeSync()
        try await wait { b.states[bid]?.items.isEmpty == true }
        let listed = try await request(["command": "credential.list", "url": origin])
        XCTAssertEqual((listed["payload"] as? [[String: String]])?.count, 0)
        let ciphertext = try Data(contentsOf: shared.appendingPathComponent("space.pbsync"))
        for secret in [master, "Synthetic-First-Only", "Synthetic-Updated-Only", "Synthetic-Peer-Updated-Only"] {
            XCTAssertNil(ciphertext.range(of: Data(secret.utf8)))
        }
        await a.lockAll()
        await b.lockAll()
    }

    private func wait(_ condition: () async throws -> Bool) async throws {
        for _ in 0..<200 {
            if try await condition() { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        throw PBError.unavailable
    }
}
