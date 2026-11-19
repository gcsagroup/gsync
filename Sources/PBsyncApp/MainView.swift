import SwiftUI
import PBsyncCore
import UniformTypeIdentifiers

struct MainView: View {
    @EnvironmentObject var model: AppModel
    @State private var compactColumn = NavigationSplitViewColumn.sidebar
    @State private var showCreate = false
    @State private var showImport = false
    @State private var showBackupImport = false
    @State private var editing: Item?
    @State private var selection: UUID?
    @State private var exportDocument = ExportDocument(data: Data())
    @State private var exportName = "PBsync-加密备份.pbsync"
    @State private var showExport = false
    @State private var confirmPlaintext = false
    @State private var deleteCandidate: Item?
    #if os(macOS)
    @State private var showConnectionSettings = false
    #endif
    private let sections: [(String, String)] = [("收藏夹", "bookmark"), ("保险库", "lock.shield"), ("同步与连接", "arrow.triangle.2.circlepath"), ("恢复与备份", "clock.arrow.circlepath"), ("设置", "gearshape")]
    var body: some View {
        NavigationSplitView(preferredCompactColumn: $compactColumn) {
            VStack(alignment: .leading, spacing: 24) {
                HStack(spacing: 12) {
                    Image(systemName: "square.stack.3d.up.fill").font(.title).foregroundStyle(.tint)
                    Text("PBsync").font(.title2.bold())
                }.padding(.top, 22).padding(.horizontal, 18)
                if model.usesSeparateProfile {
                    VStack(alignment: .leading, spacing: 4) {
                        Label("独立资料模式", systemImage: "folder.badge.gearshape")
                        Text("与日常资料分开，来源需单独连接。").font(.caption).foregroundStyle(.secondary)
                    }.font(.callout).padding(.horizontal, 18)
                }
                List {
                    Section("工作空间") {
                        ForEach(sections, id: \.0) { name, icon in
                            Button { model.selectSection(name); selection = nil; compactColumn = .detail } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: icon).frame(width: 20)
                                    Text(name == "保险库" ? "密码库" : name)
                                }.font(.system(size: 14, weight: model.section == name ? .semibold : .regular))
                                    .foregroundStyle(model.section == name ? pbsyncAccent : .primary)
                                    .padding(.vertical, 6).frame(maxWidth: .infinity, alignment: .leading)
                                    .contentShape(Rectangle())
                            }.buttonStyle(.plain)
                                .listRowBackground(model.section == name ? pbsyncAccent.opacity(0.12) : Color.clear)
                        }
                    }
                    Section("我的数据空间") {
                        ForEach(model.entries) { entry in
                            Button { model.selectSpace(entry.id); selection = nil; compactColumn = .detail } label: {
                                HStack { Image(systemName: entry.kind == .bookmarks ? "folder" : "lock"); Text(model.spaceDisplayName(entry)); Spacer(); if entry.id == model.selectedID { Image(systemName: "checkmark").foregroundStyle(.tint) } }
                                    .font(.callout).padding(.vertical, 3).contentShape(Rectangle())
                            }.buttonStyle(.plain)
                        }
                        Button { showCreate = true } label: { Label("创建数据空间", systemImage: "plus.circle") }
                        Button { showBackupImport = true } label: { Label("从备份连接", systemImage: "square.and.arrow.down") }
                    }
                }.listStyle(.sidebar)
                VStack(alignment: .leading, spacing: 6) {
                    #if os(macOS)
                    if !model.automaticBookmarkFiles.intersection(model.states.keys).isEmpty ||
                        (model.backgroundBookmarkID.flatMap { model.states[$0] } != nil && !model.bridgeToken.isEmpty) {
                        Label("后台连接检查已启用", systemImage: "arrow.triangle.2.circlepath")
                    } else {
                        Label("解密钥匙由你保管", systemImage: "key.horizontal")
                    }
                    #else
                    Label("解密钥匙由你保管", systemImage: "key.horizontal")
                    #endif
                }.padding(18)
            }
            .navigationSplitViewColumnWidth(min: 230, ideal: 255)
        } detail: {
            VStack(spacing: 0) {
                header
                Divider()
                if ["收藏夹", "保险库"].contains(model.section) { workspace }
                else if model.section == "同步与连接" {
                    #if os(macOS)
                    DesktopConnectionsView()
                    #else
                    ConnectionView().id(model.sensitivePresentationID)
                    #endif
                }
                else if model.section == "恢复与备份" { RecoveryView(onExport: { Task { await prepareExport("archive") } }, onImport: { showBackupImport = true }).id(model.sensitivePresentationID) }
                else { SettingsView() }
                if let id = model.selectedID, let status = model.status[id] {
                    Divider()
                    HStack { Image(systemName: model.busy ? "arrow.triangle.2.circlepath" : "info.circle"); Text(status).font(.caption); Spacer() }.foregroundStyle(.secondary).padding(12)
                }
            }
            #if os(macOS)
            .navigationTitle("PBsync")
            .frame(minWidth: 650, minHeight: 590)
            #else
            .navigationTitle("")
            #endif
        }
        .sheet(isPresented: $showCreate) { CreateSpaceView().environmentObject(model) }
        .sheet(item: $model.pendingCredential) { approval in CredentialApprovalView(approval: approval).environmentObject(model) }
        .sheet(isPresented: $showBackupImport) { BackupImportView().environmentObject(model) }
        .sheet(item: $editing) { item in
            if let id = model.selectedID, model.current != nil {
                ItemEditor(item: item, spaceID: id, presentationID: model.sensitivePresentationID).environmentObject(model)
            }
        }
        .sheet(isPresented: Binding(get: { model.recoverySecret != nil }, set: { if !$0 { model.recoverySecret = nil } })) { RecoverySecretView().environmentObject(model) }
        .sheet(isPresented: Binding(get: { model.preview != nil }, set: { if !$0 { model.preview = nil; model.importTarget = nil } })) { ImportPreviewView().environmentObject(model) }
        #if os(macOS)
        .sheet(isPresented: $showConnectionSettings) {
            VStack(spacing: 0) {
                HStack {
                    Text("连接来源与同步位置").font(.title2.bold())
                    Spacer()
                    Button("完成") { showConnectionSettings = false }.keyboardShortcut(.cancelAction)
                }.padding()
                Divider()
                ConnectionView()
            }.frame(minWidth: 670, idealWidth: 725, minHeight: 600, idealHeight: 710)
        }
        .sheet(item: $model.fileVaultSelection) { choice in
            VStack(alignment: .leading, spacing: 12) {
                Text("选择 1PUX 来源保险库").font(.headline)
                ForEach(choice.choices) { vault in
                    Button("\(vault.name)（\(vault.count) 项）") {
                        model.fileVaultSelection = nil
                        guard model.spaceSession(choice.target) == choice.session else { return }
                        Task {
                            do { try await model.preview1PUX(choice.url,target:choice.target,vault:vault.id) }
                            catch { model.report(error) }
                        }
                    }
                }
                Button("取消") { model.fileVaultSelection = nil }
            }.padding()
        }
        #endif
        #if os(macOS)
        .onReceive(model.$bookmarkFileSelection) { selection in
            if selection != nil { showImport = true }
        }
        .onReceive(model.$bookmarkExportSelection) { selection in
            if let selection {
                exportDocument = ExportDocument(data: selection.data); exportName = selection.name; showExport = true
            }
        }
        #endif
        .fileImporter(isPresented: $showImport, allowedContentTypes: [.html, .commaSeparatedText, .plainText, .data]) { result in
            #if os(macOS)
            if let selection = model.bookmarkFileSelection {
                model.bookmarkFileSelection = nil
                if case .success(let url) = result { Task { await model.receiveBookmarkFile(url, selection: selection) } }
                else if case .failure(let error) = result, (error as NSError).code != NSUserCancelledError { model.report(error) }
                return
            }
            #endif
            if case .success(let url) = result { Task { await model.previewImport(url: url) } }
            else if case .failure(let error) = result { model.report(error) }
        }
        .fileExporter(isPresented: $showExport, document: exportDocument, contentType: .data, defaultFilename: exportName) { result in
            exportDocument = ExportDocument(data: Data())
            #if os(macOS)
            if let selection = model.bookmarkExportSelection {
                model.bookmarkExportSelection = nil
                model.bookmarkExportCompleted(result, selection: selection)
                return
            }
            #endif
            if case .failure(let error) = result { model.report(error) }
        }
        .modifier(ExchangeReceiver())
        .onReceive(model.$sensitivePresentationID.dropFirst()) { _ in
            clearSensitivePresentation()
            #if os(macOS)
            showConnectionSettings = false
            #endif
        }
        .onChange(of: model.selectedID) { _, _ in clearSensitivePresentation() }
        .alert("操作提示", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) { Button("知道了") { model.error = nil } } message: { Text(model.error ?? "") }
        .confirmationDialog("导出的 CSV 包含明文密码，仅包含登录字段，不是完整备份。", isPresented: $confirmPlaintext, titleVisibility: .visible) { Button("继续导出明文 CSV", role: .destructive) { Task { await prepareExport("csv") } } }
        .confirmationDialog(deleteCandidate?.kind == .folder
                            ? "移至回收站？文件夹中的所有收藏也会一并移入，可在历史中恢复。"
                            : "移至回收站？可在历史中恢复。", isPresented: Binding(get: { deleteCandidate != nil }, set: { if !$0 { deleteCandidate = nil } }), titleVisibility: .visible) {
            Button("移至回收站", role: .destructive) { if let item = deleteCandidate { Task { await model.delete(item); selection = nil; deleteCandidate = nil } } }
        }
    }
    private var header: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text(model.section == "保险库" ? "密码库" : model.section).font(.system(size: 27, weight: .bold))
                #if os(macOS)
                if model.section == "收藏夹", let id = model.selectedID, model.automaticBookmarkFiles.contains(id) {
                    Text(model.current == nil ? "已锁定 · 文件交换暂停" : (model.bookmarkFileStatus[id] ?? "后台文件交换已启用"))
                        .font(.callout).foregroundStyle(.secondary)
                }
                #else
                Text(subtitle).font(.callout).foregroundStyle(.secondary)
                #endif
            }
            Spacer()
            if model.busy { ProgressView().controlSize(.small) }
            #if os(macOS)
            if model.section == "同步与连接" {
                Button { showConnectionSettings = true } label: { Label("连接来源", systemImage: "plus") }
                    .buttonStyle(.borderedProminent)
            } else if (model.section == "收藏夹" || model.section == "保险库"), model.current != nil {
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField(model.section == "收藏夹" ? "搜索收藏夹" : "搜索密码库", text: $model.search)
                        .textFieldStyle(.plain).onChange(of: model.search) { _, _ in model.touch(); selection = nil }
                }.padding(7).background(.quaternary, in: RoundedRectangle(cornerRadius: 7)).frame(maxWidth: 240)
                Button { addItem() } label: { Label(model.section == "收藏夹" ? "新增收藏" : "新增密码", systemImage: "plus") }
                    .buttonStyle(.borderedProminent)
                Button { Task { await model.lockSelected() } } label: { Image(systemName: "lock") }.help("锁定当前空间")
            }
            #else
            if model.current != nil {
                Button { Task { await model.sync() } } label: { Label("同步", systemImage: "arrow.triangle.2.circlepath") }.disabled(model.busy)
                Button { Task { await model.lockSelected() } } label: { Image(systemName: "lock.fill") }.help("锁定当前空间")
            }
            #endif
        }.padding(24)
    }
    private var subtitle: String {
        switch model.section {
        case "收藏夹": return "保留目录与顺序，把常用网址带到每一台设备。"
        case "保险库": return "密码、验证码与重要资料，独立加密保存。"
        case "同步与连接": return "每个空间使用一个主要同步位置。"
        case "恢复与备份": return "保留恢复材料，让误删和换机都有退路。"
        default: return "按你的使用习惯管理保存、填充与锁定。"
        }
    }
    @ViewBuilder private var workspace: some View {
        if model.selected == nil {
            ContentUnavailableView {
                Label(model.section == "收藏夹" ? "把分散的收藏带到一起" : "建立属于你的保险库", systemImage: model.section == "收藏夹" ? "bookmark.circle" : "lock.shield")
            } description: { Text("从本机开始，也可以连接已有加密备份。\n收藏夹和保险库分别解锁，自备存储不需要注册账号。") } actions: {
                Button("创建\(model.section)") { showCreate = true }.buttonStyle(.borderedProminent)
                Button("从备份连接") { showBackupImport = true }
            }
        } else if model.current == nil { UnlockView() }
        else {
            #if os(macOS)
            if let state = model.current {
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        Group {
                            if state.kind == .bookmarks {
                                if model.backgroundBookmarkID == model.selectedID && !model.bridgeToken.isEmpty {
                                    Label("已授权浏览器后台同步", systemImage: "arrow.triangle.2.circlepath")
                                } else { Label("浏览器连接设置", systemImage: "globe") }
                            } else {
                                Label("密码库已解锁", systemImage: "lock.open")
                            }
                        }.foregroundStyle(.secondary)
                        if state.kind == .bookmarks {
                            Button("连接") {
                                model.selectSection("同步与连接")
                                showConnectionSettings = true
                            }.buttonStyle(.link)
                        }
                        Spacer()
                        Toggle("回收站", isOn: $model.showDeleted).toggleStyle(.button)
                        Menu {
                            if state.kind == .bookmarks {
                                Button("新增文件夹…") { addItem(kind: .folder) }
                                Button("检查书签交换文件") { Task { await model.synchronizeBookmarkFile() } }
                            }
                            importExportActions
                            Button("同步主要存储") {
                                if let id = model.selectedID { Task { await model.runSync(id, manual: true) } }
                            }
                        } label: { Image(systemName: "ellipsis.circle") }.accessibilityLabel("导入、导出与其他操作")
                    }.padding(.horizontal, 16).padding(.vertical, 8)
                    Divider()
                    if state.kind == .bookmarks {
                        DesktopBookmarkLibrary(selection: $selection, state: state,
                                               edit: { editing = $0 }, delete: { deleteCandidate = $0 })
                    } else {
                        DesktopPasswordLibrary(selection: $selection, edit: { editing = $0 },
                                               delete: { deleteCandidate = $0 })
                    }
                }.onChange(of: model.showDeleted) { _, _ in selection = nil; model.touch() }
            }
            #else
            VStack(spacing: 0) {
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField(model.current?.kind == .bookmarks ? "搜索收藏" : "搜索密码库", text: $model.search)
                        .textFieldStyle(.plain)
                    if model.current?.kind == .bookmarks, let parent = model.selectedFolder {
                        Button {
                            model.selectedFolder = model.current?.current[parent]?.item.parentID
                        } label: {
                            Label("返回上层", systemImage: "arrow.up")
                                .labelStyle(.iconOnly)
                        }.accessibilityLabel("返回上层")
                    }
                    Toggle(isOn: $model.showDeleted) {
                        Label("回收站", systemImage: "trash")
                            .labelStyle(.iconOnly)
                    }.toggleStyle(.button).accessibilityLabel("回收站")
                    Menu { importExportActions } label: { Image(systemName: "square.and.arrow.up.on.square") }
                    Button { addItem() } label: {
                        Label("新增", systemImage: "plus").fixedSize()
                    }.buttonStyle(.borderedProminent)
                }.padding(16)
                if model.current?.clockWarning == true { Label("检测到设备时间异常；已保留冲突历史，请核对设备时间。", systemImage: "clock.badge.exclamationmark").font(.caption).foregroundStyle(.orange).padding(8) }
                Divider()
                if model.visibleItems.isEmpty {
                    ContentUnavailableView(model.showDeleted ? "回收站是空的" : (model.search.isEmpty ? "从第一条内容开始" : "没有找到匹配内容"), systemImage: model.showDeleted ? "trash" : "tray", description: Text(model.search.isEmpty ? "新增条目，或通过文件导入现有数据。" : "试试其他标题、网址或用户名。"))
                } else {
                    List(selection: $selection) {
                        ForEach(model.visibleItems) { item in
                            HStack(spacing: 14) {
                                Image(systemName: icon(item.kind)).font(.title3).foregroundStyle(.tint).frame(width: 38, height: 38).background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(item.title.isEmpty ? "未命名" : item.title).font(.headline)
                                    Text(item.kind == .bookmark ? (item.urls.first ?? "") : (item.fields["username"] ?? item.kind.label)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer()
                                if item.kind == .folder { Button { model.selectedFolder = item.id; selection = nil } label: { Image(systemName: "chevron.right") }.buttonStyle(.plain) }
                                else if item.kind == .bookmark, let url = item.urls.first, CredentialPolicy.safeBookmarkURL(url), let target = URL(string: url) { Link(destination: target) { Image(systemName: "arrow.up.right.square") } }
                                Menu {
                                    if model.showDeleted { Button("恢复") { if let revision = model.current?.history(for: item.id).first { Task { await model.restore(revision) } } } }
                                    else {
                                        Button("编辑") { editing = item }
                                        if #available(macOS 26, iOS 26, *), item.kind == .passkey { ExportPasskey(id: item.id) }
                                        Button("移至回收站", role: .destructive) { deleteCandidate = item }
                                    }
                                } label: { Image(systemName: "ellipsis") }
                            }.padding(.vertical, 7).tag(item.id)
                                .onTapGesture { selection = item.id; model.touch() }
                        }
                    }.listStyle(.inset)
                    if let id = selection, let item = model.current?.current[id]?.item {
                        Divider(); ItemDetail(item: item).id(id).frame(maxHeight: 300)
                    }
                }
            }
            #endif
        }
    }
    @ViewBuilder private var importExportActions: some View {
        Button("导入文件…") {
            #if os(macOS)
            if model.current?.kind == .bookmarks { Task { await model.beginBookmarkImport() } }
            else { showImport = true }
            #else
            showImport = true
            #endif
        }
        Button("导出加密备份…") { Task { await prepareExport("archive") } }
        if model.current?.kind == .bookmarks {
            Button("导出 Safari 交换 ZIP…") { Task { await prepareExport("safari-zip") } }
            Button("导出 Safari 收藏夹 HTML…") { Task { await prepareExport("html") } }
        } else { Button("导出明文登录 CSV…") { confirmPlaintext = true } }
    }
    private func addItem(kind: ItemKind? = nil) {
        guard let state = model.current else { return }
        let live = state.current
        let last = state.items.filter { state.effectiveParent(of: $0, live: live) == model.selectedFolder }.map(\.order).max() ?? -1
        editing = Item(kind: kind ?? (state.kind == .bookmarks ? .bookmark : .login),
                       title: "", parentID: model.selectedFolder, order: min(last, 999_999) + 1)
    }
    private func clearSensitivePresentation() {
        #if os(macOS)
        model.fileVaultSelection = nil
        model.bookmarkFileSelection = nil; model.bookmarkExportSelection = nil
        #endif
        editing = nil; selection = nil; deleteCandidate = nil
        showExport = false; confirmPlaintext = false; exportDocument = ExportDocument(data: Data())
        showCreate = false; showImport = false; showBackupImport = false
    }
    private func prepareExport(_ kind: String) async {
        let session = model.sensitivePresentationID, space = model.selectedID
        do {
            let (data, name) = try await model.export(kind: kind)
            guard session == model.sensitivePresentationID, space == model.selectedID, model.current != nil else { return }
            #if os(macOS)
            if model.current?.kind == .bookmarks {
                await model.saveBookmarkExport(data: data, name: name,
                    message: kind == "archive" ? "加密备份已保存" : "书签文件已导出，Safari 尚需导入")
                return
            }
            #endif
            exportDocument = ExportDocument(data: data); exportName = name; showExport = true
        } catch { model.report(error) }
    }
}

func icon(_ kind: ItemKind) -> String {
    switch kind {
    case .folder: return "folder.fill"
    case .bookmark: return "bookmark.fill"
    case .login: return "key.fill"
    case .totp: return "number.square"
    case .passkey: return "person.badge.key.fill"
    case .recoveryCodes: return "lifepreserver"
    case .card: return "creditcard"
    case .identity: return "person.text.rectangle"
    case .note: return "note.text"
    }
}

struct UnlockView: View {
    @EnvironmentObject var model: AppModel
    @State private var secret = ""
    @State private var useRecovery = false
    @State private var enableBiometric = false
    @State private var biometricName: String?
    @State private var biometricConfigured = false
    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "lock.shield").font(.system(size: 48)).foregroundStyle(.tint)
            Text("解锁\(model.selected?.kind == .bookmarks ? "收藏夹" : "保险库")").font(.title2.bold())
            Text("内容仅在当前设备解密。解锁收藏夹不会解锁保险库。").font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            if let biometricName, biometricConfigured {
                Button {
                    Task { await model.unlockWithBiometrics() }
                } label: {
                    Label("使用\(biometricName)解锁", systemImage: biometricName == "Face ID" ? "faceid" : "touchid")
                }.buttonStyle(.borderedProminent).disabled(model.busy)
            }
            SecureField(useRecovery ? "恢复密钥" : "主密码", text: $secret).textFieldStyle(.roundedBorder).onSubmit { unlock() }
            Toggle("使用恢复密钥", isOn: $useRecovery).font(.callout)
            if let biometricName, !useRecovery && !biometricConfigured {
                Toggle("在此设备启用\(biometricName)解锁", isOn: $enableBiometric).font(.callout)
            }
            Button("解锁") { unlock() }.buttonStyle(.borderedProminent).disabled(secret.isEmpty || model.busy)
            if model.biometricSpaceID != nil {
                Button("取消生物识别验证") { model.cancelBiometricUnlock() }
            }
        }
        .frame(maxWidth: 360).padding(32).frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: model.selectedID) {
            secret = ""
            useRecovery = false
            enableBiometric = false
            biometricName = BiometricUnlock.name
            biometricConfigured = model.biometricConfigured
        }
    }
    private func unlock() {
        let value = secret, recovery = useRecovery
        let enable = enableBiometric && !recovery
        secret = ""
        Task { await model.unlock(password: value, recovery: recovery, enableBiometric: enable) }
    }
}

struct CreateSpaceView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) var dismiss
    @State private var name = ""
    @State private var kind: SpaceKind = .bookmarks
    @State private var password = ""
    @State private var repeated = ""
    var body: some View {
        NavigationStack {
            Form {
                Section("创建独立加密空间") {
                    Picker("用途", selection: $kind) { Text("收藏夹").tag(SpaceKind.bookmarks); Text("保险库").tag(SpaceKind.vault) }
                    TextField("名称", text: $name)
                    SecureField("主密码（至少 12 个字符）", text: $password)
                    SecureField("再次输入主密码", text: $repeated)
                }
                Section { Text("先保存到本机，再选择 WebDAV 或文件夹。创建后请另行保管恢复密钥；官方无法解密或找回你的内容。").font(.callout).foregroundStyle(.secondary) }
            }.formStyle(.grouped).navigationTitle("创建数据空间")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) { Button("创建") {
                        Task { await model.create(name: name, kind: kind, password: password); if model.error == nil { password = ""; repeated = ""; dismiss() } }
                    }.disabled(password.count < 12 || password != repeated || model.busy) }
                }
        }.frame(minWidth: 360, idealWidth: 480, minHeight: 380).onAppear { kind = model.section == "保险库" ? .vault : .bookmarks }
    }
}

struct RecoverySecretView: View {
    @EnvironmentObject var model: AppModel
    @State private var confirmed = false
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Label("保存恢复密钥", systemImage: "key.horizontal").font(.title2.bold())
            Text("主密码遗失时，恢复密钥与加密数据可以帮助你恢复。请放在保险库之外的安全位置，不要与同步数据保存在一起。")
            Text(model.recoverySecret ?? "").font(.system(.callout, design: .monospaced)).textSelection(.enabled).padding().background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
            Button("复制（30 秒后清除）") { model.copy(model.recoverySecret ?? "") }
            Toggle("我已另外保存恢复密钥", isOn: $confirmed)
            Button("完成") { model.recoverySecret = nil }.buttonStyle(.borderedProminent).disabled(!confirmed)
        }.padding(28).frame(minWidth: 360, idealWidth: 520).interactiveDismissDisabled()
    }
}

struct ImportPreviewView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) var dismiss
    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                Text("预览 \(model.preview?.count ?? 0) 个条目").font(.title2.bold())
                Text("确认后一次性合并到当前空间。相同来源保持身份；文件缺少旧条目不会触发删除。").font(.callout).foregroundStyle(.secondary)
                ForEach(model.preview?.warnings ?? [], id: \.self) { Text($0).font(.caption).foregroundStyle(.orange) }
                List(model.preview?.items ?? []) { item in Label(item.title.isEmpty ? "未命名" : item.title, systemImage: icon(item.kind)) }
            }.padding(20).navigationTitle("导入预览")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("取消") { model.preview = nil; dismiss() } }
                    ToolbarItem(placement: .confirmationAction) { Button("确认合并") { Task { await model.commitImport() } }.disabled(model.busy) }
                }
        }.frame(minWidth: 360, idealWidth: 550, minHeight: 450)
    }
}
