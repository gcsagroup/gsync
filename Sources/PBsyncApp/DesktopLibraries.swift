#if os(macOS)
import SwiftUI
import PBsyncCore

private struct BookmarkFolder: Identifiable {
    let item: Item
    let children: [BookmarkFolder]?
    var id: UUID { item.id }

    static func tree(in state: SpaceState) -> [Self] {
        let live = state.current
        let groups = Dictionary(grouping: state.items.filter { $0.kind == .folder }) {
            state.effectiveParent(of: $0, live: live)
        }
        func branch(_ parent: UUID?) -> [Self] {
            (groups[parent] ?? []).map { item in
                let children = branch(item.id)
                return Self(item: item, children: children.isEmpty ? nil : children)
            }
        }
        return branch(nil)
    }
}

struct DesktopBookmarkLibrary: View {
    @EnvironmentObject private var model: AppModel
    @Binding var selection: UUID?
    let state: SpaceState
    let edit: (Item) -> Void
    let delete: (Item) -> Void

    private var arranging: Bool { model.search.isEmpty && !model.showDeleted }
    private var rows: [Item] { model.visibleItems }
    private var current: Item? { rows.first { $0.id == selection } }

    var body: some View {
        HSplitView {
            List {
                folderRow("根目录", icon: "square.stack", id: nil)
                OutlineGroup(BookmarkFolder.tree(in: state), children: \.children) { folder in
                    folderRow(folder.item.title, icon: "folder", id: folder.id)
                }
            }.listStyle(.sidebar).frame(minWidth: 145, idealWidth: 185, maxWidth: 210)
            VStack(spacing: 0) {
                HStack {
                    Text("名称").frame(maxWidth: .infinity, alignment: .leading)
                    Text("网址").frame(maxWidth: .infinity, alignment: .leading)
                    Text("来源").frame(width: 76, alignment: .leading)
                }.font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.horizontal, 16).padding(.vertical, 9)
                Divider()
                if rows.isEmpty {
                    ContentUnavailableView(model.showDeleted ? "回收站是空的" : "没有匹配的收藏", systemImage: "bookmark")
                } else {
                    List(selection: $selection) {
                        ForEach(rows) { item in
                            bookmarkRow(item).tag(item.id).contextMenu { actions(item) }
                        }.onMove(perform: arranging ? reorder : nil)
                    }.listStyle(.plain)
                }
                if let current {
                    Divider()
                    HStack(spacing: 14) {
                        actions(current)
                        Spacer()
                    }.buttonStyle(.borderless).padding(.horizontal, 16).padding(.vertical, 12)
                }
            }.frame(minWidth: 380)
        }
    }

    private func folderRow(_ title: String, icon: String, id: UUID?) -> some View {
        Button {
            model.selectedFolder = id
            model.search = ""
            model.showDeleted = false
            selection = nil
            model.touch()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: icon).frame(width: 17)
                Text(title).lineLimit(1)
            }.foregroundStyle(model.selectedFolder == id ? pbsyncAccent : .primary)
                .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
        }.buttonStyle(.plain)
    }

    private func bookmarkRow(_ item: Item) -> some View {
        HStack(spacing: 8) {
            if item.kind == .folder && !model.showDeleted {
                Button { model.selectedFolder = item.id; model.search = ""; selection = nil; model.touch() } label: {
                    Label(item.title, systemImage: "folder")
                        .lineLimit(1)
                }.buttonStyle(.borderless).frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Label(item.title, systemImage: icon(item.kind))
                    .lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
            }
            Text(item.urls.first ?? "—").lineLimit(1).truncationMode(.middle)
                .foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
            Text(item.fields["importSource"] != nil ? "文件导入" : (item.fields["browserRoot"] != nil ? "浏览器目录" : "—"))
                .font(.caption).foregroundStyle(.secondary).frame(width: 76, alignment: .leading)
        }.padding(.vertical, 8).accessibilityElement(children: .contain)
    }

    @ViewBuilder private func actions(_ item: Item) -> some View {
        if model.showDeleted {
            Button("恢复") {
                if let revision = state.history(for: item.id).first { Task { await model.restore(revision) } }
            }
        } else {
            if let raw = item.urls.first, CredentialPolicy.safeBookmarkURL(raw), let url = URL(string: raw) {
                Link("打开", destination: url)
            }
            if item.fields["browserRoot"] == nil {
                Button("编辑") { edit(item) }
                Menu("移动到") {
                    Button("根目录") { place(item, in: nil) }
                    ForEach(state.items.filter { $0.kind == .folder && $0.id != item.id }) { folder in
                        Button(folderPath(folder)) { place(item, in: folder.id) }
                            .disabled(isDescendant(folder, of: item.id))
                    }
                }
                if arranging, let index = rows.firstIndex(where: { $0.id == item.id }) {
                    Button("上移") { place(item, in: model.selectedFolder, before: rows[index - 1].id) }
                        .disabled(index == 0)
                    Button("下移") {
                        place(item, in: model.selectedFolder, before: index + 2 < rows.count ? rows[index + 2].id : nil)
                    }.disabled(index + 1 >= rows.count)
                }
                Button("移至回收站", role: .destructive) { delete(item) }
            }
        }
    }

    private func ancestors(of folder: Item) -> [Item] {
        let live = state.current
        var chain: [Item] = []
        var seen: Set<UUID> = [folder.id]
        var parent = folder.parentID
        while let id = parent, seen.insert(id).inserted, let node = live[id], !node.deleted {
            chain.append(node.item)
            parent = node.item.parentID
        }
        return chain
    }
    private func folderPath(_ folder: Item) -> String {
        (ancestors(of: folder).reversed().map(\.title) + [folder.title]).joined(separator: " / ")
    }
    private func isDescendant(_ folder: Item, of id: UUID) -> Bool {
        ancestors(of: folder).contains { $0.id == id }
    }
    private func reorder(from offsets: IndexSet, to destination: Int) {
        let items = rows
        guard offsets.count == 1, let index = offsets.first, items.indices.contains(index),
              destination != index, destination != index + 1, items[index].fields["browserRoot"] == nil else { return }
        place(items[index], in: model.selectedFolder, before: items.indices.contains(destination) ? items[destination].id : nil)
    }
    private func place(_ item: Item, in parent: UUID?, before anchor: UUID? = nil) {
        Task { await model.placeBookmark(item.id, in: parent, before: anchor) }
    }
}

enum VaultItemSource: String, CaseIterable {
    case local = "PBsync", csv = "CSV 导入", keepass = "KeePass", onePassword = "1Password"

    init(_ item: Item) {
        if item.sourceData.keys.contains(where: { $0.hasPrefix("keepass:") }) { self = .keepass }
        else if item.sourceData.keys.contains(where: { $0.hasPrefix("1password:") }) { self = .onePassword }
        else if item.sourceData["password-csv"] != nil { self = .csv }
        else { self = .local }
    }

    var writeback: String {
        switch self {
        case .local: return "保存在 PBsync"
        case .csv: return "从文件导入 · 来源写回待接入"
        case .keepass: return "写回仅生成 KDBX 候选文件"
        case .onePassword: return "来源写回待验证"
        }
    }
}

struct DesktopPasswordLibrary: View {
    @EnvironmentObject private var model: AppModel
    @Binding var selection: UUID?
    @State private var source: VaultItemSource?
    let edit: (Item) -> Void
    let delete: (Item) -> Void

    private var rows: [Item] { model.visibleItems.filter { source == nil || VaultItemSource($0) == source } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Picker("来源", selection: $source) {
                Text("全部来源").tag(Optional<VaultItemSource>.none)
                ForEach(VaultItemSource.allCases, id: \.self) { Text($0.rawValue).tag(Optional($0)) }
            }.pickerStyle(.segmented).labelsHidden().frame(maxWidth: 420)
                .padding(.horizontal, 16).padding(.vertical, 10)
                .onChange(of: source) { _, _ in selection = nil }
            Divider()
            HSplitView {
                if rows.isEmpty {
                    ContentUnavailableView(model.showDeleted ? "回收站是空的" : "没有匹配的条目", systemImage: "key")
                        .frame(minWidth: 245, idealWidth: 320)
                } else {
                    List(selection: $selection) {
                        ForEach(rows) { item in
                            row(item).tag(item.id).contextMenu { actions(item) }
                        }
                    }.listStyle(.plain).frame(minWidth: 245, idealWidth: 320)
                }
                if let item = rows.first(where: { $0.id == selection }) {
                    ItemDetail(item: item, actions: AnyView(actions(item)))
                        .id(item.id).frame(minWidth: 330, idealWidth: 420)
                } else {
                    ContentUnavailableView("请选择条目", systemImage: "key")
                        .frame(minWidth: 330, idealWidth: 420)
                }
            }
        }.onChange(of: selection) { _, _ in model.touch() }
    }

    private func row(_ item: Item) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon(item.kind)).foregroundStyle(.tint)
                .frame(width: 34, height: 34)
                .background(pbsyncAccent.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title).font(.headline).lineLimit(1)
                Text(item.fields["username"] ?? item.kind.label).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Text(VaultItemSource(item).rawValue).font(.caption).foregroundStyle(.secondary)
        }.padding(.vertical, 6)
    }

    @ViewBuilder private func actions(_ item: Item) -> some View {
        if model.showDeleted {
            Button("恢复") {
                if let revision = model.current?.history(for: item.id).first { Task { await model.restore(revision) } }
            }
        } else {
            Button("编辑") { edit(item) }
            Menu {
                if #available(macOS 26, *), item.kind == .passkey { ExportPasskey(id: item.id) }
                Button("移至回收站", role: .destructive) { delete(item) }
            } label: { Image(systemName: "ellipsis") }.accessibilityLabel("更多操作")
        }
    }
}
#endif
