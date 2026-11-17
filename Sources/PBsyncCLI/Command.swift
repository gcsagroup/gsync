import Foundation
import PBsyncCore
#if os(macOS)
import Darwin
#endif

@main struct PBsyncCommand {
    static func main() async {
        do { try await run() }
        catch {
            let message = (error as? PBError)?.localizedDescription ?? "操作失败，请检查输入文件、权限和连接。"
            FileHandle.standardError.write(Data((message + "\n").utf8)); exit(1)
        }
    }
    static func run() async throws {
        let args = Array(CommandLine.arguments.dropFirst())
        let command = args.first ?? "help"
        func option(_ name: String) -> String? { guard let i = args.firstIndex(of: "--" + name), args.count > i + 1 else { return nil }; return args[i + 1] }
        func required(_ name: String) throws -> String { guard let value = option(name) else { throw PBError.invalid("缺少 --\(name) 参数。") }; return value }
        func secret(_ name: String = "password") throws -> String {
            if let path = option(name + "-file") { return try String(contentsOfFile: path, encoding: .utf8).trimmingCharacters(in: .newlines) }
            if let value = ProcessInfo.processInfo.environment["PBSYNC_" + name.uppercased().replacingOccurrences(of: "-", with: "_")] { return value }
            #if os(macOS)
            if isatty(STDIN_FILENO) != 0, let value = getpass("请输入解锁材料（不回显）：") { return String(cString: value) }
            #endif
            throw PBError.invalid("请通过 --\(name)-file、受控环境变量或交互终端提供秘密；不要把秘密放入命令参数。")
        }
        func output<T: Encodable>(_ value: T) throws { FileHandle.standardOutput.write(try Coding.encode(value) + Data([10])) }
        if command == "help" {
            print("""
            PBsync 本地开发工具
              create --file PATH --kind bookmarks|vault --name NAME --recovery-out PATH
              inspect --file PATH
              import --file PATH --input PATH --format html|safari-zip|csv|connector
              export --file PATH --output PATH --format archive|html|safari-zip|csv
              sync --file PATH --folder PATH
              sync --file PATH --url HTTPS_URL --username USER --storage-secret-file PATH
              connect --file NEW_PATH --folder PATH
              migrate --file PATH --url SOURCE_URL --username USER --destination-folder EMPTY --new-password-file PATH --recovery-out PATH
              native-host --profile PATH --caller ORIGIN
              inspect-native-bookmarks --pid PID [--request-permission]（Mac 原生只读核对）
            主密码通过 --password-file、PBSYNC_PASSWORD 或终端输入。CSV 明文导出须另加 --allow-plaintext。
            """); return
        }
        #if os(macOS)
        if command == "inspect-native-bookmarks" {
            guard let pid = Int32(try required("pid")), pid > 0 else { throw PBError.invalid("浏览器进程号无效。") }
            try output(MacBookmarkReader.inspect(pid:pid, requestPermission:args.contains("--request-permission")))
            return
        }
        if command == "native-host" {
            let root = try option("profile").map { URL(fileURLWithPath: $0) } ?? AppPaths.root()
            let caller = try required("caller")
            let allowedURL = root.appendingPathComponent("allowed-native-callers.json")
            let allowed = try Coding.decode([String].self, from: Data(contentsOf: allowedURL))
            guard allowed.contains(caller) else { throw PBError.unauthorized }
            while true {
                guard let header = try FileHandle.standardInput.read(upToCount: 4), !header.isEmpty else { return }
                guard header.count == 4 else { throw PBError.damaged }
                let count = header.enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element) << ($1.offset * 8) }
                guard count > 0, count <= 1_048_576 else { throw PBError.damaged }
                var data = Data()
                while data.count < count {
                    guard let part = try FileHandle.standardInput.read(upToCount: Int(count) - data.count), !part.isEmpty else { throw PBError.damaged }; data += part
                }
                let response: Data
                // 本地写回只处理调用浏览器自己的书签。空间数据仍走原有的认证加密通道。
                if let message = try? JSONSerialization.jsonObject(with: data) as? [String:Any],
                   let route = message["nativeBookmarkRoute"] as? String {
                    var outcome = "fallback"
                    if let path = option("bookmark-profile"), caller.hasPrefix("chrome-extension://") {
                        if route == "available" { outcome = "available" }
                        else if route == "authorize" {
                            let status = MacBookmarkWriter.requestAccess(browserPID:getppid())
                            outcome = status == 0 ? "available" : "fallback:系统权限 \(status)"
                        }
                        else if route == "write", let body = message["request"],
                                let bytes = try? JSONSerialization.data(withJSONObject:body),
                                let request = try? JSONDecoder().decode(MacBookmarkWriter.Request.self,from:bytes) {
                            outcome = MacBookmarkWriter.perform(request,profile:URL(fileURLWithPath:path),browserPID:getppid())
                        }
                    }
                    let parts = outcome.split(separator:":",maxSplits:1).map(String.init)
                    response = try Coding.encode(["outcome":parts[0],"reason":parts.count > 1 ? parts[1] : ""])
                } else { response = try NativeBridgeServer.send(data, root: root) }
                var length = UInt32(response.count).littleEndian
                FileHandle.standardOutput.write(withUnsafeBytes(of: &length) { Data($0) }); FileHandle.standardOutput.write(response)
            }
        }
        #endif
        let file = URL(fileURLWithPath: try required("file")), device = try AppPaths.deviceID(at: file.deletingLastPathComponent())
        func storage() throws -> any ObjectStorage {
            if let folder = option("folder") { let url = URL(fileURLWithPath: folder, isDirectory: true); try SafeFile.privateDirectory(url); return FolderStorage(directory: url) }
            guard let url = URL(string: try required("url")) else { throw PBError.invalid("存储地址无效。") }
            if args.contains("--cloud") { return try WebDAVStorage(localCloudURL: url, token: secret("storage-secret")) }
            return try WebDAVStorage(url: url, username: option("username") ?? "", password: secret("storage-secret"))
        }
        if command == "create" {
            guard let kind = SpaceKind(rawValue: try required("kind")) else { throw PBError.invalid("空间类型无效。") }
            let recoveryPath = URL(fileURLWithPath: try required("recovery-out"))
            guard !FileManager.default.fileExists(atPath: recoveryPath.path), recoveryPath.standardizedFileURL != file.standardizedFileURL else { throw PBError.conflict }
            let (_, recovery) = try VaultStore.create(fileURL: file, name: option("name") ?? "测试空间", kind: kind, password: secret(), deviceID: device)
            try SafeFile.write(Data(recovery.utf8), to: recoveryPath); try output(["created": true]); return
        }
        if command == "connect" {
            let store = try await VaultStore.connect(storage: storage(), fileURL: file, password: secret(), deviceID: device)
            let state = try await store.snapshot(); try output(["items": state.items.count, "revisions": state.revisions.count]); return
        }
        let store = try VaultStore(fileURL: file, deviceID: device)
        if args.contains("--recovery") { try await store.recover(secret: secret("recovery")) }
        else { try await store.unlock(password: secret()) }
        switch command {
        case "inspect":
            let state = try await store.snapshot(); try output(["items": state.items.count, "revisions": state.revisions.count, "deleted": state.current.values.filter(\.deleted).count])
        case "import":
            let input = try Data(contentsOf: URL(fileURLWithPath: required("input"))), format = try required("format")
            let preview: ImportPreview
            if format == "html" || format == "safari-zip" { preview = try SafariBookmarks.preview(input) }
            else if format == "csv" { preview = try PasswordCSV.parse(input) }
            else if format == "connector" { preview = try ConnectorImport.parse(input) }
            else { throw PBError.unsupported }
            let count = try await store.importItems(preview.items); try output(["changed": count, "warnings": preview.warnings.count])
        case "export":
            let format = option("format") ?? "archive", data: Data
            if format == "archive" { data = try await store.exportArchive(storage:(option("folder") != nil || option("url") != nil) ? storage() : nil) }
            else if format == "safari-zip" { data = try SafariBookmarks.export(await store.snapshot()) }
            else if format == "html" { data = try BookmarkHTML.export(await store.snapshot()) }
            else if format == "csv", args.contains("--allow-plaintext") { data = try PasswordCSV.export(await store.snapshot()) }
            else { throw PBError.invalid("不支持的格式，或未确认明文导出。") }
            let url = URL(fileURLWithPath: try required("output"))
            guard !FileManager.default.fileExists(atPath: url.path) else { throw PBError.conflict }
            try SafeFile.write(data, to: url); try output(["exported": true])
        case "migrate":
            let destination = URL(fileURLWithPath:try required("destination-folder"),isDirectory:true)
            let receipt = URL(fileURLWithPath:try required("recovery-out"))
            guard !FileManager.default.fileExists(atPath:receipt.path) else { throw PBError.conflict }
            try SafeFile.privateDirectory(destination)
            let recovery = try await store.migrate(from:storage(),to:FolderStorage(directory:destination),newPassword:secret("new-password"))
            try SafeFile.write(Data(recovery.utf8),to:receipt); try output(["migrated":true])
        case "sync":
            let result = try await store.synchronize(with: storage()); try output(["downloaded": result.downloaded, "uploaded": result.uploaded, "pending": result.pending])
        default: throw PBError.invalid("未知命令，请运行 pbsync help。")
        }
        await store.lock()
    }
}
