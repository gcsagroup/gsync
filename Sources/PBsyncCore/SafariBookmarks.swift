import Foundation
import ZIPFoundation

public enum SafariBookmarks {
    private static let maximum = 20 * 1024 * 1024
    public static func preview(_ data: Data) throws -> ImportPreview {
        guard data.starts(with:[0x50,0x4b]) else { return try BookmarkHTML.parse(data) }
        guard data.count <= 128*1024*1024 else { throw PBError.invalid("Safari 导出包超过 128 MB。") }
        let archive = try ZIPFoundation.Archive(data:data,accessMode:.read,pathEncoding:.utf8)
        var found: Entry?, count = 0, totalHTML = UInt64(0)
        for entry in archive {
            count += 1
            let path = entry.path, components = path.split(separator:"/")
            guard count <= 4096, !path.hasPrefix("/"), !path.contains("\\"), !components.contains(".."),
                  !path.contains("\0"), entry.type != .symlink else { throw PBError.invalid("Safari 导出包包含不安全路径或过多文件。") }
            guard components.last?.lowercased().hasSuffix(".html") == true else { continue }
            // Safari 按系统语言命名文件。以 Netscape 书签文件头区分历史等其他 HTML。
            guard entry.type == .file, entry.uncompressedSize <= maximum else { throw PBError.invalid("收藏夹文件重复或超过大小上限。") }
            totalHTML += entry.uncompressedSize
            guard totalHTML <= 2 * maximum else { throw PBError.invalid("导出包中的 HTML 总大小超限。") }
            var prefix = Data()
            var extracted = 0
            let checksum = try archive.extract(entry) { chunk in
                extracted += chunk.count
                guard extracted <= entry.uncompressedSize else { throw PBError.damaged }
                if prefix.count < 256 { prefix.append(chunk.prefix(256 - prefix.count)) }
            }
            guard checksum == entry.checksum else { throw PBError.damaged }
            let header = String(decoding:prefix,as:UTF8.self).trimmingCharacters(in:.whitespacesAndNewlines).lowercased()
            guard header.hasPrefix("<!doctype netscape-bookmark-file-1>") else { continue }
            guard found == nil else { throw PBError.invalid("导出包中有多个书签文件，请分别导入。") }
            found = entry
        }
        guard let entry = found else { throw PBError.invalid("Safari 导出包中没有可识别的书签 HTML。") }
        var html = Data()
        let crc = try archive.extract(entry) { chunk in
            guard html.count + chunk.count <= maximum else { throw PBError.damaged }
            html.append(chunk)
        }
        guard crc == entry.checksum, html.count == entry.uncompressedSize else { throw PBError.damaged }
        return try BookmarkHTML.parse(html)
    }

    public static func export(_ state: SpaceState) throws -> Data {
        let html = try BookmarkHTML.export(state)
        guard html.count <= maximum else { throw PBError.invalid("收藏夹 HTML 超过导出上限。") }
        let archive = try ZIPFoundation.Archive(accessMode:.create)
        // 相同内容生成相同字节，后台轮询不会反复覆盖文件或制造历史副本。
        try archive.addEntry(with:"Bookmarks.html",type:.file,uncompressedSize:Int64(html.count),
                             modificationDate:Date(timeIntervalSince1970: 946_684_800),compressionMethod:.deflate) { position,size in
            html.subdata(in:Int(position)..<(Int(position)+size))
        }
        guard let data=archive.data else { throw PBError.damaged }
        return data
    }
}
