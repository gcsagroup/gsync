import XCTest
import PBsyncCore
@testable import PBsyncApp

@MainActor final class AutomaticSyncTests: XCTestCase {
    func testOfflineChangesSurviveRestartAndForegroundPull() async throws {
        let fm = FileManager.default, root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: root) }
        let primary = root.appendingPathComponent("A"), folder = root.appendingPathComponent("shared")
        try SafeFile.privateDirectory(folder)
        let password = "Synthetic-Offline-Password"
        let model = AppModel(root: primary, startBrowserBridge: false)
        await model.create(name: "验收", kind: .bookmarks, password: password)
        let id = try XCTUnwrap(model.selectedID)
        defer { try? Keychain.remove(account: model.settingsAccount(id)) }
        await model.setFolder(folder)
        await model.saveSettings()
        try await until { fm.fileExists(atPath: folder.appendingPathComponent("space.pbsync").path) }
        let peer = try await VaultStore.connect(storage: FolderStorage(directory: folder), fileURL: root.appendingPathComponent("B.pbsync"), password: password, deviceID: UUID())
        let offline = Item(kind:.bookmark,title:"停机前",urls:["https://example.test/a"])
        await model.save(offline)
        await model.lockAll() // 阻止本次防抖任务执行，模拟退出后的待传。
        let restarted = AppModel(root:primary,startBrowserBridge:false)
        await restarted.unlock(password:password)
        try await until {
            _ = try await peer.synchronize(with:FolderStorage(directory:folder))
            return try await peer.snapshot().items.contains(offline)
        }
        let reverse = Item(kind:.bookmark,title:"另一端",urls:["https://example.test/b"])
        _ = try await peer.save(reverse)
        _ = try await peer.synchronize(with:FolderStorage(directory:folder))
        restarted.resumeSync()
        try await until { restarted.states[id]?.items.contains(reverse) == true }
        await restarted.lockAll()
    }

    func testQueuedRetryAfterRealWebDAVOutage() async throws {
        let fm = FileManager.default, root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try SafeFile.privateDirectory(root)
        defer { try? fm.removeItem(at: root) }
        let offline = root.appendingPathComponent("offline")
        try Data().write(to: offline)
        let service = Process()
        service.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        let tests = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        service.arguments = [tests.appendingPathComponent("f04_webdav_fixture.py").path, root.path]
        try service.run()
        defer { service.terminate(); service.waitUntilExit() }
        let portFile = root.appendingPathComponent("port")
        try await until { fm.fileExists(atPath: portFile.path) }
        let port = try String(contentsOf: portFile, encoding: .utf8)
        let model = AppModel(root:root.appendingPathComponent("A"),startBrowserBridge:false)
        await model.create(name:"网络恢复",kind:.vault,password:"Synthetic-DAV-Password")
        let id = try XCTUnwrap(model.selectedID)
        defer { try? Keychain.remove(account:model.settingsAccount(id)) }
        model.settings = StorageConfiguration(kind:.webdav, endpoint:"http://127.0.0.1:\(port)/dav/test/", username:"qa",secret:"synthetic-dav-secret")
        await model.saveSettings()
        let item = Item(kind:.note,title:"离线修改")
        await model.save(item)
        try await until { model.status[id]?.contains("重试") == true }
        try fm.removeItem(at:offline)
        try await until { model.status[id]?.contains("已同步到存储") == true }
        let peer = try await VaultStore.connect(storage:model.settings.storage(),fileURL:root.appendingPathComponent("B.pbsync"),password:"Synthetic-DAV-Password",deviceID:UUID())
        let copied = try await peer.snapshot()
        XCTAssertEqual(copied.items,[item])
        await model.lockAll()
    }

    func testAutomaticLoginRevisionGuard() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let (store,_) = try VaultStore.create(fileURL:root.appendingPathComponent("login"),name:"合成",kind:.vault,password:"Synthetic-Auto-Password",deviceID:UUID())
        try await store.unlock(password:"Synthetic-Auto-Password")
        let origin="https://example.test"
        _ = try await store.saveWebsiteLogin(origin:origin,username:"a",password:"one",expected:"new",automatic:true)
        let first = try await store.snapshot().revisions.last!.id.uuidString
        _ = try await store.saveWebsiteLogin(origin:origin,username:"a",password:"two",expected:first,automatic:true)
        for (user,version) in [("a",first),("b","new")] {
            do {
                _ = try await store.saveWebsiteLogin(origin:origin,username:user,password:"wrong",expected:version,automatic:true)
                XCTFail("不应写入")
            } catch PBError.conflict {}
        }
        let final = try await store.snapshot()
        XCTAssertEqual(final.items.count,1)
        XCTAssertEqual(final.items.first?.fields["password"],"two")
    }

    func testFillPermitIsSingleUseAndInvalidAfterRelock() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = AppModel(root:root,startBrowserBridge:false), password = "Synthetic-Permit-Password"
        await model.create(name:"合成库",kind:.vault,password:password)
        let id = try XCTUnwrap(model.selectedID), origin = "https://fixture.example"
        let login = Item(kind:.login,title:"验收",urls:[origin],fields:["username":"user","password":"synthetic"])
        await model.save(login)
        let key = try Crypto.random(32)
        model.bridgeToken = key.base64EncodedString()
        model.bridgeActiveVaultID = id
        model.bridgeActiveOrigins = [origin]
        func request(_ fields: [String: Any]) async throws -> [String: Any] {
            let packet = try BridgeWire.make(payload:JSONSerialization.data(withJSONObject:fields),token:key)
            let response = try await model.handleBridge(Coding.encode(packet))
            let decoded = try Coding.decode(BridgeWire.self,from:response).open(token:key,response:true)
            return try XCTUnwrap(JSONSerialization.jsonObject(with:decoded) as? [String:Any])
        }
        func prepare() async throws -> String {
            let result = try await request(["command":"credential.prepareFill","url":origin,"itemID":login.id.uuidString,"auto":true])
            let payload = try XCTUnwrap(result["payload"] as? [String:String])
            XCTAssertNil(payload["password"])
            return try XCTUnwrap(payload["permit"])
        }
        let permit = try await prepare()
        let redemption = ["command":"credential.redeemFill","url":origin,"permit":permit]
        let first = try await request(redemption), replay = try await request(redemption)
        XCTAssertEqual(first["ok"] as? Bool,true)
        XCTAssertEqual(replay["ok"] as? Bool,false)
        let expired = try await prepare()
        await model.lockAll(); await model.unlock(password:password)
        let stale = try await request(["command":"credential.redeemFill","url":origin,"permit":expired])
        XCTAssertEqual(stale["ok"] as? Bool,false)
        await model.lockAll()
    }

    private func until(_ condition: () async throws -> Bool) async throws {
        for _ in 0..<100 {
            if try await condition() { return }
            try await Task.sleep(nanoseconds:50_000_000)
        }
        throw PBError.unavailable
    }
}
