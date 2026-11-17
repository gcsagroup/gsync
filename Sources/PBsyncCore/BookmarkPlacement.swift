import Foundation

extension VaultStore {
    /// 一次保存移动和同级顺序，避免同步读到只挪了一半的目录。
    public func placeBookmark(_ id: UUID, in parent: UUID?, before anchor: UUID? = nil) throws {
        try transaction { state in
            let live = state.current
            guard state.kind == .bookmarks, let current = live[id], !current.deleted,
                  current.item.fields["browserRoot"] == nil else { throw PBError.unsupported }
            var cursor = parent
            var visited: Set<UUID> = [id]
            while let folderID = cursor {
                guard visited.insert(folderID).inserted, let folder = live[folderID],
                      !folder.deleted, folder.item.kind == .folder else {
                    throw PBError.invalid("目标文件夹已不存在，或会形成循环。")
                }
                cursor = folder.item.parentID
            }
            let oldParent = state.effectiveParent(of: current.item, live: live)
            let others = state.items.filter { $0.id != id }
            func children(in folder: UUID?) -> [Item] {
                others.filter { state.effectiveParent(of: $0, live: live) == folder }
            }
            var target = children(in: parent)
            let index: Int
            if let anchor {
                guard let found = target.firstIndex(where: { $0.id == anchor }) else { throw PBError.conflict }
                index = found
            } else { index = target.count }
            var item = current.item
            item.parentID = parent
            target.insert(item, at: index)
            let groups = oldParent == parent ? [target] : [children(in: oldParent), target]
            var clock = state.revisions.map(\.time).max() ?? LogicalTime(milliseconds: 0)
            var revisions: [Revision] = []
            for group in groups {
                for (offset, original) in group.enumerated() {
                    guard let base = live[original.id] else { throw PBError.damaged }
                    var changed = original
                    changed.order = Int64(offset)
                    if changed == base.item { continue }
                    clock = clock.next()
                    revisions.append(Revision(deviceID: deviceID, time: clock, parents: [base.id], item: changed))
                }
            }
            try state.merge(revisions)
        }
    }
}
