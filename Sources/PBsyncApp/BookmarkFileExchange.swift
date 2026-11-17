#if os(macOS)
import Foundation
import PBsyncCore

struct BookmarkFileSelection {
    let space: UUID
    let session: String
    let synchronize: Bool
}

struct BookmarkExportSelection {
    let space: UUID
    let session: String
    let data: Data
    let name: String
    let message: String
}

struct BookmarkExchangePreferences: Codable {
    var input: Data?
    var outputs: [String: Data] = [:]
    var importedDigest: String?
    var automatic: Bool?
}

@MainActor extension AppModel {
    func exchangeFiles(_ id: UUID) -> BookmarkExchangeFiles {
        BookmarkExchangeFiles(base: bookmarkExchangeBase, spaceID: id)
    }
    private func exchangeSettingsURL(_ id: UUID) -> URL {
        root.appendingPathComponent("bookmark-exchange-" + id.uuidString.lowercased() + ".json")
    }
    func exchangePreferences(_ id: UUID) throws -> BookmarkExchangePreferences {
        let url = exchangeSettingsURL(id)
        if !FileManager.default.fileExists(atPath: url.path) { return BookmarkExchangePreferences() }
        return try Coding.decode(BookmarkExchangePreferences.self, from: Data(contentsOf: url))
    }
    func saveExchangePreferences(_ value: BookmarkExchangePreferences, _ id: UUID) throws {
        try SafeFile.write(Coding.encode(value), to: exchangeSettingsURL(id))
    }
    private func validExchange(_ id: UUID, _ session: String) -> Bool {
        selectedID == id && states[id]?.kind == .bookmarks && spaceSession(id) == session
    }
    private func exchangeInput(_ id: UUID, _ prefs: BookmarkExchangePreferences) throws -> URL {
        if let bookmark = prefs.input { return try SourceTool.file(bookmark) }
        return try exchangeFiles(id).input()
    }

    func setAutomaticBookmarkFiles(_ enabled: Bool, for id: UUID) {
        guard states[id]?.kind == .bookmarks else { return }
        do {
            var preferences = try exchangePreferences(id)
            if enabled { try SafeFile.privateDirectory(exchangeFiles(id).inputDirectory) }
            preferences.automatic = enabled
            try saveExchangePreferences(preferences, id)
            if enabled {
                automaticBookmarkFiles.insert(id)
                bookmarkFileStatus[id] = "等待检查固定目录"
                pollBookmarkFiles()
            } else {
                automaticBookmarkFiles.remove(id)
                bookmarkFileStatus[id] = nil
            }
        } catch { report(error) }
    }

    func pollBookmarkFiles() {
        for id in automaticBookmarkFiles where states[id]?.kind == .bookmarks && !bookmarkFileWork.contains(id) {
            Task { await exchangeBookmarkFilesInBackground(id) }
        }
    }

    func exchangeBookmarkFilesInBackground(_ id: UUID) async {
        guard let store = stores[id], states[id]?.kind == .bookmarks,
              automaticBookmarkFiles.contains(id), bookmarkFileWork.insert(id).inserted else { return }
        defer { bookmarkFileWork.remove(id) }
        let session = spaceSession(id)
        func isActive() -> Bool {
            states[id]?.kind == .bookmarks && spaceSession(id) == session && automaticBookmarkFiles.contains(id)
        }
        do {
            var preferences = try exchangePreferences(id)
            let name = "Safari-收藏夹.zip"
            let output = try preferences.outputs[name].map { try SourceTool.file($0) } ?? exchangeFiles(id).output(name)
            let input = try exchangeInput(id, preferences)
            guard input.resolvingSymlinksInPath() != output.resolvingSymlinksInPath() else {
                throw PBError.invalid("待导入文件和交换输出不能指向同一位置。")
            }
            let digest = preferences.importedDigest
            let (preview, nextDigest) = try await Task.detached {
                try BookmarkExchangeFiles.readIfChanged(input, since: digest)
            }.value
            guard isActive() else { return }
            if let preview {
                let count = try await store.mergeBookmarkFile(preview)
                guard isActive() else { return }
                preferences = try exchangePreferences(id)
                preferences.importedDigest = nextDigest
                try saveExchangePreferences(preferences, id)
                try await refresh(id, userActivity: false)
                if count > 0 { requestSync(id) }
            }
            let snapshot = try await store.snapshot()
            let atEncoding = states[id]
            let data = try await Task.detached { try SafariBookmarks.export(snapshot) }.value
            guard isActive(), states[id] == atEncoding else { return }
            try BookmarkExchangeFiles.write(data, to: output)
            bookmarkFileStatus[id] = "交换文件已更新 · 待 Safari 导入"
        } catch {
            guard isActive() else { return }
            bookmarkFileStatus[id] = (error as? PBError)?.localizedDescription ?? "交换文件处理失败，请检查路径与权限。"
        }
    }

    /// 先读固定位置；只有缺失、权限或解析失败才请求文件选择器。
    func beginBookmarkImport() async {
        guard let id = selectedID, current?.kind == .bookmarks else { report(PBError.locked); return }
        let session = spaceSession(id)
        do {
            let prefs = try exchangePreferences(id), url = try exchangeInput(id, prefs)
            let (incoming, _) = try BookmarkExchangeFiles.read(url)
            guard validExchange(id, session) else { return }
            preview = incoming
            importTarget = id
            status[id] = "已读取固定文件：\(url.path)"
        } catch {
            guard validExchange(id, session) else { return }
            status[id] = "固定文件不可用（\(error.localizedDescription)），请选择来源文件。"
            bookmarkFileSelection = BookmarkFileSelection(space: id, session: session, synchronize: false)
        }
    }

    func receiveBookmarkFile(_ url: URL, selection: BookmarkFileSelection) async {
        guard validExchange(selection.space, selection.session) else { return }
        if selection.synchronize { await synchronizeBookmarkFile(selectedInput: url); return }
        do {
            let (incoming, _) = try BookmarkExchangeFiles.read(url)
            guard validExchange(selection.space, selection.session) else { return }
            var prefs = try exchangePreferences(selection.space)
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            prefs.input = try StorageConfiguration.bookmark(for: url)
            try saveExchangePreferences(prefs, selection.space)
            preview = incoming
            importTarget = selection.space
            status[selection.space] = "已记住来源文件，下次优先直接读取。"
        } catch { report(error) }
    }

    func synchronizeBookmarkFile(selectedInput: URL? = nil) async {
        guard let id = selectedID, current?.kind == .bookmarks, !busy,
              bookmarkFileWork.insert(id).inserted else { return }
        defer { bookmarkFileWork.remove(id) }
        let session = spaceSession(id)
        busy = true; defer { busy = false }
        var prefs: BookmarkExchangePreferences
        let incoming: ImportPreview, digest: String
        do {
            prefs = try exchangePreferences(id)
            let url = try selectedInput ?? exchangeInput(id, prefs)
            (incoming, digest) = try BookmarkExchangeFiles.read(url)
            if selectedInput != nil {
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                prefs.input = try StorageConfiguration.bookmark(for: url)
            }
        } catch {
            guard validExchange(id, session) else { return }
            status[id] = "固定文件读取失败（\(error.localizedDescription)），请选择来源文件。"
            bookmarkFileSelection = BookmarkFileSelection(space: id, session: session, synchronize: true)
            return
        }
        do {
            guard validExchange(id, session), let store = stores[id] else { throw PBError.locked }
            // 原文件没有改变时，不复活随后在浏览器中删除的条目。
            let count = prefs.importedDigest == digest ? 0 : try await store.mergeBookmarkFile(incoming)
            guard validExchange(id, session) else { return }
            prefs.importedDigest = digest
            try saveExchangePreferences(prefs, id)
            try await refresh(id, userActivity: false)
            var remote = ""
            if try configuredStorage() != nil {
                await runSync(id, manual: true)
                remote = "；" + (status[id] ?? "请查看主要同步位置的状态")
            }
            guard validExchange(id, session) else { return }
            let (data, name) = try await export(kind: "safari-zip")
            let warning = incoming.warnings.isEmpty ? "" : "；\(incoming.warnings.joined(separator: "；"))"
            await saveBookmarkExport(data: data, name: name,
                message: "文件合并新增 \(count) 项，交换文件已写出；Safari 尚需导入\(remote)\(warning)")
        } catch {
            guard validExchange(id, session) else { return }
            // 合并或输出阶段失败不能改成成功，也不能重新应用未核对的输入。
            report(error)
        }
    }

    func saveBookmarkExport(data: Data, name: String, message: String = "书签文件已导出，Safari 尚需导入") async {
        guard let id = selectedID, current?.kind == .bookmarks else { return }
        let session = spaceSession(id)
        do {
            let prefs = try exchangePreferences(id)
            let url = try prefs.outputs[name].map { try SourceTool.file($0) } ?? exchangeFiles(id).output(name)
            try BookmarkExchangeFiles.write(data, to: url)
            guard validExchange(id, session) else { return }
            status[id] = message + "：" + url.path
        } catch {
            guard validExchange(id, session) else { return }
            status[id] = "固定位置写出失败（\(error.localizedDescription)），请选择保存位置。"
            bookmarkExportSelection = BookmarkExportSelection(space: id, session: session, data: data, name: name, message: message)
        }
    }

    func bookmarkExportCompleted(_ result: Result<URL, Error>, selection: BookmarkExportSelection) {
        guard validExchange(selection.space, selection.session) else { return }
        do {
            let url = try result.get(), access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            guard try Data(contentsOf: url) == selection.data else { throw PBError.damaged }
            var prefs = try exchangePreferences(selection.space)
            prefs.outputs[selection.name] = try StorageConfiguration.bookmark(for: url)
            try saveExchangePreferences(prefs, selection.space)
            status[selection.space] = selection.message + "：" + url.path
        } catch {
            if (error as NSError).code != NSUserCancelledError { report(error) }
            else { status[selection.space] = "已取消写出；本机合并内容仍保留，尚未导入 Safari。" }
        }
    }
}
#endif
