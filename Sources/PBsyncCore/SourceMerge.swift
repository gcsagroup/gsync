import Foundation

public struct SourceChanges: Sendable {
    public var imported = 0
    public var conflicts = 0
    public var missing = 0
    public var unsupported = 0
    public var patches: [[String: String]] = []
}

extension VaultStore {
    /// 基线与条目一起加密和同步。读取来源永不把“缺少”解释为删除。
    public func reconcileSource(_ incoming: ImportPreview, apply: Bool) throws -> SourceChanges {
        guard incoming.source.hasPrefix("keepass:") || incoming.source.hasPrefix("1password:") else { throw PBError.unsupported }
        let baselineKey = "pbsync.source-digest"
        func fingerprint(_ value: Item) throws -> Data {
            var normalized = value
            normalized.order = 0
            normalized.sourceData.removeValue(forKey: baselineKey)
            return Data(Crypto.digest(try Coding.encode(normalized)).utf8)
        }
        func compare(_ state: inout SpaceState) throws -> SourceChanges {
            guard state.kind == .vault else { throw PBError.invalid("请先解锁目标保险库。") }
            var result = SourceChanges()
            let before = state.current
            let present = Set(incoming.items.map(\.id))
            guard present.count == incoming.items.count else { throw PBError.conflict }
            result.missing = before.values.filter { !$0.deleted && $0.item.sourceData[incoming.source] != nil && !present.contains($0.item.id) }.count
            for var remote in incoming.items {
                guard let rawID = remote.sourceData["pbsync.external-id"], let sourceID = String(data: rawID, encoding: .utf8),
                      remote.id == Coding.stableID(incoming.source + ":" + sourceID) else { throw PBError.damaged }
                let digest = try fingerprint(remote)
                if let revision = before[remote.id] {
                    var local = revision.item
                    guard !revision.deleted else { result.conflicts += 1; continue }
                    // 兼容此前手动迁入的条目。没有可核对的基线时保守处理。
                    if local.sourceData["pbsync.external-id"] == nil { local.sourceData["pbsync.external-id"] = rawID }
                    let localDigest = try fingerprint(local)
                    let previous = local.sourceData[baselineKey]
                    if localDigest == digest, previous == digest { continue }
                    if localDigest != digest && localDigest != previous {
                        guard previous == digest else { result.conflicts += 1; continue }
                        var patch = ["sourceID": sourceID]
                        var projected = remote
                        for key in ["username","password"] where local.fields[key] != remote.fields[key] {
                            patch[key] = local.fields[key] ?? ""
                            projected.fields[key] = local.fields[key]
                        }
                        if local.title != remote.title { patch["title"] = local.title; projected.title = local.title }
                        if local.notes != remote.notes { patch["notes"] = local.notes; projected.notes = local.notes }
                        if local.urls != remote.urls, local.urls.count <= 1 {
                            patch["url"] = local.urls.first ?? ""; projected.urls = local.urls
                        }
                        guard try fingerprint(projected) == localDigest, patch.count > 1 else {
                            result.unsupported += 1; continue
                        }
                        result.patches.append(patch)
                        continue
                    }
                    remote.order = local.order
                }
                remote.sourceData[baselineKey] = digest
                _ = try append(remote, deleted:false, now:Date(), to:&state)
                result.imported += 1
            }
            return result
        }
        var state = try snapshot()
        let preview = try compare(&state)
        if apply && preview.imported > 0 { return try transaction(compare) }
        return preview
    }
}
