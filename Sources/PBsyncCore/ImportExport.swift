import Foundation

public struct ImportPreview: Sendable {
    public var items: [Item]
    public var warnings: [String]
    public var source: String
    public var count: Int { items.count }
    public init(items: [Item], warnings: [String] = [], source: String) { self.items = items; self.warnings = warnings; self.source = source }
}

public enum BookmarkHTML {
    private static func unescape(_ value: String) -> String {
        var result = value
        let named = ["&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'", "&apos;": "'", "&nbsp;": " "]
        for (entity, character) in named { result = result.replacingOccurrences(of: entity, with: character) }
        let pattern = try! NSRegularExpression(pattern: "&#(x[0-9a-fA-F]+|[0-9]+);")
        for match in pattern.matches(in: result, range: NSRange(result.startIndex..., in: result)).reversed() {
            guard let whole = Range(match.range, in: result), let numberRange = Range(match.range(at: 1), in: result) else { continue }
            let token = String(result[numberRange]); let radix = token.hasPrefix("x") ? 16 : 10
            if let number = UInt32(token.hasPrefix("x") ? String(token.dropFirst()) : token, radix: radix), let scalar = UnicodeScalar(number) { result.replaceSubrange(whole, with: String(scalar)) }
        }
        return result.replacingOccurrences(of: "&amp;", with: "&")
    }
    private static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }
    public static func parse(_ data: Data, source: String = "safari") throws -> ImportPreview {
        guard data.count <= 20 * 1024 * 1024, let html = String(data: data, encoding: .utf8) else { throw PBError.invalid("收藏夹文件须为 UTF-8，且不超过 20 MB。") }
        let tokenizer = try NSRegularExpression(pattern: "<(/?)(DL|H3|A)\\b([^>]*)>|([^<]+)", options: [.caseInsensitive, .dotMatchesLineSeparators])
        let attributes = try NSRegularExpression(pattern: "([a-zA-Z_-]+)\\s*=\\s*(?:\"([^\"]*)\"|'([^']*)'|([^\\s>]+))")
        var stack: [UUID?] = [], pendingFolder: UUID?, title = "", active = "", attrs: [String: String] = [:]
        var items: [Item] = [], occurrences: [String: Int] = [:], order: [String: Int64] = [:]
        var warnings: [String] = [], recognized = false
        func parent() -> UUID? { stack.last ?? nil }
        for match in tokenizer.matches(in: html, range: NSRange(html.startIndex..., in: html)) {
            func part(_ index: Int) -> String { Range(match.range(at: index), in: html).map { String(html[$0]) } ?? "" }
            let tag = part(2).uppercased(), closing = part(1) == "/"
            if tag.isEmpty { if !active.isEmpty { title += part(4) }; continue }
            if tag == "DL" {
                recognized = true
                if closing { if !stack.isEmpty { stack.removeLast() } }
                else {
                    guard stack.count < 64 else { throw PBError.invalid("收藏夹目录超过 64 层。") }
                    stack.append(pendingFolder ?? parent()); pendingFolder = nil
                }
                continue
            }
            if !closing {
                active = tag; title = ""; attrs = [:]
                let input = part(3)
                for attribute in attributes.matches(in: input, range: NSRange(input.startIndex..., in: input)) {
                    guard let keyRange = Range(attribute.range(at: 1), in: input) else { continue }
                    for index in 2...4 {
                        if let range = Range(attribute.range(at: index), in: input) { attrs[String(input[keyRange]).lowercased()] = unescape(String(input[range])); break }
                    }
                }
            } else if active == tag {
                let text = unescape(title).trimmingCharacters(in: .whitespacesAndNewlines)
                let url = attrs["href"] ?? ""
                if tag == "A" && url.isEmpty { warnings.append("一条收藏缺少网址，已跳过。"); active = ""; continue }
                let parentID = parent(), key = parentID?.uuidString ?? "root"
                let identity = "\(source)|\(key)|\(tag)|\(text)|\(url)"
                let occurrence = occurrences[identity, default: 0]; occurrences[identity] = occurrence + 1
                let id = Coding.stableID(identity + "|\(occurrence)")
                let index = order[key, default: 0]; order[key] = index + 1
                var item = Item(id: id, kind: tag == "H3" ? .folder : .bookmark, title: text, parentID: parentID, order: index, urls: tag == "A" ? [url] : [])
                if tag == "A" && !CredentialPolicy.safeBookmarkURL(url) {
                    item.fields["unsafeURL"] = "true"; warnings.append("一个网址不属于 HTTP／HTTPS，已保留为文本，禁止直接打开。")
                }
                item.fields["importSource"] = source
                items.append(item); if tag == "H3" { pendingFolder = id }; active = ""
                guard items.count <= 100_000 else { throw PBError.invalid("单次最多导入 100,000 个收藏节点。") }
            }
        }
        guard recognized else { throw PBError.invalid("未识别到收藏夹 HTML 目录结构。") }
        return ImportPreview(items: items, warnings: Array(Set(warnings)).sorted(), source: source)
    }
    public static func export(_ state: SpaceState) throws -> Data {
        guard state.kind == .bookmarks else { throw PBError.invalid("当前空间不是收藏夹。") }
        let items = state.items
        var groups: [String: [Item]] = [:]
        let live = state.current
        for item in items { groups[state.effectiveParent(of: item, live:live)?.uuidString ?? "root", default: []].append(item) }
        var output = "<!DOCTYPE NETSCAPE-Bookmark-file-1>\n<META HTTP-EQUIV=\"Content-Type\" CONTENT=\"text/html; charset=UTF-8\">\n<TITLE>PBsync 收藏夹</TITLE>\n<H1>PBsync 收藏夹</H1>\n"
        func emit(_ key: String, depth: Int) throws {
            guard depth <= 64 else { throw PBError.invalid("目录深度超过导出上限。") }
            output += "<DL><p>\n"
            for item in groups[key] ?? [] {
                if item.kind == .folder {
                    output += "<DT><H3>\(escape(item.title))</H3>\n"; try emit(item.id.uuidString, depth: depth + 1)
                } else { output += "<DT><A HREF=\"\(escape(item.urls.first ?? ""))\">\(escape(item.title))</A>\n" }
            }
            output += "</DL><p>\n"
        }
        try emit("root", depth: 0); return Data(output.utf8)
    }
}

public enum PasswordCSV {
    public static func rows(_ text: String) throws -> [[String]] {
        guard text.utf8.count <= 20 * 1024 * 1024 else { throw PBError.invalid("CSV 超过 20 MB。") }
        let chars = Array(text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text)
        var result: [[String]] = [], row: [String] = [], field = "", quoted = false, closed = false, index = 0
        func finishField() { row.append(field); field = ""; closed = false }
        while index < chars.count {
            let c = chars[index]
            if quoted {
                if c == "\"" {
                    if index + 1 < chars.count && chars[index + 1] == "\"" { field.append("\""); index += 1 }
                    else { quoted = false; closed = true }
                } else { field.append(c) }
            } else if c == "," { finishField() }
            else if c == "\n" || c == "\r" || c == "\r\n" {
                finishField(); if row != [""] { result.append(row) }; row = []
                if c == "\r", index + 1 < chars.count, chars[index + 1] == "\n" { index += 1 }
            } else if c == "\"" && field.isEmpty && !closed { quoted = true }
            else {
                guard !closed, c != "\"" else { throw PBError.invalid("CSV 引号结构不正确。") }; field.append(c)
            }
            guard row.count <= 256, result.count <= 100_000, field.utf8.count <= 1_048_576 else { throw PBError.invalid("CSV 行数或字段大小超限。") }
            index += 1
        }
        guard !quoted else { throw PBError.invalid("CSV 引号未闭合。") }
        if !field.isEmpty || !row.isEmpty || closed { finishField(); result.append(row) }
        return result
    }
    public static func parse(_ data: Data, source: String = "password-csv") throws -> ImportPreview {
        guard let text = String(data: data, encoding: .utf8) else { throw PBError.invalid("CSV 必须为 UTF-8。") }
        let rows = try rows(text)
        guard let header = rows.first else { throw PBError.invalid("CSV 文件为空。") }
        let names = header.map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        guard Set(names).count == names.count, names.contains("password") else { throw PBError.invalid("CSV 缺少 password 列或存在重复列名。") }
        var items: [Item] = [], occurrences: [String: Int] = [:]
        for (index, row) in rows.dropFirst().enumerated() {
            guard row.count == header.count else { throw PBError.invalid("CSV 第 \(index + 2) 行列数与表头不一致。") }
            let values = Dictionary(uniqueKeysWithValues: zip(names, row))
            let url = values["url"] ?? values["website"] ?? values["login_uri"] ?? ""
            let username = values["username"] ?? values["user"] ?? values["login_username"] ?? ""
            let title = values["name"] ?? values["title"] ?? URL(string: url)?.host ?? "导入账号"
            let identity = "\(source)|\(url)|\(username)|\(title)"
            let occurrence = occurrences[identity, default: 0]; occurrences[identity] = occurrence + 1
            var item = Item(id: Coding.stableID(identity + "|\(occurrence)"), kind: .login, title: title, order: Int64(index), urls: url.isEmpty ? [] : [url], fields: ["username": username, "password": values["password"] ?? ""], notes: values["note"] ?? values["notes"] ?? "")
            item.sourceData[source] = try Coding.encode(values); items.append(item)
        }
        return ImportPreview(items: items, warnings: ["CSV 只承载部分登录字段；通行密钥、附件及历史需要完整加密备份。未知列已加密保留。"], source: source)
    }
    public static func export(_ state: SpaceState) throws -> Data {
        guard state.kind == .vault else { throw PBError.invalid("当前空间不是保险库。") }
        func quote(_ text: String) -> String { "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
        let rows = state.items.filter { $0.kind == .login }.map { [$0.title, $0.urls.first ?? "", $0.fields["username"] ?? "", $0.fields["password"] ?? "", $0.notes].map(quote).joined(separator: ",") }
        return Data((["name,url,username,password,note"] + rows).joined(separator: "\r\n").utf8)
    }
}

public enum CredentialPolicy {
    public static func safeBookmarkURL(_ text: String) -> Bool {
        guard let url = URL(string: text), ["https", "http"].contains(url.scheme?.lowercased() ?? ""), url.host != nil, url.user == nil, url.password == nil else { return false }; return true
    }
    public static func origin(_ text: String) -> String? {
        guard let components = URLComponents(string: text), components.scheme?.lowercased() == "https", let host = components.host?.lowercased(), !host.isEmpty,
              components.user == nil, components.password == nil else { return nil }
        return "https://\(host)" + ((components.port == nil || components.port == 443) ? "" : ":\(components.port!)")
    }
    public static func matches(item: Item, pageURL: String) -> Bool {
        guard item.kind == .login, let pageOrigin = origin(pageURL) else { return false }
        return item.urls.contains { origin($0) == pageOrigin }
    }
    public static func matchesDomain(item: Item, domain: String) -> Bool {
        guard !domain.contains("/"), !domain.contains(":"), !domain.hasPrefix("."), !domain.hasSuffix(".") else { return false }
        return item.urls.contains { origin($0) == "https://" + domain.lowercased() }
    }
}
