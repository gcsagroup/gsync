import Foundation

public enum AppPaths {
    public static let group = "group.com.gcsa.pbsync"
    public static func root() throws -> URL {
        #if os(macOS)
        let args = ProcessInfo.processInfo.arguments
        if let index = args.firstIndex(of: "--profile"), args.count > index + 1 {
            let url = URL(fileURLWithPath: args[index + 1], isDirectory: true)
            try SafeFile.privateDirectory(url); return url
        }
        #endif
        if Bundle.main.object(forInfoDictionaryKey: "PBsyncSharedContainer") as? Bool == true {
            guard let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) else { throw PBError.invalid("共享容器尚未获签名授权，无法启用系统凭据提供器。") }
            let root = url.appendingPathComponent("PBsync", isDirectory: true); try SafeFile.privateDirectory(root); return root
        }
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("GCSA-PBsync", isDirectory: true)
        try SafeFile.privateDirectory(root); return root
    }
    public static func deviceID(at root: URL) throws -> UUID {
        let path = root.appendingPathComponent("device-id")
        return try SafeFile.withLock(at: root.appendingPathComponent(".device-lock")) {
            if let data = try? Data(contentsOf: path), let text = String(data: data, encoding: .utf8), let id = UUID(uuidString: text) { return id }
            let id = UUID(); try SafeFile.write(Data(id.uuidString.utf8), to: path); return id
        }
    }
}

public struct CatalogEntry: Codable, Identifiable, Sendable {
    public var id: UUID
    public var filename: String
    public var kind: SpaceKind
    public init(id: UUID, filename: String, kind: SpaceKind) { self.id = id; self.filename = filename; self.kind = kind }
}

public enum Catalog {
    public static func read(at root: URL) throws -> [CatalogEntry] {
        let path = root.appendingPathComponent("catalog.json")
        guard FileManager.default.fileExists(atPath: path.path) else { return [] }
        let entries = try Coding.decode([CatalogEntry].self, from: Data(contentsOf: path))
        guard entries.allSatisfy({ $0.filename == $0.id.uuidString.lowercased() + ".pbsync" }), Set(entries.map(\.id)).count == entries.count else { throw PBError.damaged }
        return entries
    }
    public static func add(_ entry: CatalogEntry, at root: URL) throws {
        try SafeFile.withLock(at: root.appendingPathComponent(".catalog-lock")) {
            var entries = try read(at: root)
            guard !entries.contains(where: { $0.id == entry.id }) else { throw PBError.conflict }
            entries.append(entry); try SafeFile.write(Coding.encode(entries), to: root.appendingPathComponent("catalog.json"))
        }
    }
}
