import Foundation
import LocalAuthentication
import SwiftUI
import PBsyncCore
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#else
import UIKit
#endif

struct ExportDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.data] }
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}

@MainActor final class AppModel: ObservableObject {
    @Published var entries: [CatalogEntry] = []
    @Published var states: [UUID: SpaceState] = [:]
    @Published var selectedID: UUID?
    @Published var section: String = "收藏夹"
    @Published var error: String?
    @Published var status: [UUID: String] = [:]
    @Published var busy = false
    @Published var recoverySecret: String?
    @Published var preview: ImportPreview?
    @Published var importTarget: UUID?
    @Published var settings = StorageConfiguration()
    @Published var root: URL
    @Published var search = ""
    @Published var showDeleted = false
    @Published var selectedFolder: UUID?
    @Published var autoSavePages = ""
    @Published var autoFillOrigins = ""
    var stores: [UUID: VaultStore] = [:]
    @Published var bridgeToken = ""
    @Published var bridgeBookmarkID: UUID?
    @Published var bridgeVaultID: UUID?
    @Published var pendingCredential: CredentialApproval?
    #if os(macOS)
    @Published var bookmarkFileSelection: BookmarkFileSelection?
    @Published var bookmarkExportSelection: BookmarkExportSelection?
    var bookmarkExchangeBase = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("PBsync-书签交换", isDirectory: true)
    @Published var automaticBookmarkFiles: Set<UUID> = []
    @Published var bookmarkFileStatus: [UUID: String] = [:]
    @Published var lastBookmarkBridgeExchange: [UUID: Date] = [:]
    var bookmarkFileWork: Set<UUID> = []
    @Published var externalStatus: [UUID: String] = [:]
    @Published var fileVaultSelection: FileVaultSelection?
    @Published var externalEpoch = 0
    @Published var externalBusy = Set<UUID>()
    var bridgeServer: NativeBridgeServer?
    var bridgeSeen: [UUID: Int64] = [:]
    var fillPermit: FillPermit?
    @Published var backgroundBookmarks = false
    @Published var bridgeAuthorizationNeedsUnlock = false
    @Published var restoringBridgeAuthorization = false
    var bridgeAuthorizationEpoch = UUID()
    var backgroundBookmarkID: UUID?
    var bridgeActiveBookmarkID: UUID?
    var bridgeActiveVaultID: UUID?
    var bridgeSavePages: [String: String] = [:]
    var bridgeActiveOrigins: Set<String> = []
    #endif
    // 锁定先使界面会话失效，再等待存储清钥，避免异步回读重新显示旧内容。
    @Published private(set) var sensitivePresentationID = UUID()
    private var lockGeneration: [UUID: Int] = [:]
    private var lockingSpaces: Set<UUID> = []
    @Published private(set) var biometricSpaceID: UUID?
    private var biometricContext: LAContext?
    private var deviceID = UUID()
    private var clipboardToken = UUID()
    private var copiedChange: Int?
    private var copiedSpace: UUID?
    #if os(macOS)
    var pasteboard = NSPasteboard.general
    #else
    private var pasteboard: UIPasteboard { .general }
    #endif
    var syncTimers: [UUID: Task<Void, Never>] = [:]
    var syncInFlight = Set<UUID>()
    var syncAgain = Set<UUID>()
    var syncSuspended = Set<UUID>()
    var retryDelay: [UUID: UInt64] = [:]
    let processSession = UUID()
    private var lastActivity = Date()
    var selected: CatalogEntry? { entries.first { $0.id == selectedID } }
    var current: SpaceState? { selectedID.flatMap { states[$0] } }
    func spaceDisplayName(_ entry: CatalogEntry) -> String {
        if let name = states[entry.id]?.name { return name }
        let label = entry.kind == .bookmarks ? "收藏夹" : "密码库"
        let siblings = entries.filter { $0.kind == entry.kind }
        if siblings.count > 1, let index = siblings.firstIndex(where: { $0.id == entry.id }) {
            return "\(label) \(index + 1)（已锁定）"
        }
        return "\(label)（已锁定）"
    }
    var visibleItems: [Item] {
        guard let current else { return [] }
        let live = current.current
        let candidates = showDeleted ? current.current.values.filter(\.deleted).map(\.item) : current.items
        return candidates.filter { item in
            let textMatch = search.isEmpty || item.title.localizedCaseInsensitiveContains(search) || item.urls.contains { $0.localizedCaseInsensitiveContains(search) } || (item.fields["username"] ?? "").localizedCaseInsensitiveContains(search)
            let folderMatch = !search.isEmpty || showDeleted || current.kind != .bookmarks || current.effectiveParent(of: item, live:live) == selectedFolder
            return textMatch && folderMatch
        }.sorted {
            if $0.order != $1.order { return $0.order < $1.order }
            if current.kind == .bookmarks { return $0.id.uuidString < $1.id.uuidString }
            return $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }
    }
    init(root profile: URL? = nil, startBrowserBridge: Bool = true) {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("PBsync-unavailable")
        do {
            root = try profile ?? AppPaths.root(); deviceID = try AppPaths.deviceID(at: root)
            entries = try Catalog.read(at: root)
            for entry in entries { stores[entry.id] = try VaultStore(fileURL: root.appendingPathComponent(entry.filename), deviceID: deviceID) }
            selectedID = entries.first?.id
            if let entry = selected { section = entry.kind == .bookmarks ? "收藏夹" : "保险库" }
            #if os(macOS)
            if profile != nil || ProcessInfo.processInfo.arguments.contains("--profile") {
                bookmarkExchangeBase = root.appendingPathComponent("书签交换", isDirectory: true)
            }
            for entry in entries where entry.kind == .bookmarks && (try? exchangePreferences(entry.id).automatic) == true {
                automaticBookmarkFiles.insert(entry.id)
            }
            if startBrowserBridge {
                startBridge()
                let args = CommandLine.arguments
                if let index = args.firstIndex(of: "--unlock-bookmarks-stdin"), args.indices.contains(index+1),
                   let id = UUID(uuidString: args[index+1]), entries.contains(where: { $0.id == id && $0.kind == .bookmarks }),
                   isatty(STDIN_FILENO) == 0 {
                    selectSpace(id)
                    Task {
                        let input = await Task.detached { try? FileHandle.standardInput.read(upToCount: 4097) }.value
                        guard let input, input.count <= 4096, selectedID == id, let value = String(data:input, encoding:.utf8) else { return }
                        await unlock(password:value.trimmingCharacters(in:.newlines))
                    }
                }
            }
            #endif
        } catch { report(error) }
    }
    func report(_ error: Error) {
        self.error = (error as? PBError)?.localizedDescription ?? "操作未完成。请检查文件权限、文件格式或连接状态；本地有效数据已保留。"
    }
    func selectedStore() throws -> VaultStore {
        guard let id = selectedID, let store = stores[id] else { throw PBError.invalid("请先创建或连接数据空间。") }; return store
    }
    func selectSection(_ section: String) {
        cancelBiometricUnlock()
        self.section = section; search = ""; showDeleted = false; selectedFolder = nil
        if section == "收藏夹" || section == "保险库" {
            let kind: SpaceKind = section == "收藏夹" ? .bookmarks : .vault
            if selected?.kind != kind { selectedID = entries.first { $0.kind == kind }?.id }
        }
    }
    func selectSpace(_ id: UUID) {
        cancelBiometricUnlock()
        selectedID = id; selectedFolder = nil; showDeleted = false; search = ""
        if let entry = selected { section = entry.kind == .bookmarks ? "收藏夹" : "保险库" }
    }
    func refresh(_ id: UUID, userActivity: Bool = true) async throws {
        guard let store = stores[id], !lockingSpaces.contains(id) else { throw PBError.locked }
        let generation = lockGeneration[id, default: 0]
        let snapshot = try await store.snapshot()
        guard generation == lockGeneration[id, default: 0], !lockingSpaces.contains(id) else { throw PBError.locked }
        states[id] = snapshot
        if userActivity { lastActivity = Date() }
    }
    var biometricConfigured: Bool {
        guard let entry = selected else { return false }
        return BiometricUnlock.configured(root.appendingPathComponent(entry.filename))
    }
    func disableBiometricUnlock() {
        guard !busy, let entry = selected else { return }
        do {
            try BiometricUnlock.remove(root.appendingPathComponent(entry.filename))
            status[entry.id] = "已关闭本机生物识别解锁"
        } catch { report(error) }
    }
    func cancelBiometricUnlock() {
        guard let context = biometricContext else { return }
        if let id = biometricSpaceID { lockGeneration[id, default: 0] += 1 }
        finishBiometricUnlock(context)
    }
    private func finishBiometricUnlock(_ context: LAContext) {
        if biometricContext === context {
            biometricContext = nil
            biometricSpaceID = nil
        }
        context.invalidate()
    }
    private func beginBiometricUnlock(_ id: UUID) -> LAContext {
        let context = LAContext()
        biometricContext = context
        biometricSpaceID = id
        return context
    }
    private func unlockSession(_ open: (VaultStore, UUID, Int, URL) async throws -> Bool) async {
        guard !busy, let entry = selected, let store = stores[entry.id], !lockingSpaces.contains(entry.id) else { return }
        let id = entry.id, file = root.appendingPathComponent(entry.filename)
        busy = true; defer { busy = false }
        let generation = lockGeneration[id, default: 0]
        do {
            guard try await open(store, id, generation, file) else { return }
            guard generation == lockGeneration[id, default: 0], !lockingSpaces.contains(id) else {
                await store.lock(); throw PBError.locked
            }
            try await refresh(id); status[id] = "已解锁 · 本地数据可用"
            await loadSettings()
            requestSync(id)
            #if os(macOS)
            if automaticBookmarkFiles.contains(id) { pollBookmarkFiles() }
            #endif
        } catch let error as LAError where [.userCancel, .systemCancel, .appCancel].contains(error.code) {
            return
        } catch {
            if generation == lockGeneration[id, default: 0] { report(error) }
        }
    }
    func unlock(password: String, recovery: Bool = false, enableBiometric: Bool = false) async {
        await unlockSession { store, id, generation, file in
            if recovery { try await store.recover(secret: password); return true }
            try await store.unlock(password: password)
            if enableBiometric, generation == lockGeneration[id, default: 0], selectedID == id {
                let context = beginBiometricUnlock(id)
                defer { finishBiometricUnlock(context) }
                do {
                    try await BiometricUnlock.authenticate(context: context, reason: "为当前空间启用生物识别解锁")
                    guard generation == lockGeneration[id, default: 0], selectedID == id else { return true }
                    var key = try await store.deviceUnlockKey()
                    defer { key.resetBytes(in: 0..<key.count) }
                    guard generation == lockGeneration[id, default: 0], selectedID == id else { return true }
                    try BiometricUnlock.save(key, file: file, context: context)
                } catch let error as LAError where [.userCancel, .systemCancel, .appCancel].contains(error.code) {
                    return true
                } catch {
                    if error is PBError { report(error) }
                    else { report(PBError.invalid("已用主密码解锁，本机未能启用生物识别解锁。")) }
                }
            }
            return true
        }
    }
    func unlockWithBiometrics() async {
        await unlockSession { store, id, generation, file in
            let context = beginBiometricUnlock(id)
            defer { finishBiometricUnlock(context) }
            try await BiometricUnlock.authenticate(context: context, reason: "解锁 PBsync 当前空间")
            guard var key = try await Task.detached(operation: {
                try BiometricUnlock.read(file, context: context)
            }).value else { return false }
            defer { key.resetBytes(in: 0..<key.count) }
            guard selectedID == id, generation == lockGeneration[id, default: 0] else { return false }
            try await store.unlock(deviceKey: key)
            return true
        }
    }
    private func invalidateSensitiveState(for ids: Set<UUID>, all: Bool) {
        if all || biometricSpaceID.map(ids.contains) == true { cancelBiometricUnlock() }
        for id in ids {
            lockGeneration[id, default: 0] += 1
            states[id] = nil
            cancelScheduledSync(id)
        }
        if all || selectedID.map(ids.contains) == true {
            sensitivePresentationID = UUID()
            recoverySecret = nil; settings.secret = ""; search = ""
            if let id = selectedID { status[id] = "已锁定 · 未保存的编辑和未完成的导出已取消" }
        }
        #if os(macOS)
        if all || bridgeActiveVaultID.map(ids.contains) == true { fillPermit = nil }
        #endif
        if all || importTarget.map(ids.contains) == true { preview = nil; importTarget = nil }
        if let approval = pendingCredential, all || ids.contains(approval.spaceID) {
            finishCredentialApproval(approval.id, accepted: false)
        }
    }
    func lockAll() async {
        let ids = Set(stores.keys)
        lockingSpaces.formUnion(ids)
        invalidateSensitiveState(for: ids, all: true)
        for id in ids { await stores[id]?.lock() }
        lockingSpaces.subtract(ids)
        clearClipboard(); lastActivity = Date()
    }
    func lockSpace(_ id: UUID) async {
        lockingSpaces.insert(id)
        invalidateSensitiveState(for: [id], all: false)
        await stores[id]?.lock()
        lockingSpaces.remove(id)
        if copiedSpace == id { clearClipboard() }
    }
    func lockSelected() async {
        guard let id = selectedID else { return }; await lockSpace(id)
    }
    func finishCredentialApproval(_ id: UUID, accepted: Bool) {
        guard let approval = pendingCredential, approval.id == id else { return }
        pendingCredential = nil
        approval.completion(accepted && states[approval.spaceID] != nil && !lockingSpaces.contains(approval.spaceID))
    }
    func lockForInactivity() async {
        #if os(macOS)
        var keep = automaticBookmarkFiles.filter { states[$0]?.kind == .bookmarks }
        if let id = backgroundBookmarkID, id == bridgeActiveBookmarkID, !bridgeToken.isEmpty,
           states[id]?.kind == .bookmarks { keep.insert(id) }
        if !keep.isEmpty {
            for id in Array(stores.keys) where !keep.contains(id) { await lockSpace(id) }
            recoverySecret = nil
            clearClipboard()
            lastActivity = Date()
            return
        }
        #endif
        await lockAll()
    }
    func checkIdle(at now: Date = Date()) async { if now.timeIntervalSince(lastActivity) > 300 { await lockForInactivity() } }
    func spaceSession(_ id: UUID) -> String {
        "\(processSession.uuidString)/\(id.uuidString)/\(lockGeneration[id, default: 0])"
    }
    func touch() { lastActivity = Date() }
    func create(name: String, kind: SpaceKind, password: String) async {
        let epoch = sensitivePresentationID
        busy = true; defer { busy = false }
        do {
            let id = UUID(), filename = id.uuidString.lowercased() + ".pbsync"
            let (store, secret) = try VaultStore.create(fileURL: root.appendingPathComponent(filename), name: name.isEmpty ? (kind == .bookmarks ? "我的收藏夹" : "个人保险库") : name, kind: kind, password: password, deviceID: deviceID)
            let entry = CatalogEntry(id: id, filename: filename, kind: kind)
            try Catalog.add(entry, at: root); entries.append(entry); stores[id] = store; selectSpace(id)
            try await store.unlock(password: password); try await refresh(id)
            guard epoch == sensitivePresentationID, selectedID == id else { return }
            recoverySecret = secret; status[id] = "已保存到本机 · 尚未连接同步位置"
        } catch { report(error) }
    }
    func save(_ item: Item, spaceID: UUID? = nil, presentationID: UUID? = nil) async {
        guard let id = selectedID, states[id] != nil, !lockingSpaces.contains(id),
              spaceID == nil || spaceID == id,
              presentationID == nil || presentationID == sensitivePresentationID else { report(PBError.locked); return }
        busy = true; defer { busy = false }
        let session = spaceSession(id)
        do {
            let store = try selectedStore(), prepared = try await store.attachedItem(item)
            guard session == spaceSession(id), selectedID == id, states[id] != nil else { throw PBError.locked }
            _ = try await store.save(prepared); try await refresh(id)
            status[id] = "已保存到本机 · 待同步"; requestSync(id)
        }
        catch { report(error) }
    }
    func delete(_ item: Item) async {
        guard let id = selectedID else { return }
        do { _ = try await selectedStore().delete(item.id); try await refresh(id); status[id] = "已移至回收站 · 可恢复"; requestSync(id) }
        catch { report(error) }
    }
    func restore(_ revision: Revision) async {
        guard let id = selectedID else { return }
        do { try await selectedStore().restore(revision.id); try await refresh(id); status[id] = "已恢复为新版本 · 待同步"; requestSync(id) }
        catch { report(error) }
    }
    func move(_ item: Item, parentID: UUID?, order: Int64) async {
        var changed = item; changed.parentID = parentID; changed.order = order; await save(changed)
    }
    func placeBookmark(_ item: UUID, in parent: UUID?, before anchor: UUID? = nil) async {
        guard let id = selectedID, states[id]?.kind == .bookmarks, let store = stores[id] else { return }
        let session = spaceSession(id)
        do {
            try await store.placeBookmark(item, in: parent, before: anchor)
            guard spaceSession(id) == session, states[id] != nil else { return }
            try await refresh(id)
            status[id] = "收藏顺序已保存"
            requestSync(id)
        } catch {
            if spaceSession(id) == session { report(error) }
        }
    }
    func previewImport(url: URL) async {
        guard let current, let id = selectedID else { report(PBError.locked); return }
        let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
        do {
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= 128 * 1024 * 1024 else { throw PBError.invalid("文件超过导入上限。") }
            #if os(macOS)
            if current.kind == .vault, url.pathExtension.lowercased() == "1pux" {
                try await preview1PUX(url,target:id)
                return
            }
            #endif
            let data = try Data(contentsOf: url)
            if current.kind == .bookmarks { preview = try SafariBookmarks.preview(data) }
            else if url.pathExtension.lowercased() == "csv" { preview = try PasswordCSV.parse(data) }
            else if url.pathExtension.lowercased() == "json" { preview = try ConnectorImport.parse(data) }
            else { throw PBError.invalid("保险库界面当前接收 CSV；1PUX／KDBX 请使用随项目提供的桌面连接器生成导入包。") }
            importTarget = id
        } catch { report(error) }
    }
    func commitImport() async {
        guard let preview, let id = importTarget, id == selectedID else { return }
        busy = true; defer { busy = false }
        do {
            let store = try selectedStore()
            let count: Int
            if current?.kind == .bookmarks { count = try await store.mergeBookmarkFile(preview) }
            else { count = try await store.importItems(preview.items) }
            try await refresh(id)
            self.preview = nil; importTarget = nil; status[id] = "导入完成：新增或更新 \(count) 条 · 未删除来源数据"
            if count > 0 { requestSync(id) }
        } catch { report(error) }
    }
    func importBackup(url: URL, secret: String, recovery: Bool) async {
        let epoch = sensitivePresentationID
        busy = true; defer { busy = false }
        let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: url), archive = try Coding.decode(Archive.self, from: data)
            let key = try recovery ? Crypto.recover(archive.header, recovery: secret) : Crypto.unlock(archive.header, password: secret)
            let state = try Crypto.restore(archive, key: key)
            for store in stores.values {
                if await store.spaceHeader().spaceID == archive.header.spaceID { throw PBError.invalid("此空间已在当前设备中，请使用原空间的恢复入口，避免重复连接。") }
            }
            guard epoch == sensitivePresentationID else { throw PBError.locked }
            let id = UUID(), filename = id.uuidString.lowercased() + ".pbsync", file = root.appendingPathComponent(filename)
            try SafeFile.write(data, to: file)
            let entry = CatalogEntry(id: id, filename: filename, kind: state.kind), store = try VaultStore(fileURL: file, deviceID: deviceID)
            try Catalog.add(entry, at: root); entries.append(entry); stores[id] = store; selectSpace(id)
            if recovery { try await store.recover(secret: secret) } else { try await store.unlock(password: secret) }
            try await refresh(id); status[id] = "已从加密备份恢复 · 请连接主要同步位置"
        } catch { report(error) }
    }
    func settingsAccount(_ id: UUID) -> String { Crypto.digest(Data(root.path.utf8)) + ".storage." + id.uuidString }
    func loadSettings() async {
        guard let id = selectedID, states[id] != nil else { settings = StorageConfiguration(); return }
        do { settings = try Keychain.read(account: settingsAccount(id)).map { try Coding.decode(StorageConfiguration.self, from: $0) } ?? StorageConfiguration() }
        catch { report(error) }
    }
    func saveSettings() async {
        guard let id = selectedID, states[id] != nil else { report(PBError.locked); return }
        do {
            if settings.kind != .local { _ = try settings.storage() }
            // 变更主位置必须走显式迁移。首次连接允许直接设置。
            if let bytes = try Keychain.read(account: settingsAccount(id)) {
                let old = try Coding.decode(StorageConfiguration.self, from: bytes)
                if old.kind != .local && (old.kind != settings.kind || old.endpoint != settings.endpoint || old.folderBookmark != settings.folderBookmark) {
                    throw PBError.invalid("已有主要同步位置。请使用迁移功能，不能直接建立第二个主位置。")
                }
            }
            try Keychain.save(Coding.encode(settings), account: settingsAccount(id)); status[id] = "同步位置已保存"
            requestSync(id, immediately: true)
        } catch { report(error) }
    }
    func setFolder(_ url: URL) async {
        let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
        do { settings.folderBookmark = try StorageConfiguration.bookmark(for: url); settings.kind = .folder; settings.endpoint = url.lastPathComponent }
        catch { report(error) }
    }
    func sync() async {
        guard let id = selectedID else { return }
        #if os(macOS)
        if current?.kind == .bookmarks { await synchronizeBookmarkFile(); return }
        #endif
        syncTimers.removeValue(forKey: id)?.cancel()
        await runSync(id, manual: true)
    }
    func connectRemote(password: String) async {
        let epoch = sensitivePresentationID, config = settings
        busy = true; defer { busy = false }
        do {
            let id = UUID(), filename = id.uuidString.lowercased() + ".pbsync"
            let store = try await VaultStore.connect(storage: config.storage(), fileURL: root.appendingPathComponent(filename), password: password, deviceID: deviceID)
            var catalogued = false
            defer {
                if !catalogued {
                    // 此路径是本次刚创建并独占的随机文件。
                    try? FileManager.default.removeItem(at:root.appendingPathComponent(filename))
                    try? FileManager.default.removeItem(at:root.appendingPathComponent(filename).appendingPathExtension("lock"))
                }
            }
            let state = try await store.snapshot(), spaceID = await store.spaceHeader().spaceID
            for existing in stores.values where await existing.spaceHeader().spaceID == spaceID { throw PBError.invalid("此空间已连接，请从列表打开。") }
            guard epoch == sensitivePresentationID else { await store.lock(); throw PBError.locked }
            let entry = CatalogEntry(id: id, filename: filename, kind: state.kind)
            try Catalog.add(entry, at: root); catalogued = true; entries.append(entry); stores[id] = store; selectSpace(id); states[id] = state
            try Keychain.save(Coding.encode(config), account: settingsAccount(id)); status[id] = "已连接存储并完成合并"
        } catch { report(error) }
    }
    func configuredStorage() throws -> (any ObjectStorage)? {
        guard let id = selectedID, states[id] != nil else { throw PBError.locked }
        guard let data = try Keychain.read(account: settingsAccount(id)) else { return nil }
        let config = try Coding.decode(StorageConfiguration.self,from:data)
        return try config.kind == .local ? nil : config.storage()
    }
    func export(kind: String) async throws -> (Data, String) {
        guard let current else { throw PBError.locked }
        switch kind {
        case "safari-zip": return (try SafariBookmarks.export(current), "Safari-收藏夹.zip")
        case "html": return (try BookmarkHTML.export(current), "PBsync-收藏夹.html")
        case "csv": return (try PasswordCSV.export(current), "PBsync-登录账号-明文.csv")
        default: return (try await selectedStore().exportArchive(storage: configuredStorage()), "PBsync-加密备份.pbsync")
        }
    }
    func changePassword(_ password: String) async {
        guard let space = selectedID, !syncInFlight.contains(space), syncSuspended.insert(space).inserted else {
            report(PBError.invalid("同步正在进行，请在完成后重试。")); return
        }
        cancelScheduledSync(space)
        defer { syncSuspended.remove(space); requestSync(space) }
        busy = true; defer { busy = false }
        do {
            await loadSettings(); let storage: (any ObjectStorage)? = settings.kind == .local ? nil : try settings.storage()
            try await selectedStore().changePassword(password, storage: storage)
            if let id = selectedID { try await refresh(id); status[id] = "主密码已更新 · 旧备份仍可能使用旧密码" }
        } catch { report(error) }
    }
    func migrate(newPassword: String) async {
        guard let space = selectedID, !syncInFlight.contains(space), syncSuspended.insert(space).inserted else {
            report(PBError.invalid("同步正在进行，请在完成后重试。")); return
        }
        cancelScheduledSync(space)
        defer { syncSuspended.remove(space); requestSync(space) }
        guard let id = selectedID else { return }; busy = true; defer { busy = false }
        do {
            guard let bytes = try Keychain.read(account: settingsAccount(id)) else { throw PBError.invalid("当前空间没有已连接的主要存储位置。") }
            let old = try Coding.decode(StorageConfiguration.self, from: bytes), next = settings, epoch = sensitivePresentationID
            let recovery = try await selectedStore().migrate(from: old.storage(), to: next.storage(), newPassword: newPassword)
            try Keychain.save(Coding.encode(next), account: settingsAccount(id))
            guard epoch == sensitivePresentationID, selectedID == id else { return }; recoverySecret = recovery
            try await refresh(id); status[id] = "已迁移并轮换密钥 · 请让其他设备连接新位置，并撤销旧存储凭据"
        } catch { report(error) }
    }
    func copy(_ text: String) {
        let token = UUID(); clipboardToken = token; touch()
        #if os(macOS)
        pasteboard.clearContents(); pasteboard.setString(text, forType: .string)
        #else
        pasteboard.setItems([[UIPasteboard.typeAutomatic: text]], options: [.localOnly: true, .expirationDate: Date().addingTimeInterval(30)])
        #endif
        copiedChange = pasteboard.changeCount; copiedSpace = selectedID
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 30_000_000_000)
            if self?.clipboardToken == token { self?.clearClipboard() }
        }
    }
    func clearClipboard() {
        defer { copiedChange = nil; copiedSpace = nil; clipboardToken = UUID() }
        guard let copiedChange, pasteboard.changeCount == copiedChange else { return }
        #if os(macOS)
        pasteboard.clearContents()
        #else
        pasteboard.items = []
        #endif
    }
}
