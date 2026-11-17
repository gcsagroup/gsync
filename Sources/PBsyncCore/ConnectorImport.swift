import Foundation

public enum ConnectorImport {
    private struct Package: Decodable { var schema: Int; var source: String; var items: [Record]; var warnings: [String] }
    private struct Record: Decodable {
        var sourceID: String; var title: String; var kind: ItemKind; var urls: [String]; var fields: [String: String]
        var notes: String; var tags: [String]; var attachments: [File]; var raw: Data
    }
    private struct File: Decodable { var name: String; var mediaType: String; var data: Data }
    public static func parse(_ data: Data) throws -> ImportPreview {
        let package = try Coding.decode(Package.self, from: data)
        guard package.schema == 1, package.items.count <= 100_000,
              package.source.hasPrefix("1password:") || package.source.hasPrefix("keepass:") else { throw PBError.unsupported }
        var items: [Item] = []
        for (index, record) in package.items.enumerated() {
            guard !record.sourceID.isEmpty, record.sourceID.utf8.count < 256 else { throw PBError.invalid("来源条目缺少稳定身份。") }
            let attachments = try record.attachments.enumerated().map { index, file -> Attachment in
                var attachment = try Attachment(name: file.name, mediaType: file.mediaType, data: file.data)
                attachment.id = Coding.stableID(package.source + ":" + record.sourceID + ":attachment:\(index):" + attachment.digest)
                return attachment
            }
            let item = Item(id: Coding.stableID(package.source + ":" + record.sourceID), kind: record.kind, title: record.title, order: Int64(index), urls: record.urls, fields: record.fields, notes: record.notes, tags: record.tags, attachments: attachments, sourceData: [package.source: record.raw, "pbsync.external-id": Data(record.sourceID.utf8)])
            try item.validate(in: .vault); items.append(item)
        }
        guard Set(items.map(\.id)).count == items.count else { throw PBError.invalid("来源包含重复的条目身份。") }
        return ImportPreview(items: items, warnings: package.warnings, source: package.source)
    }
}
