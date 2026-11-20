#if os(macOS)
import SwiftUI
import UniformTypeIdentifiers
import PBsyncCore

struct ExternalLink: Identifiable, Codable, Sendable {
    var id = UUID()
    var kind: String
    var file: Data?
    var originalPath: String?
    var keyFile: Data?
    var account = ""
    var vault = ""
    var source = ""
    var initialDigest: String?
    var enabled = true
    var label: String

    static func saved(account: String, allowInteraction: Bool) throws -> [Self] {
        try Keychain.read(account: account, allowInteraction: allowInteraction)
            .map { try Coding.decode([Self].self, from: $0) } ?? []
    }
}

enum SourceTool {
    static func run(_ args: [String], password: String, account: String, patches: [[String:String]] = []) async throws -> Data {
        guard let helper = Bundle.main.url(forResource:"pbsync-connector",withExtension:nil),
              FileManager.default.isExecutableFile(atPath:helper.path) else { throw PBError.invalid("安装包缺少桌面连接器，请重新安装完整的 Mac App。") }
        let input = try JSONSerialization.data(withJSONObject:["password":password,"patch":patches])
        return try await Task.detached {
            let task = Process(), output = Pipe(), stdin = Pipe()
            task.executableURL = helper
            task.arguments = args + ["--request-stdin"]
            task.environment = ["PATH":"/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin","PBSYNC_OP_ACCOUNT":account]
            task.standardOutput = output; task.standardInput = stdin; task.standardError = FileHandle.nullDevice
            try task.run()
            let timeout = DispatchWorkItem { if task.isRunning { task.terminate() } }
            DispatchQueue.global().asyncAfter(deadline:.now()+90,execute:timeout)
            defer { timeout.cancel(); try? output.fileHandleForReading.close() }
            DispatchQueue.global().async {
                try? stdin.fileHandleForWriting.write(contentsOf:input)
                try? stdin.fileHandleForWriting.close()
            }
            var data = Data()
            while let chunk = try output.fileHandleForReading.read(upToCount:65_536), !chunk.isEmpty {
                guard data.count + chunk.count <= 128*1024*1024 else { task.terminate(); throw PBError.invalid("来源响应超过大小上限。") }
                data.append(chunk)
            }
            task.waitUntilExit()
            guard task.terminationStatus == 0 else { throw PBError.invalid("来源读取或候选校验失败，请核对来源授权、文件和解锁材料后重试。") }
            return data
        }.value
    }

    static func file(_ bookmark: Data?) throws -> URL {
        guard let bookmark else { throw PBError.unauthorized }
        var stale = false
        let url = try URL(resolvingBookmarkData:bookmark,options:[.withSecurityScope,.withoutUI],relativeTo:nil,bookmarkDataIsStale:&stale)
        guard !stale else { throw PBError.unauthorized }
        return url
    }
    static func read(_ link: ExternalLink, password: String, patches: [[String:String]] = [], baseline: String? = nil) async throws -> Data {
        if link.kind == "op" {
            guard !link.account.isEmpty, !link.vault.isEmpty, baseline == nil else { throw PBError.unauthorized }
            return try await run(["op-read","--vault",link.vault],password:"",account:link.account)
        }
        let url: URL
        if let resolved = try? file(link.file) {
            url = resolved
        } else {
            // KeePassXC 使用原子替换。只尝试已选的原路径，拒绝符号链接，仍需核对库 UUID。
            guard let path = link.originalPath, path.hasPrefix("/") else { throw PBError.unauthorized }
            let original = URL(fileURLWithPath:path).standardizedFileURL
            guard original.resolvingSymlinksInPath().path == original.path else { throw PBError.unauthorized }
            url = original
        }
        let key = try link.keyFile.map { try file($0) }
        let access = url.startAccessingSecurityScopedResource(), keyAccess = key?.startAccessingSecurityScopedResource() == true
        defer { if access { url.stopAccessingSecurityScopedResource() }; if keyAccess { key?.stopAccessingSecurityScopedResource() } }
        // 网盘尚未挂载或来源正在原子替换时，等待下一次检查，不撤销已有连接。
        for file in [url] + (key.map { [$0] } ?? []) {
            guard FileManager.default.fileExists(atPath: file.path) else { throw PBError.unavailable }
            guard FileManager.default.isReadableFile(atPath: file.path) else { throw PBError.unauthorized }
        }
        var args = [baseline == nil ? "kdbx-read" : "kdbx-write","--input",url.path]
        if let key { args += ["--keyfile",key.path] }
        if let baseline { args += ["--expected",baseline] }
        return try await run(args,password:password,account:"",patches:patches)
    }
}

struct FileVaultChoice: Identifiable, Decodable {
    let id: String
    let name: String
    let count: Int
}
struct FileVaultSelection: Identifiable {
    let id = UUID()
    let url: URL
    let target: UUID
    let session: String
    let choices: [FileVaultChoice]
}
struct FileVaultList: Decodable { let vaults: [FileVaultChoice] }

@MainActor extension AppModel {
    func preview1PUX(_ url: URL, target: UUID, vault: String? = nil) async throws {
        let session = spaceSession(target)
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let arguments = ["1pux","--input",url.path] + (vault.map { ["--vault",$0] } ?? ["--list-vaults"])
        let data = try await SourceTool.run(arguments,password:"",account:"")
        guard selectedID == target, current?.kind == .vault, spaceSession(target) == session else { throw PBError.locked }
        if vault == nil {
            let choices = try Coding.decode(FileVaultList.self,from:data).vaults
            guard !choices.isEmpty, Set(choices.map(\.id)).count == choices.count else { throw PBError.damaged }
            fileVaultSelection = FileVaultSelection(url:url,target:target,session:session,choices:choices)
        } else {
            preview = try ConnectorImport.parse(data)
            importTarget = target
        }
    }
    func linkKey(_ id: UUID) -> String { Crypto.digest(Data(root.path.utf8)) + ".sources." + id.uuidString }
    func links(_ id: UUID, allowInteraction: Bool = true) throws -> [ExternalLink] {
        try ExternalLink.saved(account:linkKey(id), allowInteraction:allowInteraction)
    }
    func storeLinks(_ links: [ExternalLink], _ id: UUID, allowInteraction: Bool = true) throws {
        try Keychain.save(Coding.encode(links),account:linkKey(id),allowInteraction:allowInteraction)
        externalEpoch += 1
    }
    func registerLink(_ link: ExternalLink, password: String, target: UUID, session: String) async throws -> (ExternalLink,SourceChanges) {
        guard let store = stores[target], states[target]?.kind == .vault, selectedID == target else { throw PBError.locked }
        let data = try await SourceTool.read(link,password:password)
        let preview = try ConnectorImport.parse(data)
        guard spaceSession(target) == session, selectedID == target, states[target] != nil else { throw PBError.locked }
        guard !(try links(target)).contains(where: { $0.source == preview.source }) else { throw PBError.conflict }
        var bound = link; bound.source = preview.source
        bound.initialDigest = Crypto.digest(try Coding.encode(preview.items))
        return (bound,try await store.reconcileSource(preview,apply:false))
    }
    func activateLink(_ link: ExternalLink, password: String, target: UUID, session: String) async throws {
        guard target == selectedID, states[target]?.kind == .vault, spaceSession(target) == session else { throw PBError.locked }
        var current = try links(target)
        guard !current.contains(where: { $0.source == link.source }) else { throw PBError.conflict }
        current.append(link)
        try Keychain.save(Data(password.utf8),account:linkKey(target)+link.id.uuidString)
        do { try storeLinks(current,target) }
        catch { try? Keychain.remove(account:linkKey(target)+link.id.uuidString); throw error }
        await refreshLink(link,target:target)
    }
    func removeLink(_ link: ExternalLink, target: UUID) throws {
        try storeLinks(links(target).filter { $0.id != link.id },target)
        try Keychain.remove(account:linkKey(target)+link.id.uuidString)
        externalStatus[link.id] = nil
    }
    func pollSourceLinks() {
        for (target,state) in states where state.kind == .vault {
            guard let links = try? links(target, allowInteraction:false) else { continue }
            for link in links where link.enabled && !externalBusy.contains(link.id) {
                Task { await refreshLink(link,target:target,allowInteraction:false) }
            }
        }
    }
    func refreshLink(_ link: ExternalLink, target: UUID, candidate: Bool = false, allowInteraction: Bool = true) async {
        guard let store = stores[target], states[target]?.kind == .vault, externalBusy.insert(link.id).inserted else { return }
        defer { externalBusy.remove(link.id) }
        let session = spaceSession(target)
        func valid() throws {
            guard states[target]?.kind == .vault, spaceSession(target) == session,
                  try links(target, allowInteraction:allowInteraction).contains(where:{ $0.id == link.id }) else { throw PBError.locked }
        }
        do {
            try valid()
            let password = try Keychain.read(account:linkKey(target)+link.id.uuidString, allowInteraction:allowInteraction)
                .flatMap { String(data:$0,encoding:.utf8) } ?? ""
            let data = try await SourceTool.read(link,password:password)
            let preview = try ConnectorImport.parse(data)
            try valid()
            guard preview.source == link.source else { throw PBError.invalid("来源库身份已变更，连接已暂停。") }
            if let expected = link.initialDigest, try Crypto.digest(Coding.encode(preview.items)) != expected { throw PBError.invalid("来源在预览后发生变化，请断开并重新预览。") }
            let result = try await store.reconcileSource(preview,apply:!candidate)
            try valid()
            if result.imported > 0 && !candidate { try await refresh(target,userActivity:false); requestSync(target) }
            var message = "更新 \(result.imported) 项，待写回 \(result.patches.count) 项，冲突 \(result.conflicts) 项，来源缺失 \(result.missing) 项，受限 \(result.unsupported) 项"
            if candidate && !result.patches.isEmpty {
                guard link.kind == "kdbx", let obj = try JSONSerialization.jsonObject(with:data) as? [String:Any],
                      let digest = obj["baseline"] as? String else { throw PBError.invalid("此来源只允许读取和核对候选。") }
                let reply = try await SourceTool.read(link,password:password,patches:result.patches,baseline:digest)
                try valid()
                guard let record = try JSONSerialization.jsonObject(with:reply) as? [String:Any], record["applied"] as? Bool == false,
                      let path = record["candidate"] as? String else { throw PBError.damaged }
                message += "。候选：" + URL(fileURLWithPath:path).lastPathComponent
                if record["sourceChanged"] as? Bool == true { message += "（生成期间来源已变更，请重新核对）" }
            }
            var configs = try links(target, allowInteraction:allowInteraction)
            if let index = configs.firstIndex(where:{$0.id == link.id}), (!configs[index].enabled || configs[index].initialDigest != nil) {
                configs[index].enabled = true; configs[index].initialDigest = nil
                try storeLinks(configs,target,allowInteraction:allowInteraction)
            }
            externalStatus[link.id] = message
        } catch {
            guard states[target] != nil, spaceSession(target) == session else { return }
            if (error as? PBError) == .unavailable {
                externalStatus[link.id] = link.enabled ? "来源暂不可用 · 本地密码已保留，恢复后自动重试" :
                    "来源暂不可用 · 本地密码已保留，请恢复来源后重新读取"
                return
            }
            do {
                var configs = try links(target, allowInteraction:allowInteraction)
                if let i = configs.firstIndex(where:{$0.id == link.id}) {
                    configs[i].enabled = false
                    try storeLinks(configs,target,allowInteraction:allowInteraction)
                }
            } catch {
                if allowInteraction { report(error) }
            }
            externalStatus[link.id] = (error as? PBError)?.localizedDescription ?? "来源暂不可用，已暂停自动读取。"
        }
    }
}

struct ExternalSourceView: View {
    @EnvironmentObject var model: AppModel
    @State private var kind = "kdbx"
    @State private var account = ""
    @State private var vault = ""
    @State private var password = ""
    @State private var file: URL?
    @State private var key: URL?
    @State private var pick = false
    @State private var pickingKey = false
    @State private var pending: (ExternalLink,UUID,String,String,Int)?
    @State private var working = false
    @State private var savedLinks: [ExternalLink]?
    @State private var loadingLinks = false
    @State private var sourceAuthorizationNeeded = false
    var body: some View {
        Section("连接外部保险库") {
            if let target = model.selectedID, model.states[target]?.kind == .vault {
                if let savedLinks {
                    ForEach(savedLinks) { link in
                            VStack(alignment:.leading) {
                                Text(link.label).bold()
                                Text(model.externalBusy.contains(link.id) ? "正在读取或校验…" :
                                    (model.externalStatus[link.id] ?? (link.enabled ? "已配置读取" : "读取已暂停"))).font(.caption)
                                HStack {
                                    Button("重新读取") { Task { await model.refreshLink(link,target:target) } }
                                        .disabled(model.externalBusy.contains(link.id))
                                    if link.kind == "kdbx" {
                                        Button("生成写回候选") { Task { await model.refreshLink(link,target:target,candidate:true) } }
                                            .disabled(model.externalBusy.contains(link.id))
                                    }
                                    Button("断开") { do { try model.removeLink(link,target:target) } catch { model.report(error) } }
                                }
                            }
                    }
                    Picker("来源",selection:$kind) { Text("KeePass 文件").tag("kdbx"); Text("1Password CLI").tag("op") }
                    if kind == "kdbx" {
                        Button(file?.lastPathComponent ?? "选择 KDBX 文件") { pickingKey = false; pick = true }
                        Button(key?.lastPathComponent ?? "选择可选密钥文件") { pickingKey = true; pick = true }
                        if key != nil { Button("清除密钥文件选择") { key = nil } }
                        SecureField("KDBX 主密码",text:$password)
                    } else { TextField("1Password 账户标识",text:$account); TextField("已授权的来源库 ID",text:$vault) }
                    Button("预览来源连接") {
                        let session = model.spaceSession(target), secret = password
                        working = true
                        Task {
                            defer { working = false }
                            do {
                                var link = ExternalLink(kind:kind,account:account,vault:vault,label:kind == "op" ? vault : (file?.lastPathComponent ?? "KDBX"))
                                if kind == "kdbx" {
                                    guard let file else { throw PBError.invalid("请选择来源文件。") }
                                    link.originalPath = file.standardizedFileURL.path; link.file = try bookmark(file); link.keyFile = try key.map(bookmark)
                                }
                                let (bound,result) = try await model.registerLink(link,password:secret,target:target,session:session)
                                pending = (bound,target,session,secret,result.imported)
                            } catch { model.report(error) }
                        }
                    }.disabled(working || (kind == "kdbx" ? file == nil : account.isEmpty || vault.isEmpty))
                    if let draft = pending {
                        Text("导入或更新 \(draft.4) 项到当前保险库").font(.caption)
                        Button("确认连接此来源") {
                            pending = nil; password = ""; working = true
                            Task {
                                defer { working = false }
                                do { try await model.activateLink(draft.0,password:draft.3,target:draft.1,session:draft.2) } catch { model.report(error) }
                            }
                        }.disabled(working)
                    }
                } else if sourceAuthorizationNeeded {
                    Button("恢复来源钥匙串授权") { Task { await loadLinks(target: target, allowInteraction: true) } }
                        .disabled(loadingLinks)
                } else {
                    ProgressView().controlSize(.small)
                }
            } else { Text("请选择并解锁要接收条目的保险库。") }
        }
        .task(id: (model.selectedID.map(model.spaceSession) ?? "") + "|\(model.externalEpoch)") {
            guard let target = model.selectedID, model.states[target]?.kind == .vault else { savedLinks = nil; return }
            await loadLinks(target: target, allowInteraction: false)
        }
        .onChange(of:model.selectedID) { _,_ in pending=nil;password="";file=nil;key=nil;savedLinks=nil;sourceAuthorizationNeeded=false }
        .onChange(of:model.sensitivePresentationID) { _,_ in pending=nil;password="";file=nil;key=nil;savedLinks=nil;sourceAuthorizationNeeded=false }
        .onChange(of:kind) { _,_ in pending=nil }
        .fileImporter(isPresented:$pick,allowedContentTypes:[.data]) { result in
            do { let url = try result.get(); if pickingKey { key=url } else { file=url }; pending=nil }
            catch { model.report(error) }
        }
    }
    private func loadLinks(target: UUID, allowInteraction: Bool) async {
        let session = model.spaceSession(target), account = model.linkKey(target)
        loadingLinks = true
        defer { loadingLinks = false }
        let result = await Task.detached {
            Result { try ExternalLink.saved(account: account, allowInteraction: allowInteraction) }
        }.value
        guard !Task.isCancelled, model.selectedID == target, model.spaceSession(target) == session else { return }
        switch result {
        case .success(let links):
            savedLinks = links
            sourceAuthorizationNeeded = false
            if allowInteraction { model.externalEpoch += 1 }
        case .failure:
            savedLinks = nil
            sourceAuthorizationNeeded = true
        }
    }
    private func bookmark(_ url: URL) throws -> Data {
        let access=url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        return try StorageConfiguration.bookmark(for:url)
    }
}
#endif
