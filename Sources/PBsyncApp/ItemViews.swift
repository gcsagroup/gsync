import SwiftUI
import UniformTypeIdentifiers
import PBsyncCore

private struct EditableField: Identifiable {
    var id = UUID(); var name: String; var value: String
}

struct ItemEditor: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) var dismiss
    @State var item: Item
    let spaceID: UUID
    let presentationID: UUID
    @State private var urls = ""
    @State private var fields: [EditableField] = []
    @State private var importAttachment = false
    @State private var reveal = false
    private var bookmark: Bool { model.current?.kind == .bookmarks }
    var body: some View {
        NavigationStack {
            Form {
                Section("基本信息") {
                    Picker("类型", selection: $item.kind) {
                        ForEach(ItemKind.allCases.filter { bookmark ? [.bookmark, .folder].contains($0) : ![.bookmark, .folder, .passkey].contains($0) }, id: \.self) { Text($0.label).tag($0) }
                        if item.kind == .passkey { Text("通行密钥").tag(ItemKind.passkey) }
                    }.disabled(item.kind == .passkey)
                    TextField("标题", text: $item.title)
                    if item.kind != .folder { TextField("网址（多条以换行分隔）", text: $urls, axis: .vertical).lineLimit(1...4) }
                    if bookmark {
                        Picker("所在文件夹", selection: $item.parentID) {
                            Text("根目录").tag(Optional<UUID>.none)
                            ForEach((model.current?.items ?? []).filter { $0.kind == .folder && $0.id != item.id }) { folder in Text(folder.title).tag(Optional(folder.id)) }
                        }
                        Stepper("排列顺序：\(item.order)", value: $item.order, in: 0...1_000_000)
                    }
                }
                if !bookmark {
                    Section("\(item.kind.label)内容") {
                        if [.login, .totp].contains(item.kind) {
                            TextField("用户名", text: field("username"))
                            if item.kind == .login {
                                HStack {
                                    if reveal { TextField("密码", text: field("password")) } else { SecureField("密码", text: field("password")) }
                                    Button { reveal.toggle() } label: { Image(systemName: reveal ? "eye.slash" : "eye") }.buttonStyle(.borderless)
                                    Button("生成") { do { item.fields["password"] = try Crypto.random(24).base64EncodedString() } catch { model.report(error) } }.buttonStyle(.borderless)
                                }
                            }
                            SecureField("验证码密钥或 otpauth 地址（可选）", text: field("totp"))
                        } else if item.kind == .card {
                            TextField("持卡人", text: field("cardholder")); TextField("卡号", text: field("number")); TextField("有效期", text: field("expiry")); SecureField("安全码", text: field("cvv"))
                        } else if item.kind == .identity {
                            TextField("姓名", text: field("name")); TextField("证件类型", text: field("documentType")); SecureField("证件号码", text: field("documentNumber")); TextField("地址", text: field("address"), axis: .vertical)
                        } else if item.kind == .recoveryCodes { TextField("恢复码（每行一条）", text: field("codes"), axis: .vertical).lineLimit(4...10) }
                        else if item.kind == .passkey { Text("通行密钥由系统凭据入口创建和使用。修改标题、备注不会更改密钥。").font(.caption).foregroundStyle(.secondary) }
                        TextField("备注", text: $item.notes, axis: .vertical).lineLimit(3...8)
                    }
                    Section("自定义字段") {
                        ForEach($fields) { $entry in
                            HStack { TextField("名称", text: $entry.name); SecureField("内容", text: $entry.value); Button { fields.removeAll { $0.id == entry.id } } label: { Image(systemName: "minus.circle") }.buttonStyle(.borderless) }
                        }
                        Button("添加字段") { fields.append(EditableField(name: "", value: "")) }
                    }
                    Section("附件 · 每个文件最多 10 MB") {
                        ForEach(item.attachments) { attachment in
                            HStack { Label(attachment.name, systemImage: "paperclip"); Spacer(); Text(ByteCountFormatter.string(fromByteCount: Int64(attachment.remoteSize ?? attachment.data.count), countStyle: .file)).foregroundStyle(.secondary); Button { item.attachments.removeAll { $0.id == attachment.id } } label: { Image(systemName: "minus.circle") }.buttonStyle(.borderless) }
                        }
                        Button("添加附件") { importAttachment = true }
                    }
                }
            }.formStyle(.grouped).navigationTitle(item.title.isEmpty ? "新增条目" : "编辑条目")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) { Button("保存") { save() }.disabled(item.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.busy) }
                }
        }.frame(minWidth: 360, idealWidth: 580, minHeight: 520)
            .onReceive(model.$sensitivePresentationID.dropFirst()) { _ in
                item = Item(kind: .login, title: ""); urls = ""; fields = []; reveal = false
            }
            .onAppear {
                urls = item.urls.joined(separator: "\n")
                fields = item.fields.filter { $0.key.hasPrefix("custom.") }.sorted { $0.key < $1.key }.map { EditableField(name: String($0.key.dropFirst(7)), value: $0.value) }
            }
            .fileImporter(isPresented: $importAttachment, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
                if case .success(let urls) = result {
                    for url in urls {
                        let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
                        do {
                            guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= 10 * 1024 * 1024 else { throw PBError.invalid("附件超过 10 MB。") }
                            item.attachments.append(try Attachment(name: url.lastPathComponent, data: Data(contentsOf: url)))
                        } catch { model.report(error) }
                    }
                }
            }
    }
    private func field(_ name: String) -> Binding<String> { Binding(get: { item.fields[name] ?? "" }, set: { item.fields[name] = $0 }) }
    private func save() {
        item.urls = urls.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        if item.kind == .bookmark && (item.urls.count != 1 || !CredentialPolicy.safeBookmarkURL(item.urls[0])) { model.report(PBError.invalid("收藏需要一个有效的 HTTP／HTTPS 网址。")); return }
        if let seed = item.fields["totp"], !seed.isEmpty {
            do { let configuration = try seed.hasPrefix("otpauth:") ? OTPConfiguration(uri: seed) : OTPConfiguration(secret: seed); _ = try configuration.code() }
            catch { model.report(error); return }
        }
        let names = fields.map { $0.name.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard !names.contains(""), Set(names).count == names.count else { model.report(PBError.invalid("自定义字段名称不能为空或重复。")); return }
        item.fields = item.fields.filter { !$0.key.hasPrefix("custom.") }
        for (name, value) in zip(names, fields.map(\.value)) { item.fields["custom." + name] = value }
        if let parent = item.parentID {
            var cursor: UUID? = parent; var visited: Set<UUID> = [item.id]
            while let id = cursor {
                guard !visited.contains(id) else { model.report(PBError.invalid("不能把文件夹放入自身的下级目录。")); return }
                visited.insert(id); cursor = model.current?.current[id]?.item.parentID
            }
        }
        Task { await model.save(item, spaceID: spaceID, presentationID: presentationID); if model.error == nil { dismiss() } }
    }
}

struct ItemDetail: View {
    @EnvironmentObject var model: AppModel
    let item: Item
    var actions: AnyView? = nil
    @State private var reveal = false
    @State private var showHistory = false
    @State private var exportAttachment = false
    @State private var attachmentDocument = ExportDocument(data: Data())
    @State private var attachmentName = "附件"
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(item.title).font(.title3.bold())
                    Spacer()
                    actions
                    Button("历史版本") { showHistory = true }
                }
                if let website = item.urls.first, !website.isEmpty { valueRow("网站", value: website, secret: false) }
                if let username = item.fields["username"], !username.isEmpty { valueRow("用户名", value: username, secret: false) }
                if let password = item.fields["password"], !password.isEmpty { valueRow("密码", value: password, secret: true) }
                #if os(macOS)
                if item.kind != .folder && item.kind != .bookmark {
                    let source = VaultItemSource(item)
                    LabeledContent("来源", value: source.rawValue)
                    Label(source.writeback, systemImage: "info.circle").font(.caption).foregroundStyle(.secondary)
                }
                #endif
                if let totp = item.fields["totp"], !totp.isEmpty {
                    TimelineView(.periodic(from: .now, by: 1)) { timeline in
                        let code = otp(totp, at: timeline.date)
                        HStack { Text("验证码").foregroundStyle(.secondary); Text(code).font(.system(.title3, design: .monospaced)).bold(); Button("复制") { model.copy(code) } }
                    }
                }
                ForEach(item.fields.keys.filter { !["password", "username", "totp", "importSource", "unsafeURL"].contains($0) }.sorted(), id: \.self) { key in
                    valueRow(fieldLabel(key), value: item.fields[key] ?? "", secret: true)
                }
                if !item.notes.isEmpty { Text(item.notes).font(.callout).textSelection(.enabled) }
                ForEach(item.attachments) { attachment in
                    Button {
                        let epoch = model.sensitivePresentationID, id = model.selectedID
                        Task { do {
                            let bytes = try await model.selectedStore().attachmentBytes(attachment, storage:model.configuredStorage())
                            guard epoch == model.sensitivePresentationID, id == model.selectedID, model.current != nil else { return }
                            attachmentDocument = ExportDocument(data: bytes); attachmentName = URL(fileURLWithPath: attachment.name).lastPathComponent; exportAttachment = true
                        } catch { model.report(error) } }
                    } label: { Label("导出附件：\(attachment.name)", systemImage: "paperclip") }
                }
                if !item.sourceData.isEmpty { Text("已加密保留来源扩展字段；完整备份会包含这些内容。").font(.caption).foregroundStyle(.secondary) }
            }.padding(20)
        }.onReceive(model.$sensitivePresentationID.dropFirst()) { _ in
            reveal = false; showHistory = false; exportAttachment = false
            attachmentDocument = ExportDocument(data: Data())
        }.sheet(isPresented: $showHistory) { HistoryView(itemID: item.id).environmentObject(model) }
            .fileExporter(isPresented: $exportAttachment, document: attachmentDocument, contentType: .data, defaultFilename: attachmentName) { result in
                attachmentDocument = ExportDocument(data: Data())
                if case .failure(let error) = result { model.report(error) } }
    }
    private func valueRow(_ label: String, value: String, secret: Bool) -> some View {
        HStack(alignment: .top) {
            Text(label).foregroundStyle(.secondary).frame(width: 85, alignment: .leading)
            Text(secret && !reveal ? "••••••••••••" : value).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
            Spacer()
            if secret { Button { reveal.toggle(); model.touch() } label: { Image(systemName: reveal ? "eye.slash" : "eye") }.buttonStyle(.borderless) }
            Button { model.copy(value) } label: { Image(systemName: "doc.on.doc") }.buttonStyle(.borderless).help("复制，30 秒后清除")
        }
    }
    private func fieldLabel(_ key: String) -> String {
        ["cardholder": "持卡人", "number": "卡号", "expiry": "有效期", "cvv": "安全码", "name": "姓名", "documentType": "证件类型", "documentNumber": "证件号码", "address": "地址", "codes": "恢复码"][key] ?? key.replacingOccurrences(of: "custom.", with: "")
    }
    private func otp(_ value: String, at date: Date) -> String {
        do { let configuration = try value.hasPrefix("otpauth:") ? OTPConfiguration(uri: value) : OTPConfiguration(secret: value); return try configuration.code(at: date.timeIntervalSince1970) }
        catch { return "密钥无效" }
    }
}

struct HistoryView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) var dismiss
    let itemID: UUID
    var body: some View {
        NavigationStack {
            List(model.current?.history(for: itemID) ?? []) { revision in
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(revision.deleted ? "移至回收站" : revision.item.title).font(.headline)
                        Text(Date(timeIntervalSince1970: Double(revision.time.milliseconds) / 1000), style: .date).font(.caption)
                        Text(Date(timeIntervalSince1970: Double(revision.time.milliseconds) / 1000), style: .time).font(.caption).foregroundStyle(.secondary)
                    }; Spacer()
                    Button("恢复此版本") { Task { await model.restore(revision); if model.error == nil { dismiss() } } }
                }.padding(.vertical, 6)
            }.navigationTitle("历史与恢复")
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }.frame(minWidth: 360, idealWidth: 520, minHeight: 380)
    }
}
