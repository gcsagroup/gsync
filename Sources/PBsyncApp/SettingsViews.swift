import SwiftUI
import UniformTypeIdentifiers
import PBsyncCore

struct ConnectionView: View {
    @EnvironmentObject var model: AppModel
    @State private var pickFolder = false
    @State private var remotePassword = ""
    @State private var connectExisting = false
    @State private var migration = false
    @State private var migrationPassword = ""
    var body: some View {
        Form {
            Section("当前数据空间") {
                if model.entries.isEmpty { Text("可先创建空间，或填写已有远端空间的位置后连接。").foregroundStyle(.secondary) }
                else {
                    Picker("空间", selection: $model.selectedID) {
                        ForEach(model.entries) { entry in Text(model.spaceDisplayName(entry)).tag(Optional(entry.id)) }
                    }
                }
            }
            Section { AccountDevicesView() }
            Section("主要同步位置") {
                Picker("存储方式", selection: $model.settings.kind) {
                    Text("仅保存在本机").tag(StorageConfiguration.Kind.local)
                    Text("文件夹／网盘目录").tag(StorageConfiguration.Kind.folder)
                    Text("WebDAV／NAS").tag(StorageConfiguration.Kind.webdav)
                    Text("本地云验证").tag(StorageConfiguration.Kind.localCloud)
                }
                if model.settings.kind == .folder {
                    Button(model.settings.folderBookmark == nil ? "选择此空间的专用目录…" : "重新选择目录…") { pickFolder = true }
                    Text(model.settings.endpoint.isEmpty ? "不同空间请使用不同目录；本地写入不表示另一设备已收到。" : "目录：\(model.settings.endpoint)").font(.caption).foregroundStyle(.secondary)
                } else if model.settings.kind == .webdav || model.settings.kind == .localCloud {
                    TextField(model.settings.kind == .webdav ? "HTTPS 目录地址" : "本机验证目录地址", text: $model.settings.endpoint)
                    if model.settings.kind == .webdav { TextField("用户名", text: $model.settings.username) }
                    SecureField(model.settings.kind == .webdav ? "密码或应用密码" : "本地测试令牌", text: $model.settings.secret)
                    Text("凭据仅保存在本机系统钥匙串。服务端只接收密文，不接收主密码。").font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Button("保存位置") { Task { await model.saveSettings() } }.disabled(model.current == nil || model.busy)
                    Button("立即同步") { Task { await model.sync() } }.buttonStyle(.borderedProminent).disabled(model.current == nil || model.busy)
                }
                Toggle("将当前空间迁移到上面填写的新位置", isOn: $migration)
                if migration {
                    SecureField("迁移后的新主密码（至少 12 个字符）", text: $migrationPassword)
                    Text("目标须为空。完整副本验证通过后冻结旧位置，并生成新的数据密钥与恢复密钥。其他设备需重新连接；请另外撤销丢失设备的存储权限。迁移期间暂停编辑。").font(.caption).foregroundStyle(.secondary)
                    Button("复制、校验并切换位置") { let secret = migrationPassword; migrationPassword = ""; Task { await model.migrate(newPassword: secret) } }.disabled(migrationPassword.count < 12 || model.current == nil || model.busy)
                }
                Toggle("连接已有远端空间", isOn: $connectExisting)
                if connectExisting {
                    SecureField("远端空间的主密码", text: $remotePassword)
                    Button("读取、解锁并连接") { let password = remotePassword; remotePassword = ""; Task { await model.connectRemote(password: password) } }.disabled(remotePassword.isEmpty || model.settings.kind == .local || model.busy)
                }
            }
            Section("浏览器与外部来源") {
                capability("Chrome／Firefox／Edge／Aegis", detail: "使用项目提供的桌面扩展。每个浏览器配置文件单独连接；首次合并需预览。", icon: "globe")
                #if os(macOS)
                capability("Safari 收藏夹", detail: "固定位置的书签 HTML／ZIP 可在后台合并并写出交换文件。Safari 端仍需执行导入。", icon: "safari")
                if let id = model.selectedID, model.current?.kind == .bookmarks {
                    Toggle("后台处理此收藏夹的交换文件", isOn: Binding(
                        get: { model.automaticBookmarkFiles.contains(id) },
                        set: { model.setAutomaticBookmarkFiles($0, for: id) }
                    ))
                    Text("固定交换目录：\(model.exchangeFiles(id).directory.path)\n来源放在“待导入”，结果以未加密的书签文件写到“已导出”。锁屏、手动锁定或退出时暂停。").font(.caption).textSelection(.enabled)
                }
                #else
                capability("Safari 收藏夹", detail: "在 PBsync 通过文件选择器交换书签 HTML／ZIP。Safari 端的导入和回读单独确认。", icon: "safari")
                #endif
                capability("Apple／Google／浏览器密码", detail: "通过用户主动导出的 CSV 迁移。扩展不能读取浏览器内置密码库。", icon: "key")
                capability("1Password 与 KeePass", detail: "桌面连接器处理 1PUX、KDBX 和已授权的来源库。来源授权与写回验证单独进行。", icon: "externaldrive.badge.person.crop")
            }
            #if os(macOS)
            ExternalSourceView()
            Section("配对桌面扩展") {
                if model.bridgeAuthorizationNeedsUnlock {
                    Text("已有浏览器连接需要系统钥匙串确认，原配对仍保留。")
                    Button("恢复已有浏览器连接") { Task { await model.restoreBrowserAuthorization(interactive: true) } }
                        .disabled(model.restoringBridgeAuthorization)
                }
                Picker("授权收藏夹", selection: $model.bridgeBookmarkID) {
                    Text("不授权").tag(Optional<UUID>.none)
                    ForEach(model.entries.filter { $0.kind == .bookmarks }) { entry in Text(model.states[entry.id]?.name ?? "收藏夹（已锁定）").tag(Optional(entry.id)) }
                }
                Picker("授权保险库", selection: $model.bridgeVaultID) {
                    Text("不授权").tag(Optional<UUID>.none)
                    ForEach(model.entries.filter { $0.kind == .vault }) { entry in Text(model.states[entry.id]?.name ?? "保险库（已锁定）").tag(Optional(entry.id)) }
                }
                TextField("允许自动填入的网站（每行一个 HTTPS 地址）", text: $model.autoFillOrigins, axis: .vertical).lineLimit(2...6)
                TextField("自动保存的登录成功页（每个网站一行）", text: $model.autoSavePages, axis: .vertical).lineLimit(2...6)
                Text("为上面所选保险库填写登录成功后才会出现的固定 HTTPS 地址。留空时逐次确认。生成配对密钥后，请到扩展设置授权网站。").font(.caption)
                Toggle("Mac 解锁期间允许此收藏夹后台同步", isOn: $model.backgroundBookmarks)
                Text("生成配对密钥后生效。PBsync 运行时，切换窗口或空闲仍可同步。手动锁定、锁屏或退出将暂停。").font(.caption)
                Button("生成新的配对密钥") { model.pairBrowser() }
                if !model.bridgeToken.isEmpty {
                    Button("复制配对密钥，粘贴到扩展设置") { if model.canCopyBridgeToken { model.copy(model.bridgeToken) } }.disabled(!model.canCopyBridgeToken)
                    Button("撤销所有已配对扩展", role: .destructive) { model.revokeBrowsers() }
                }
                Text("配对密钥只授权所选空间，消息在扩展与 App 间加密。更改授权范围后重新生成密钥；旧密钥失效。默认填充和保存需要确认。").font(.caption).foregroundStyle(.secondary)
            }
            #endif
            Section("连接边界") { Text("iPhone 直接访问所选存储，不通过 Mac 中转。桌面专属来源连接器需要桌面上线。系统后台时机由设备决定，解锁、保存及回到前台后自动补传。已有主位置的迁移需要完整复制与核对，不能直接建立第二个主位置。").font(.callout).foregroundStyle(.secondary) }
        }.formStyle(.grouped).task { await model.loadSettings() }
            .onChange(of: model.selectedID) { _, _ in Task { await model.loadSettings() } }
            .fileImporter(isPresented: $pickFolder, allowedContentTypes: [.folder]) { result in
                if case .success(let url) = result { Task { await model.setFolder(url) } }
                else if case .failure(let error) = result { model.report(error) }
            }
    }
    private func capability(_ title: String, detail: String, icon: String) -> some View {
        HStack(alignment: .top, spacing: 12) { Image(systemName: icon).foregroundStyle(.tint).frame(width: 24); VStack(alignment: .leading, spacing: 5) { Text(title).font(.headline); Text(detail).font(.callout).foregroundStyle(.secondary) } }.padding(.vertical, 5)
    }
}

struct RecoveryView: View {
    @EnvironmentObject var model: AppModel
    let onExport: () -> Void
    let onImport: () -> Void
    @State private var newPassword = ""
    @State private var repeated = ""
    var body: some View {
        Form {
            Section("完整加密备份") {
                Text("备份包含条目、附件、扩展字段和历史。恢复仍需对应的主密码或恢复密钥；备份位置不会自动参与日常同步。").foregroundStyle(.secondary)
                Button("导出当前空间的加密备份…", action: onExport).disabled(model.current == nil)
                Button("从备份恢复到本机…", action: onImport)
            }
            Section("修改主密码") {
                SecureField("新主密码（至少 12 个字符）", text: $newPassword)
                SecureField("再次输入新主密码", text: $repeated)
                Text("需要先解锁空间。已连接存储会同步更新密钥保护；其他设备需重新解锁。旧备份可能仍可用旧密码解密。").font(.caption).foregroundStyle(.secondary)
                Button("更新主密码") { let password = newPassword; newPassword = ""; repeated = ""; Task { await model.changePassword(password) } }.disabled(model.current == nil || newPassword.count < 12 || newPassword != repeated || model.busy)
            }
            Section("误删与旧版本") {
                Text("在条目详情打开“历史版本”，或打开“回收站”恢复。恢复会生成新版本并参与下一次同步，已有历史不会被覆盖。").foregroundStyle(.secondary)
                Button("查看当前空间的回收站") { model.section = model.selected?.kind == .bookmarks ? "收藏夹" : "保险库"; model.showDeleted = true }
            }
            Section("设备遗失") { Text("删除本机记录不能撤销其他设备已获得的密钥。需要轮换存储访问权限及数据密钥，并保留独立备份；本地账号可在“同步与连接”中逐台撤销。").foregroundStyle(.secondary) }
        }.formStyle(.grouped)
    }
}

struct BackupImportView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) var dismiss
    @State private var picker = false
    @State private var url: URL?
    @State private var secret = ""
    @State private var recovery = false
    var body: some View {
        NavigationStack {
            Form {
                Section("完整加密备份") {
                    Button(url?.lastPathComponent ?? "选择 .pbsync 备份文件…") { picker = true }
                    Toggle("使用恢复密钥", isOn: $recovery)
                    SecureField(recovery ? "恢复密钥" : "主密码", text: $secret)
                    Text("先校验全部密文和历史，再创建本机空间。不会覆盖现有空间或删除来源备份。").font(.caption).foregroundStyle(.secondary)
                }
            }.formStyle(.grouped).navigationTitle("从备份连接")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) { Button("恢复") {
                        if let url { Task { await model.importBackup(url: url, secret: secret, recovery: recovery); if model.error == nil { secret = ""; dismiss() } } }
                    }.disabled(url == nil || secret.isEmpty || model.busy) }
                }
        }.frame(minWidth: 360, idealWidth: 480, minHeight: 300)
            .fileImporter(isPresented: $picker, allowedContentTypes: [.data, .item]) { result in
                if case .success(let selected) = result { url = selected }
                else if case .failure(let error) = result { model.report(error) }
            }
    }
}

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        Form {
            Section("保存与填充") {
                Label("默认确认保存；默认主动触发填充", systemImage: "hand.tap")
                Text("在“同步与连接”中为指定保险库设置自动填入网站和自动保存成功页，再到扩展授权。不会自动提交登录，多账号时由你选择。").foregroundStyle(.secondary)
                Text("系统凭据填充需在设备设置中启用 PBsync 提供器。开发签名及扩展权限未完成时不显示为已启用。").foregroundStyle(.secondary)
            }
            Section("锁定与隐私") {
                Label("闲置 5 分钟后锁定；进入后台或系统锁定时锁定", systemImage: "lock")
                Label("复制的内容 30 秒后清除", systemImage: "doc.on.clipboard")
                Label("不自动上传诊断或使用记录", systemImage: "eye.slash")
                Button("立即锁定全部空间") { Task { await model.lockAll() } }
                if model.biometricConfigured {
                    Button("关闭当前空间的生物识别解锁") { model.disableBiometricUnlock() }.disabled(model.busy)
                }
            }
            Section("关于") {
                LabeledContent("版本", value: "Ver \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0") (\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "开发"))")
                Text("Mac＋iPhone 开发候选。公开云未上线；外部连接、真机、系统填充和签名发布以验收报告为准。").foregroundStyle(.secondary)
                Text("免费、开源是产品目标；正式开源许可证须在公开发布前确定。").font(.caption).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped)
    }
}
