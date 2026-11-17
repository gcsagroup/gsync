#if os(macOS)
import SwiftUI
import AppKit
import PBsyncCore

struct DesktopConnectionsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var connectedLinks: [ExternalLink] = []
    @State private var authorizationNeeded = false

    private struct Row: Identifiable {
        var id: String { source }
        let source: String
        let data: String
        let route: String
        let status: String
        var icon: String = "circle"
    }

    private var bookmarkSpace: UUID? {
        if model.selected?.kind == .bookmarks { return model.selectedID }
        return model.bridgeActiveBookmarkID ?? model.entries.first { $0.kind == .bookmarks }?.id
    }
    private var safariState: String {
        guard let id = bookmarkSpace else { return "待创建收藏夹" }
        guard model.automaticBookmarkFiles.contains(id) else { return "后台交换未启用" }
        guard model.states[id] != nil else { return "收藏夹已锁定" }
        return model.bookmarkFileStatus[id] ?? "等待检查固定目录"
    }
    private var browserState: String {
        guard let id = model.bridgeActiveBookmarkID, !model.bridgeToken.isEmpty else {
            return model.bridgeAuthorizationNeedsUnlock ? "需要恢复配对授权" : "等待扩展配对"
        }
        guard model.states[id] != nil else { return "收藏夹已锁定" }
        if let date = model.lastBookmarkBridgeExchange[id] {
            return "最近收到扩展请求 " + date.formatted(date: .omitted, time: .shortened)
        }
        return "等待扩展请求"
    }
    private var rows: [Row] {
        [
            Row(source: "Chrome / Edge / Firefox / Aegis", data: "收藏夹", route: "浏览器扩展 API", status: browserState, icon: "globe"),
            Row(source: "Safari", data: "收藏夹", route: "固定文件交换", status: safariState, icon: "safari"),
            Row(source: "浏览器内置密码库", data: "密码", route: "文件迁移", status: "后台双向待接入", icon: "key"),
            Row(source: "KeePass", data: "密码", route: "KDBX 文件", status: sourceState("kdbx", fallback: "仅生成写回候选"), icon: "lock"),
            Row(source: "1Password", data: "密码", route: "官方 CLI", status: sourceState("op", fallback: "来源写回待验证"), icon: "lock.shield")
        ]
    }
    private func sourceState(_ kind: String, fallback: String) -> String {
        let links = connectedLinks.filter { $0.kind == kind }
        guard !links.isEmpty else {
            return (authorizationNeeded ? "需恢复钥匙串授权 · " : "待连接 · ") + fallback
        }
        let active = links.filter(\.enabled).count
        let summary = active == links.count ? "已配置读取" : "读取暂停 \(links.count - active) 个"
        return summary + " · " + fallback
    }
    private var unlockedVaults: [UUID] {
        model.entries.filter { $0.kind == .vault && model.states[$0.id] != nil }.map(\.id)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let id = bookmarkSpace {
                HStack {
                    Toggle("Safari 文件后台交换", isOn: Binding(
                        get: { model.automaticBookmarkFiles.contains(id) },
                        set: { model.setAutomaticBookmarkFiles($0, for: id) }
                    )).toggleStyle(.switch).disabled(model.states[id] == nil)
                        .help("合并固定目录中的书签文件并导出书签 ZIP。Safari 端仍需导入。")
                    if let space = model.states[id] {
                        Text(space.name).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    if model.automaticBookmarkFiles.contains(id), model.states[id] != nil {
                        Button("打开交换目录") { NSWorkspace.shared.open(model.exchangeFiles(id).directory) }
                    }
                }.padding(.horizontal, 20).padding(.vertical, 12)
            }
            Table(rows) {
                TableColumn("来源") { row in Label(row.source, systemImage: row.icon) }
                    .width(min: 155, ideal: 215)
                TableColumn("数据", value: \.data).width(min: 48, ideal: 60)
                TableColumn("接入方式", value: \.route).width(min: 105, ideal: 130)
                TableColumn("状态") { row in Text(row.status).foregroundStyle(.secondary).lineLimit(2) }
                    .width(min: 240, ideal: 320)
            }.alternatingRowBackgrounds(.disabled)
            Divider()
            Label("官方接口 → 安全读写 → 文件交换", systemImage: "info.circle")
                .font(.callout).foregroundStyle(.secondary).padding(20)
        }.task(id: unlockedVaults.map(model.spaceSession).joined(separator: "|") + "|\(model.externalEpoch)") {
            await reloadLinks()
        }
    }

    private func reloadLinks() async {
        let ids = unlockedVaults
        let accounts = ids.map(model.linkKey)
        let (loaded, needsAuthorization) = await Task.detached {
            var links: [ExternalLink] = []
            var needsAuthorization = false
            for account in accounts {
                do { links += try ExternalLink.saved(account: account, allowInteraction: false) }
                catch { needsAuthorization = true }
            }
            return (links, needsAuthorization)
        }.value
        guard !Task.isCancelled, unlockedVaults == ids else { return }
        connectedLinks = loaded
        authorizationNeeded = needsAuthorization
    }
}
#endif
