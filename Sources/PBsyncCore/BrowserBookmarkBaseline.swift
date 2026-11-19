import Foundation

/// 浏览器上次看到的字段，仅用于识别本次真正修改的部分。
public struct BrowserBookmarkBaseline: Decodable, Sendable {
    public let kind: ItemKind
    public let title: String
    public let parentID: UUID?
    public let order: Int
    public let urls: [String]

    func applying(_ proposed: Item, to current: Item) -> Item {
        var merged = current
        if proposed.kind != kind { merged.kind = proposed.kind }
        if proposed.title != title { merged.title = proposed.title }
        if proposed.parentID != parentID { merged.parentID = proposed.parentID }
        if proposed.order != order { merged.order = proposed.order }
        if proposed.urls != urls { merged.urls = proposed.urls }
        return merged
    }
}
