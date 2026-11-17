import Foundation

/// 输入、输出分开，避免把自己刚导出的文件再次当成浏览器的新数据。
public struct BookmarkExchangeFiles: Sendable {
    public let directory: URL
    public init(base: URL, spaceID: UUID) {
        directory = base.appendingPathComponent(spaceID.uuidString.lowercased(), isDirectory: true)
    }
    public var inputDirectory: URL { directory.appendingPathComponent("待导入", isDirectory: true) }
    public var outputDirectory: URL { directory.appendingPathComponent("已导出", isDirectory: true) }
    public func input() throws -> URL {
        let candidates = ["Safari-收藏夹.zip", "Safari-收藏夹.html", "Bookmarks.html"].map { inputDirectory.appendingPathComponent($0) }
        guard let url = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) else {
            throw PBError.invalid("固定位置没有书签文件，请选择一次来源文件。")
        }
        return url
    }
    public static func read(_ url: URL) throws -> (ImportPreview, String) {
        let (data, digest) = try readData(url)
        return (try SafariBookmarks.preview(data), digest)
    }
    public static func readIfChanged(_ url: URL, since previous: String?) throws -> (ImportPreview?, String) {
        let (data, digest) = try readData(url)
        return (digest == previous ? nil : try SafariBookmarks.preview(data), digest)
    }
    private static func readData(_ url: URL) throws -> (Data, String) {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize, size <= 128 * 1024 * 1024 else { throw PBError.invalid("书签来源不是普通文件，或超过大小上限。") }
        let data = try Data(contentsOf: url)
        guard data.count <= 128 * 1024 * 1024 else { throw PBError.damaged }
        return (data, Crypto.digest(data))
    }
    public func output(_ name: String) -> URL { outputDirectory.appendingPathComponent(name) }

    public static func write(_ data: Data, to url: URL) throws {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        // 已选路径失效时交回选择窗口，不追随重定向覆盖其他文件。
        guard url.standardizedFileURL.resolvingSymlinksInPath().path == url.standardizedFileURL.path else { throw PBError.unauthorized }
        if FileManager.default.fileExists(atPath: url.path) {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true, (values.fileSize ?? Int.max) <= 128 * 1024 * 1024 else { throw PBError.unauthorized }
            let previous = try Data(contentsOf: url)
            if previous == data { return }
            let backup = url.deletingLastPathComponent().appendingPathComponent("历史", isDirectory: true)
                .appendingPathComponent(UUID().uuidString + "-" + url.lastPathComponent)
            try SafeFile.write(previous, to: backup)
        }
        try SafeFile.write(data, to: url)
        guard try Data(contentsOf: url) == data else { throw PBError.damaged }
    }
}
