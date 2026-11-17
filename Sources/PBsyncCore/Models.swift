import Foundation
import CryptoKit

public enum PBError: Error, LocalizedError, Equatable {
    case invalid(String), locked, wrongSecret, damaged, unsupported, conflict, unauthorized, quota, unavailable
    public var errorDescription: String? {
        switch self {
        case .invalid(let message): return message
        case .locked: return "请先解锁当前数据空间。"
        case .wrongSecret: return "解锁材料不正确，或密钥文件已损坏。"
        case .damaged: return "内容校验失败，已保留本地有效数据。"
        case .unsupported: return "此格式或能力尚未支持，未执行写入。"
        case .conflict: return "来源已变化，请重新读取后再提交。"
        case .unauthorized: return "存储或来源需要重新授权。"
        case .quota: return "存储空间不足。"
        case .unavailable: return "暂时无法连接，修改仍保存在本机。"
        }
    }
}

public enum SpaceKind: String, Codable, Sendable { case bookmarks, vault }
public enum ItemKind: String, Codable, CaseIterable, Sendable {
    case folder, bookmark, login, totp, passkey, recoveryCodes, card, identity, note
    public var label: String {
        switch self {
        case .folder: return "文件夹"
        case .bookmark: return "收藏"
        case .login: return "登录账号"
        case .totp: return "验证码"
        case .passkey: return "通行密钥"
        case .recoveryCodes: return "恢复码"
        case .card: return "银行卡"
        case .identity: return "身份信息"
        case .note: return "安全笔记"
        }
    }
}

public struct Attachment: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var mediaType: String
    public var data: Data
    public var remoteSize: Int?
    public var digest: String
    public init(name: String, mediaType: String = "application/octet-stream", data: Data) throws {
        guard data.count <= 10 * 1024 * 1024 else { throw PBError.invalid("单个附件暂限 10 MB。") }
        self.id = UUID(); self.name = name; self.mediaType = mediaType; self.data = data
        self.digest = Crypto.digest(data)
    }
    public func validate() throws {
        if let size = remoteSize {
            guard (1...10*1024*1024).contains(size), data.isEmpty, digest.utf8.count == 64,
                  digest.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }), name.utf8.count <= 1024 else { throw PBError.damaged }
            return
        }
        guard data.count <= 10 * 1024 * 1024, digest == Crypto.digest(data), name.utf8.count <= 1024 else { throw PBError.damaged }
    }
}

public struct Item: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var kind: ItemKind
    public var title: String
    public var parentID: UUID?
    public var order: Int64
    public var urls: [String]
    public var fields: [String: String]
    public var notes: String
    public var tags: [String]
    public var attachments: [Attachment]
    /// 未识别的来源字段以原始 JSON 保存，并随整个条目加密。
    public var sourceData: [String: Data]
    public init(id: UUID = UUID(), kind: ItemKind, title: String, parentID: UUID? = nil,
                order: Int64 = 0, urls: [String] = [], fields: [String: String] = [:],
                notes: String = "", tags: [String] = [], attachments: [Attachment] = [], sourceData: [String: Data] = [:]) {
        self.id = id; self.kind = kind; self.title = title; self.parentID = parentID; self.order = order
        self.urls = urls; self.fields = fields; self.notes = notes; self.tags = tags
        self.attachments = attachments; self.sourceData = sourceData
    }
    public func validate(in space: SpaceKind) throws {
        let isBookmark = kind == .bookmark || kind == .folder
        guard isBookmark == (space == .bookmarks), parentID != id,
              title.utf8.count <= 8192, notes.utf8.count <= 1_048_576,
              fields.count <= 256, urls.count <= 100, attachments.count <= 100,
              fields.values.allSatisfy({ $0.utf8.count <= 1_048_576 }),
              urls.allSatisfy({ $0.utf8.count <= 32768 }) else { throw PBError.invalid("条目类型、层级或大小不符合当前空间规则。") }
        for attachment in attachments { try attachment.validate() }
        guard Set(attachments.map(\.id)).count == attachments.count else { throw PBError.damaged }
    }
}

/// 混合逻辑时钟：因果后继总是更大，并发用物理时间和稳定身份决胜。
public struct LogicalTime: Codable, Equatable, Comparable, Sendable {
    public var milliseconds: Int64
    public var counter: UInt64
    public init(milliseconds: Int64, counter: UInt64 = 0) { self.milliseconds = milliseconds; self.counter = counter }
    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.milliseconds == rhs.milliseconds ? lhs.counter < rhs.counter : lhs.milliseconds < rhs.milliseconds
    }
    public func next(now: Date = Date()) -> Self {
        let wall = Int64(now.timeIntervalSince1970 * 1000)
        return wall > milliseconds ? .init(milliseconds: wall) : .init(milliseconds: milliseconds, counter: counter + 1)
    }
}

public struct Revision: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var deviceID: UUID
    public var time: LogicalTime
    public var parents: [UUID]
    public var item: Item
    public var deleted: Bool
    public init(id: UUID = UUID(), deviceID: UUID, time: LogicalTime, parents: [UUID] = [], item: Item, deleted: Bool = false) {
        self.id = id; self.deviceID = deviceID; self.time = time; self.parents = parents.sorted { $0.uuidString < $1.uuidString }
        self.item = item; self.deleted = deleted
    }
    public static func precedes(_ a: Self, _ b: Self) -> Bool {
        if a.time != b.time { return a.time < b.time }
        if a.deviceID != b.deviceID { return a.deviceID.uuidString < b.deviceID.uuidString }
        return a.id.uuidString < b.id.uuidString
    }
}

public struct SpaceState: Codable, Equatable, Sendable {
    public var name: String
    public var kind: SpaceKind
    public var revisions: [Revision]
    public var generation: Int
    public var retired: Bool
    public init(name: String, kind: SpaceKind, revisions: [Revision] = [], generation: Int = 1, retired: Bool = false) {
        self.name = name; self.kind = kind; self.revisions = revisions; self.generation = generation; self.retired = retired
    }
    public var current: [UUID: Revision] {
        revisions.reduce(into: [:]) { result, revision in
            if let old = result[revision.item.id], !Revision.precedes(old, revision) { return }
            result[revision.item.id] = revision
        }
    }
    public var items: [Item] {
        current.values.filter { !$0.deleted }.map(\.item).sorted {
            $0.order == $1.order ? $0.id.uuidString < $1.id.uuidString : $0.order < $1.order
        }
    }
    public func history(for itemID: UUID) -> [Revision] {
        revisions.filter { $0.item.id == itemID }.sorted { Revision.precedes($1, $0) }
    }
    public var clockWarning: Bool {
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        return revisions.contains { $0.time.milliseconds > now + 300_000 }
    }
    /// 父目录缺失或形成环时仅修正显示位置，不改写历史，也不丢弃子树。
    public func effectiveParent(of item: Item) -> UUID? {
        return effectiveParent(of: item, live: current)
    }
    public func effectiveParent(of item: Item, live: [UUID:Revision]) -> UUID? {
        var visited: Set<UUID> = [item.id]
        var cursor = item.parentID
        while let id = cursor {
            guard !visited.contains(id), let parent = live[id], !parent.deleted, parent.item.kind == .folder else { return nil }
            visited.insert(id); cursor = parent.item.parentID
        }
        return item.parentID
    }
    public mutating func merge(_ incoming: [Revision]) throws {
        var byID = Dictionary(uniqueKeysWithValues: revisions.map { ($0.id, $0) })
        for revision in incoming {
            try revision.item.validate(in: kind)
            guard revision.time.milliseconds >= 0, revision.time.counter < UInt64.max - 1,
                  revision.parents.count <= 10_000, !revision.parents.contains(revision.id),
                  Set(revision.parents).count == revision.parents.count else { throw PBError.damaged }
            if let old = byID[revision.id] {
                if old == revision { continue }
                var projected = revision
                guard projected.item.attachments.count == old.item.attachments.count else { throw PBError.damaged }
                for i in projected.item.attachments.indices {
                    let a = projected.item.attachments[i], b = old.item.attachments[i]
                    if a.remoteSize != b.remoteSize, (a.remoteSize ?? a.data.count) == (b.remoteSize ?? b.data.count) {
                        projected.item.attachments[i].data = b.data
                        projected.item.attachments[i].remoteSize = b.remoteSize
                    }
                }
                guard projected == old else { throw PBError.damaged }; continue
            }
            byID[revision.id] = revision
        }
        for revision in byID.values {
            for parentID in revision.parents {
                guard let parent = byID[parentID], parent.item.id == revision.item.id,
                      parent.time < revision.time else { throw PBError.invalid("同步版本尚不完整或因果关系无效，请稍后重试。") }
            }
        }
        revisions = byID.values.sorted { $0.id.uuidString < $1.id.uuidString }
    }
}

public enum Coding {
    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(value)
        guard data.count <= 128 * 1024 * 1024 else { throw PBError.invalid("编码结果超过可恢复的 128 MB 上限。") }; return data
    }
    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        guard data.count <= 128 * 1024 * 1024 else { throw PBError.invalid("文件超过当前 128 MB 导入上限。") }
        do { return try JSONDecoder().decode(type, from: data) } catch { throw PBError.damaged }
    }
    public static func stableID(_ text: String) -> UUID {
        let h = Array(SHA256.hash(data: Data(text.utf8)).prefix(16))
        return UUID(uuid: (h[0],h[1],h[2],h[3],h[4],h[5],h[6],h[7],h[8],h[9],h[10],h[11],h[12],h[13],h[14],h[15]))
    }
}
