#if os(macOS)
import XCTest
import PBsyncCore
@testable import PBsyncApp

@MainActor final class ExternalSourceTests: XCTestCase {
    func testMissingKDBXDoesNotPermanentlyDisableBackgroundRead() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = AppModel(root: root, startBrowserBridge: false)
        await model.create(name: "来源恢复测试", kind: .vault, password: "Synthetic-Source-Retry-Only")
        let target = try XCTUnwrap(model.selectedID)
        let link = ExternalLink(kind: "kdbx", originalPath: root.appendingPathComponent("missing.kdbx").path,
                                source: "keepass:retry-test", label: "合成来源")
        defer {
            try? Keychain.remove(account: model.linkKey(target))
            try? Keychain.remove(account: model.linkKey(target) + link.id.uuidString)
        }
        try model.storeLinks([link], target)
        await model.refreshLink(link, target: target, allowInteraction: false)
        XCTAssertTrue(try XCTUnwrap(model.links(target).first).enabled, "暂时缺少文件不能永久关闭连接")
        XCTAssertTrue(model.externalStatus[link.id]?.contains("自动重试") == true)
        XCTAssertTrue(model.current?.items.isEmpty == true)
        await model.lockAll()
        let before = model.externalStatus[link.id]
        await model.refreshLink(link, target: target, allowInteraction: false)
        XCTAssertEqual(model.externalStatus[link.id], before, "锁定后不能继续读取来源")
        XCTAssertFalse(model.externalBusy.contains(link.id))
    }
}
#endif
