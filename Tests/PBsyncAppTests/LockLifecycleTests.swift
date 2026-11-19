import XCTest
import AppKit
import PBsyncCore
@testable import PBsyncApp

@MainActor final class LockLifecycleTests: XCTestCase {
    private let password = "SYNTHETIC-LOCK-ONLY-2026"
    private func fixture() throws -> (AppModel, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pbsync-lock-tests-" + UUID().uuidString)
        return (AppModel(root: root, startBrowserBridge: false), root)
    }
    func testOptInKeepsOnlyPairedBookmarksDuringInactivity() async throws {
        let (model, root) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        await model.create(name: "后台书签", kind: .bookmarks, password: password)
        let id = try XCTUnwrap(model.selectedID)
        await model.create(name: "独立保险库", kind: .vault, password: password)
        let vault = try XCTUnwrap(model.selectedID)
        model.bridgeToken = "合成配对"; model.bridgeActiveBookmarkID = id; model.backgroundBookmarkID = id
        await model.checkIdle(at: Date().addingTimeInterval(301))
        XCTAssertNotNil(model.states[id]); XCTAssertNil(model.states[vault])
        await model.lockAll()
        XCTAssertNil(model.states[id])
        await model.lockForInactivity()
        XCTAssertNil(model.states[id])
    }
    func testLockAllInvalidatesPresentationAndCancelsApprovalOnce() async throws {
        let (model, root) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        await model.create(name: "合成库", kind: .vault, password: password)
        let id = try XCTUnwrap(model.selectedID), session = model.sensitivePresentationID
        var answers: [Bool] = []
        let approval = CredentialApproval(spaceID: id, title: "测试", origin: "https://example.com", username: "synthetic") { answers.append($0) }
        model.pendingCredential = approval
        await model.lockAll()
        XCTAssertNil(model.current); XCTAssertNil(model.recoverySecret); XCTAssertNil(model.pendingCredential)
        XCTAssertNotEqual(session, model.sensitivePresentationID)
        let unlocked = await model.stores[id]?.isUnlocked(); XCTAssertEqual(unlocked, false)
        model.finishCredentialApproval(approval.id, accepted: true)
        XCTAssertEqual(answers, [false], "被锁定取消的旧窗口不能重复完成请求")
    }
    func testMissingBiometricRecordKeepsMasterPasswordFallback() async throws {
        let (model, root) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        await model.create(name: "本机解锁验收", kind: .vault, password: password)
        await model.lockSelected()
        XCTAssertFalse(model.biometricConfigured)
        await model.unlock(password: password)
        XCTAssertFalse(model.busy)
        XCTAssertNil(model.biometricSpaceID)
        XCTAssertNil(model.error)
        XCTAssertNotNil(model.current, "正确的主密码仍应能打开本机副本")
    }
    func testLockOtherSpacePreservesSelectedVaultAndApproval() async throws {
        let (model, root) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        await model.create(name: "收藏夹", kind: .bookmarks, password: password)
        let bookmarks = try XCTUnwrap(model.selectedID)
        await model.create(name: "保险库", kind: .vault, password: password)
        let vault = try XCTUnwrap(model.selectedID), session = model.sensitivePresentationID
        var answers: [Bool] = []
        let approval = CredentialApproval(spaceID: vault, title: "测试", origin: "https://example.com", username: "synthetic") { answers.append($0) }
        model.pendingCredential = approval
        await model.lockSpace(bookmarks)
        XCTAssertNil(model.states[bookmarks]); XCTAssertNotNil(model.states[vault])
        XCTAssertEqual(session, model.sensitivePresentationID); XCTAssertEqual(model.pendingCredential?.id, approval.id)
        XCTAssertTrue(answers.isEmpty)
        model.finishCredentialApproval(approval.id, accepted: true)
        XCTAssertEqual(answers, [true])
    }
    func testLockVaultCancelsItsApprovalWhenBookmarksSelected() async throws {
        let (model, root) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        await model.create(name: "保险库", kind: .vault, password: password)
        let vault = try XCTUnwrap(model.selectedID)
        await model.create(name: "收藏夹", kind: .bookmarks, password: password)
        let session = model.sensitivePresentationID
        var answers: [Bool] = []
        model.pendingCredential = CredentialApproval(spaceID: vault, title: "测试", origin: "https://example.com", username: "synthetic") { answers.append($0) }
        await model.lockSpace(vault)
        XCTAssertNil(model.pendingCredential); XCTAssertEqual(answers, [false])
        XCTAssertEqual(session, model.sensitivePresentationID); XCTAssertNotNil(model.current)
    }
    func testStaleEditorCannotSaveAfterRelockAndUnlock() async throws {
        let (model, root) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        await model.create(name: "保险库", kind: .vault, password: password)
        let id = try XCTUnwrap(model.selectedID), session = model.sensitivePresentationID
        let item = Item(kind: .login, title: "过期编辑", fields: ["password": "synthetic"])
        await model.lockSelected(); await model.unlock(password: password)
        XCTAssertNotNil(model.current)
        await model.save(item, spaceID: id, presentationID: session)
        XCTAssertNotNil(model.error); XCTAssertTrue(model.current?.items.isEmpty == true)
        model.error = nil
        await model.save(item, spaceID: id, presentationID: model.sensitivePresentationID)
        XCTAssertNil(model.error); XCTAssertEqual(model.current?.items.count, 1)
    }
    func testIdleUsesSameLockInvalidationPath() async throws {
        let (model, root) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        await model.create(name: "保险库", kind: .vault, password: password)
        let session = model.sensitivePresentationID
        await model.checkIdle(at: Date())
        XCTAssertEqual(session, model.sensitivePresentationID); XCTAssertNotNil(model.current)
        await model.checkIdle(at: Date().addingTimeInterval(301))
        XCTAssertNotEqual(session, model.sensitivePresentationID); XCTAssertNil(model.current)
    }
    func testClipboardUsesWriterGenerationNotContent() async throws {
        let (model, root) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }
        model.pasteboard = board
        await model.create(name:"A",kind:.vault,password:password)
        let a = try XCTUnwrap(model.selectedID)
        await model.create(name:"B",kind:.vault,password:password)
        model.copy("合成内容"); await model.lockSpace(a)
        XCTAssertEqual(board.string(forType:.string),"合成内容")
        board.clearContents(); board.setString("合成内容",forType:.string)
        await model.lockAll(); XCTAssertEqual(board.string(forType:.string),"合成内容")
        model.copy("第二次复制"); await model.lockAll(); XCTAssertNil(board.string(forType:.string))
        board.setString("外部内容",forType:.string); await model.lockAll()
        XCTAssertEqual(board.string(forType:.string),"外部内容")
    }
    func testCommittedExportStaysAtDestinationButLockedSpaceCannotExport() async throws {
        let (model,root) = try fixture(); defer { try? FileManager.default.removeItem(at:root) }
        await model.create(name:"导出范围",kind:.vault,password:password)
        let marker = "SYNTHETIC-EXPORT-MARKER"
        await model.save(Item(kind:.login,title:"已提交",fields:["password":marker]))
        let (bytes,_) = try await model.export(kind:"csv")
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".csv")
        defer { try? FileManager.default.removeItem(at:destination) }
        try SafeFile.write(bytes,to:destination)
        await model.lockSelected()
        do { _ = try await model.export(kind:"csv"); XCTFail("锁定后不能重新导出") } catch {}
        XCTAssertTrue(try String(contentsOf:destination,encoding:.utf8).contains(marker))
        for file in try FileManager.default.contentsOfDirectory(at:root,includingPropertiesForKeys:nil) {
            XCTAssertNil(try Data(contentsOf:file).range(of:Data(marker.utf8)),file.lastPathComponent)
        }
    }
}
