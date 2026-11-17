import Foundation

/// 文件交换没有可靠的删除事件。按目录和出现次数合并，只添加确实缺少的节点；
/// 不把来源缺项当成删除，也不重排、覆盖已存在的用户书签。
public enum BookmarkFileMerge {
    private static let roots: [String: UUID] = [
        "toolbar": UUID(uuidString: "62b3a4bb-4826-4856-8fb2-cff155b7d801")!,
        "other": UUID(uuidString: "62b3a4bb-4826-4856-8fb2-cff155b7d802")!,
        "mobile": UUID(uuidString: "62b3a4bb-4826-4856-8fb2-cff155b7d803")!,
        "menu": UUID(uuidString: "62b3a4bb-4826-4856-8fb2-cff155b7d804")!
    ]

    private static func role(_ item: Item, imported: Bool) -> String? {
        guard item.kind == .folder else { return nil }
        if let role = roots.first(where: { $0.value == item.id })?.key { return role }
        if let role = item.fields["browserRoot"], roots[role] != nil { return role }
        guard imported, item.parentID == nil else { return nil }
        switch item.title {
        case "个人收藏", "Favorites", "书签栏", "书签工具栏", "Bookmarks Bar": return "toolbar"
        case "其他书签", "Other Bookmarks": return "other"
        case "书签菜单", "Bookmarks Menu": return "menu"
        default: return nil
        }
    }

    public static func additions(_ preview: ImportPreview, to state: SpaceState) throws -> [Item] {
        guard state.kind == .bookmarks else { throw PBError.unsupported }
        let incoming = preview.items, existing = state.items
        guard Set(incoming.map(\.id)).count == incoming.count else { throw PBError.damaged }
        let ids = Set(incoming.map(\.id))
        guard incoming.allSatisfy({ $0.parentID == nil || ids.contains($0.parentID!) }) else { throw PBError.damaged }
        var grouped = Dictionary(grouping: incoming, by: \.parentID)
        for key in grouped.keys { grouped[key]?.sort { $0.order < $1.order } }
        var consumed = Set<UUID>(), visited = Set<UUID>(), result: [Item] = []
        var nextOrder: [UUID?: Int64] = [:]
        for item in existing { nextOrder[item.parentID] = max(nextOrder[item.parentID] ?? 0, item.order + 1) }
        let other = existing.first { role($0, imported: false) == "other" }
        func visit(_ item: Item, parent: UUID?, depth: Int) throws {
            guard depth < 64, visited.insert(item.id).inserted else { throw PBError.damaged }
            try item.validate(in: .bookmarks)
            var destination = parent
            var match: Item?
            if item.parentID == nil, let rootRole = role(item, imported: true) {
                let candidates = existing.filter { !consumed.contains($0.id) && role($0, imported: false) == rootRole }
                guard candidates.count <= 1 else { throw PBError.conflict }
                match = candidates.first
            } else if parent == nil, item.parentID == nil, let other { destination = other.id }
            if match == nil {
                match = existing.filter {
                    !consumed.contains($0.id) && $0.parentID == destination && $0.kind == item.kind &&
                    $0.title == item.title && $0.urls == item.urls
                }.sorted { $0.order < $1.order }.first
            }
            let target: UUID
            if let match { consumed.insert(match.id); target = match.id }
            else {
                var added = item
                // 文件中的身份不能覆盖本机任意旧节点；本机身份只由精确匹配复用。
                added.id = UUID(); added.parentID = destination
                added.order = nextOrder[destination] ?? 0; nextOrder[destination] = added.order + 1
                target = added.id; result.append(added)
            }
            for child in grouped[item.id] ?? [] { try visit(child, parent: target, depth: depth + 1) }
        }
        for root in grouped[nil] ?? [] { try visit(root, parent: nil, depth: 0) }
        guard visited.count == incoming.count else { throw PBError.damaged }
        return result
    }
}

extension VaultStore {
    public func mergeBookmarkFile(_ preview: ImportPreview) throws -> Int {
        try transaction { state in
            let additions = try BookmarkFileMerge.additions(preview, to: state)
            for item in additions { _ = try append(item, deleted: false, now: Date(), to: &state) }
            return additions.count
        }
    }
}
