#if os(macOS)
import AppKit
import ApplicationServices

/// 直接读取指定浏览器进程，避免同一应用的验收配置与日常配置相互串用。
/// 接口仅提供“书签栏”和“其他书签”两棵本地树。结果不包含标题或网址明文。
public enum MacBookmarkReader {
    public struct Result: Encodable {
        public var browser: String
        public var bookmarks: Int
        public var folders: Int
        public var mixedFolders: Int
        public var sha256: String
    }

    private typealias Descriptor = NSAppleEventDescriptor
    private struct Entry: Encodable {
        let type: String
        let title: String
        let url: String?
        let parent: Int
        let order: Int
    }

    private static func code(_ value: String) -> UInt32 {
        value.utf8.reduce(0) { ($0 << 8) | UInt32($1) }
    }

    private static func object(_ kind: String, _ form: String, _ selector: Descriptor,
                               in parent: Descriptor) throws -> Descriptor {
        let spec = Descriptor.record()
        spec.setDescriptor(Descriptor(typeCode:code(kind)), forKeyword:code("want"))
        spec.setDescriptor(Descriptor(enumCode:code(form)), forKeyword:code("form"))
        spec.setDescriptor(selector, forKeyword:code("seld"))
        spec.setDescriptor(parent, forKeyword:code("from"))
        guard let result = spec.coerce(toDescriptorType:code("obj ")) else { throw PBError.damaged }
        return result
    }

    public static func inspect(pid: Int32, requestPermission: Bool = false) throws -> Result {
        let supported = ["com.google.Chrome", "com.microsoft.edgemac", "app.gcsa.aegis"]
        guard let app = NSRunningApplication(processIdentifier:pid), let browser = app.bundleIdentifier,
              supported.contains(browser), !app.isTerminated else { throw PBError.invalid("请选择正在运行的 Chrome、Edge 或 Aegis 进程。") }
        let target = Descriptor(processIdentifier:pid)
        let permission = AEDeterminePermissionToAutomateTarget(target.aeDesc,code("core"),code("getd"),requestPermission)
        guard permission == noErr else { throw PBError.invalid("macOS 尚未允许读取此浏览器的原生书签（\(permission)）。") }
        guard let all = Descriptor(descriptorType:code("abso"),data:Descriptor(typeCode:code("all ")).data) else { throw PBError.damaged }
        var rows: [Entry] = [], seen = Set<UUID>(), mixed = 0
        func properties(_ collection: String, in parent: Descriptor) throws -> [Descriptor] {
            guard !app.isTerminated else { throw PBError.unavailable }
            let elements = try object(collection,"indx",all,in:parent)
            let event = Descriptor(eventClass:code("core"),eventID:code("getd"),targetDescriptor:target,returnID:-1,transactionID:0)
            event.setParam(try object("prop","prop",Descriptor(typeCode:code("pALL")),in:elements),forKeyword:code("----"))
            let reply = try event.sendEvent(options:[.waitForReply,.neverInteract],timeout:5)
            guard reply.paramDescriptor(forKeyword:code("errn"))?.int32Value ?? 0 == 0,
                  let list = reply.paramDescriptor(forKeyword:code("----")), list.descriptorType == code("list"),
                  list.numberOfItems <= 50_000 - rows.count else { throw PBError.invalid("浏览器未返回完整的书签列表。") }
            return try (0..<list.numberOfItems).map { index in
                guard let row = list.atIndex(index+1) else { throw PBError.damaged }
                return row
            }
        }
        func walk(_ parent: Descriptor, _ parentIndex: Int, _ depth: Int) throws {
            guard depth <= 64 else { throw PBError.invalid("书签层级超过限制。") }
            var children: [(Int, String, String, String?, String)] = []
            for kind in ["CrBF","CrBI"] {
                for row in try properties(kind,in:parent) {
                    guard let title = row.forKeyword(code("pnam"))?.stringValue,
                          let id = row.forKeyword(code("ID  "))?.stringValue, let uuid = UUID(uuidString:id),
                          seen.insert(uuid).inserted, seen.count <= 50_000,
                          let index = row.forKeyword(code("pidx"))?.int32Value, index > 0 else { throw PBError.damaged }
                    let url = row.forKeyword(code("URL "))?.stringValue
                    guard kind == "CrBF" || url != nil else { throw PBError.damaged }
                    children.append((Int(index),kind,title,url,id))
                }
            }
            children.sort { $0.0 < $1.0 }
            if Set(children.map { $0.1 }).count == 2 { mixed += 1 }
            for (offset,child) in children.enumerated() {
                guard child.0 == offset+1 else { throw PBError.invalid("读取期间书签顺序已变化，请重试。") }
                let childIndex = rows.count
                rows.append(Entry(type:child.1,title:child.2,url:child.3,parent:parentIndex,order:offset))
                if child.1 == "CrBF" {
                    try walk(object("CrBF","ID  ",Descriptor(string:child.4),in:parent),childIndex,depth+1)
                }
            }
        }
        for (index,root) in ["ChBB","ChOB"].enumerated() {
            try walk(object("prop","prop",Descriptor(typeCode:code(root)),in:.null()),-1-index,0)
        }
        let urls = rows.filter { $0.type == "CrBI" }.count
        return Result(browser:browser,bookmarks:urls,folders:rows.count-urls,mixedFolders:mixed,sha256:Crypto.digest(try Coding.encode(rows)))
    }
}
#endif
