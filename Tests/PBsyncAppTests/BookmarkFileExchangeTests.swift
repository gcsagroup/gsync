#if os(macOS)
import XCTest
import PBsyncCore
@testable import PBsyncApp

@MainActor final class BookmarkFileExchangeTests: XCTestCase {
    private let html = Data("""
    <!DOCTYPE NETSCAPE-Bookmark-file-1>
    <DL><p><DT><H3>独立验收</H3><DL><p>
    <DT><A HREF="https://example.invalid/a?x=1&amp;y=2">中文 &amp; 标题</A>
    <DT><A HREF="https://example.invalid/a?x=1&amp;y=2">中文 &amp; 标题</A>
    <DT><H3>空目录</H3><DL><p></DL><p></DL><p></DL>
    """.utf8)

    private func model(_ root: URL) async throws -> (AppModel, UUID) {
        let model = AppModel(root: root.appendingPathComponent("profile"), startBrowserBridge: false)
        model.bookmarkExchangeBase = root.appendingPathComponent("exchange")
        await model.create(name: "独立验收", kind: .bookmarks, password: "Synthetic-File-Exchange-Password")
        return (model, try XCTUnwrap(model.selectedID))
    }
    private func temporary() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString) }

    func testBackgroundExchangePreservesDeletionAndNeverOpensFilePicker() async throws {
        let root = temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let (model, id) = try await model(root)
        let files = model.exchangeFiles(id)
        let input = files.inputDirectory.appendingPathComponent("Bookmarks.html")
        let output = files.output("Safari-收藏夹.zip")
        try SafeFile.write(html, to: input)
        await model.exchangeBookmarkFilesInBackground(id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path), "默认不开启文件交换")
        model.setAutomaticBookmarkFiles(true, for: id)
        await model.exchangeBookmarkFilesInBackground(id)
        XCTAssertEqual(model.current?.items.count, 4)
        XCTAssertTrue(try XCTUnwrap(model.bookmarkFileStatus[id]).contains("待 Safari 导入"))
        let original = try Data(contentsOf: output)
        await model.exchangeBookmarkFilesInBackground(id)
        XCTAssertEqual(try Data(contentsOf: output), original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: files.outputDirectory.appendingPathComponent("历史").path))

        await model.delete(try XCTUnwrap(model.current?.items.first { $0.kind == .bookmark }))
        await model.exchangeBookmarkFilesInBackground(id)
        let updated = try Data(contentsOf: output)
        XCTAssertEqual(try SafariBookmarks.preview(updated).items.count, 3)
        XCTAssertEqual(model.current?.items.count, 3, "旧文件不能复活后来删除的书签")

        try SafeFile.write(Data("损坏文件".utf8), to: input)
        await model.exchangeBookmarkFilesInBackground(id)
        XCTAssertNil(model.bookmarkFileSelection)
        XCTAssertNil(model.bookmarkExportSelection)
        XCTAssertNil(model.error)
        XCTAssertFalse(try XCTUnwrap(model.bookmarkFileStatus[id]).contains("待 Safari 导入"))
        XCTAssertEqual(try Data(contentsOf: output), updated)
        await model.lockAll()
        try SafeFile.write(html, to: input)
        await model.exchangeBookmarkFilesInBackground(id)
        XCTAssertNil(model.current)
        XCTAssertEqual(try Data(contentsOf: output), updated)

        let reopened = AppModel(root: model.root, startBrowserBridge: false)
        XCTAssertTrue(reopened.automaticBookmarkFiles.contains(id))
    }

    func testMoveAndReorderBookmarksPreserveSiblingsAndRejectCycle() async throws {
        let root = temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let (model, id) = try await model(root)
        let folder = Item(kind: .folder, title: "目录")
        let child = Item(kind: .folder, title: "下级", parentID: folder.id)
        let first = Item(kind: .bookmark, title: "甲", parentID: folder.id, order: 1, urls: ["https://example.invalid/a"])
        let second = Item(kind: .bookmark, title: "乙", parentID: folder.id, order: 2, urls: ["https://example.invalid/b"])
        let store = try XCTUnwrap(model.stores[id])
        _ = try await store.importItems([folder, child, first, second])

        try await store.placeBookmark(second.id, in: folder.id, before: first.id)
        var state = try await store.snapshot()
        XCTAssertEqual(state.items.filter { $0.parentID == folder.id }.map(\.id), [child.id, second.id, first.id])
        try await store.placeBookmark(second.id, in: child.id)
        state = try await store.snapshot()
        XCTAssertEqual(state.items.filter { $0.parentID == folder.id }.map(\.id), [child.id, first.id])
        XCTAssertEqual(state.current[second.id]?.item.parentID, child.id)
        XCTAssertEqual(state.current[second.id]?.item.order, 0)
        do {
            try await store.placeBookmark(folder.id, in: child.id)
            XCTFail("目录不能移入自身的下级")
        } catch {}
        let after = try await store.snapshot()
        XCTAssertEqual(after.items, state.items)
        await model.lockAll()
    }

    func testFixedFileSyncAndRoundtripPreserveDuplicatesEmptyFoldersAndDeletion() async throws {
        let root = temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let (model, id) = try await model(root)
        let input = model.exchangeFiles(id).inputDirectory.appendingPathComponent("Safari-收藏夹.html")
        try SafeFile.write(html, to: input)
        await model.sync()
        XCTAssertNil(model.error); XCTAssertNil(model.bookmarkFileSelection); XCTAssertNil(model.bookmarkExportSelection)
        let original = try XCTUnwrap(model.current).items
        XCTAssertEqual(original.count, 4)
        XCTAssertEqual(original.filter { $0.kind == .bookmark }.count, 2)
        let output = model.exchangeFiles(id).output("Safari-收藏夹.zip")
        let decoded = try SafariBookmarks.preview(Data(contentsOf: output))
        XCTAssertEqual(decoded.items.count, 4)
        XCTAssertEqual(decoded.items.filter { $0.kind == .bookmark }.map(\.urls), [["https://example.invalid/a?x=1&y=2"], ["https://example.invalid/a?x=1&y=2"]])
        await model.sync()
        XCTAssertEqual(model.current?.items, original, "重复同步不得复制整棵树")
        // 把实际导出的 ZIP 作为更新的输入，身份不同也应逐项匹配，保留重复次数。
        try SafeFile.write(Data(contentsOf: output), to: input)
        await model.sync()
        XCTAssertEqual(model.current?.items, original)
        let removed = try XCTUnwrap(model.current?.items.first { $0.kind == .bookmark })
        await model.delete(removed)
        await model.sync()
        XCTAssertEqual(model.current?.items.count, 3, "未改变的旧文件不能复活浏览器已删书签")
        await model.lockAll()
    }

    func testMissingFileRequestsSelectionAndRemembersSuccessfulChoice() async throws {
        let root = temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let (model, id) = try await model(root)
        await model.sync()
        let selection = try XCTUnwrap(model.bookmarkFileSelection)
        XCTAssertTrue(selection.synchronize); XCTAssertEqual(model.current?.items.count, 0)
        model.bookmarkFileSelection = nil
        let selected = root.appendingPathComponent("自行选择.html")
        try SafeFile.write(html, to: selected)
        await model.receiveBookmarkFile(selected, selection: selection)
        XCTAssertNil(model.error); XCTAssertEqual(model.current?.items.count, 4)
        XCTAssertNotNil(try model.exchangePreferences(id).input)
        await model.sync()
        XCTAssertNil(model.bookmarkFileSelection); XCTAssertEqual(model.current?.items.count, 4)
        await model.lockAll()
    }

    func testCorruptInputFallsBackWithoutChangingBookmarksOrExport() async throws {
        let root = temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let (model, id) = try await model(root)
        let input = model.exchangeFiles(id).inputDirectory.appendingPathComponent("Safari-收藏夹.html")
        try SafeFile.write(html, to: input); await model.sync()
        let original = model.current?.items
        let output = model.exchangeFiles(id).output("Safari-收藏夹.zip"), before = try Data(contentsOf: output)
        try SafeFile.write(Data("不是书签文件".utf8), to: input); await model.sync()
        XCTAssertNotNil(model.bookmarkFileSelection)
        XCTAssertEqual(model.current?.items, original)
        XCTAssertEqual(try Data(contentsOf: output), before)
        await model.lockAll()
    }

    func testExportFailureRequestsDestinationAndReusesIt() async throws {
        let root = temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let (model, id) = try await model(root)
        try SafeFile.write(html, to: model.exchangeFiles(id).inputDirectory.appendingPathComponent("Safari-收藏夹.html"))
        try SafeFile.privateDirectory(model.exchangeFiles(id).output("Safari-收藏夹.zip"))
        await model.sync()
        let selection = try XCTUnwrap(model.bookmarkExportSelection)
        XCTAssertEqual(model.current?.items.count, 4)
        let chosen = root.appendingPathComponent("可写位置.zip")
        try BookmarkExchangeFiles.write(selection.data, to: chosen)
        model.bookmarkExportSelection = nil
        model.bookmarkExportCompleted(.success(chosen), selection: selection)
        XCTAssertNil(model.error)
        await model.sync()
        XCTAssertNil(model.bookmarkExportSelection)
        XCTAssertEqual(try SafariBookmarks.preview(Data(contentsOf: chosen)).items.count, 4)
        await model.lockAll()
    }

    func testOldSelectionCannotWriteAfterLock() async throws {
        let root = temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let (model, _) = try await model(root)
        await model.sync()
        let selection = try XCTUnwrap(model.bookmarkFileSelection)
        await model.lockAll()
        let chosen = root.appendingPathComponent("迟到的选择.html")
        try SafeFile.write(html, to: chosen)
        await model.receiveBookmarkFile(chosen, selection: selection)
        XCTAssertNil(model.current)
        XCTAssertFalse(FileManager.default.fileExists(atPath: model.bookmarkExchangeBase.path))
    }

    func testOverwriteRetainsPriorOutputAndRejectsSymlink() throws {
        let root = temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let output = root.appendingPathComponent("固定.html")
        try BookmarkExchangeFiles.write(html, to: output)
        let updated = html + Data("\n<!-- 新版 -->".utf8)
        try BookmarkExchangeFiles.write(updated, to: output)
        let backups = try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("历史"), includingPropertiesForKeys: nil)
        XCTAssertEqual(backups.count, 1)
        XCTAssertEqual(try Data(contentsOf: backups[0]), html)
        let link = root.appendingPathComponent("链接.html")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: output)
        XCTAssertThrowsError(try BookmarkExchangeFiles.write(html, to: link))
        XCTAssertEqual(try Data(contentsOf: output), updated)
    }
}
#endif
