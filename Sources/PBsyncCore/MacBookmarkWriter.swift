#if os(macOS)
import AppKit
import ApplicationServices

/// 只接受本浏览器宿主的叶子书签操作。配置文件只用于将扩展的数字标识对应到原生 GUID。
public enum MacBookmarkWriter {
    public struct Leaf: Codable, Equatable { let id: String; let title: String; let url: String }
    public struct Request: Decodable {
        let runtimeVersions: [String]?
        let operation: String
        let parent: String
        let children: [Leaf]
        let index: Int
        let title: String?
        let url: String?
    }
    private struct Node: Decodable {
        let id: String
        let guid: String
        let name: String
        let type: String
        let url: String?
        let children: [Node]?
    }
    private struct FileTree: Decodable { let roots: [String:Node] }
    private typealias AE = NSAppleEventDescriptor
    private static func code(_ s: String) -> UInt32 { s.utf8.reduce(0) { ($0 << 8) | UInt32($1) } }
    private static func object(_ kind: String,_ form: String,_ selector: AE,_ parent: AE) throws -> AE {
        let r=AE.record()
        for (key,value) in [("want",AE(typeCode:code(kind))),("form",AE(enumCode:code(form))),("seld",selector),("from",parent)] {
            r.setDescriptor(value,forKeyword:code(key))
        }
        guard let spec=r.coerce(toDescriptorType:code("obj ")) else { throw PBError.unsupported }
        return spec
    }
    private static func send(_ event: String, to target: AE, _ params: [String:AE]) throws -> AE {
        let query=AE(eventClass:code("core"),eventID:code(event),targetDescriptor:target,returnID:-1,transactionID:0)
        for (key,value) in params { query.setParam(value,forKeyword:code(key)) }
        let reply=try query.sendEvent(options:[.waitForReply,.neverInteract],timeout:5)
        guard reply.paramDescriptor(forKeyword:code("errn"))?.int32Value ?? 0 == 0 else { throw PBError.conflict }
        return reply.paramDescriptor(forKeyword:code("----")) ?? .null()
    }
    private static func location(_ id: String, in node: Node, at path: AE) throws -> (Node,AE)? {
        if node.id == id { return (node,path) }
        for sub in node.children ?? [] where sub.type == "folder" {
            let next=try object("CrBF","ID  ",AE(string:sub.guid),path)
            if let found=try location(id,in:sub,at:next) { return found }
        }
        return nil
    }

    public static func requestAccess(browserPID: Int32) -> Int32 {
        guard let app=NSRunningApplication(processIdentifier:browserPID), let id=app.bundleIdentifier,
              ["com.google.Chrome","com.microsoft.edgemac","app.gcsa.aegis"].contains(id) else { return -600 }
        let target=AE(processIdentifier:browserPID)
        return AEDeterminePermissionToAutomateTarget(target.aeDesc,typeWildCard,typeWildCard,true)
    }

    // fallback 只在没有发送写事件时返回。已送出但回执不确定时，由扩展先查实际树。
    public static func perform(_ request: Request, profile: URL, browserPID: Int32) -> String {
        guard let app=NSRunningApplication(processIdentifier:browserPID), !app.isTerminated,
              let bundle=app.bundleURL.flatMap({ Bundle(url:$0) }), let id=bundle.bundleIdentifier,
              let version=bundle.object(forInfoDictionaryKey:"CFBundleShortVersionString") as? String else { return "fallback:未识别宿主进程" }
        guard
              ["com.google.Chrome":["156.0.8078.81"],"com.microsoft.edgemac":["156.0.4314.58"],"app.gcsa.aegis":["155.0.8059.40"]][id]?.contains(version)==true,
              request.runtimeVersions?.contains(version) == true, ["create","rename","delete"].contains(request.operation),
              !request.children.isEmpty, request.children.count <= 3000,
              request.children.indices.contains(request.index) else { return "fallback:版本或操作范围" }
        let target=AE(processIdentifier:browserPID)
        let permission = AEDeterminePermissionToAutomateTarget(target.aeDesc,typeWildCard,typeWildCard,false)
        guard permission == noErr else { return "fallback:系统权限 \(permission)" }
        var dispatched=false
        do {
            let state=try JSONSerialization.jsonObject(with:Data(contentsOf:profile.deletingLastPathComponent().appendingPathComponent("Local State"))) as? [String:Any]
            let info=state?["profile"] as? [String:Any]
            guard let profiles=info?["info_cache"] as? [String:Any], Set(profiles.keys)==[profile.lastPathComponent],
                  (info?["last_used"] as? String ?? "Default")==profile.lastPathComponent else { return "fallback:配置身份未确认" }
            let recordedVersion = try String(contentsOf:profile.deletingLastPathComponent().appendingPathComponent("Last Version"),encoding:.utf8)
            guard recordedVersion.trimmingCharacters(in:.whitespacesAndNewlines) == version else { return "fallback:运行版本不同" }
            let tree=try JSONDecoder().decode(FileTree.self,from:Data(contentsOf:profile.appendingPathComponent("Bookmarks")))
            var found:(Node,AE)?
            for (root,property) in [("bookmark_bar","ChBB"),("other","ChOB")] {
                guard let node=tree.roots[root] else { return "fallback" }
                if let match=try location(request.parent,in:node,at:object("prop","prop",AE(typeCode:code(property)),.null())) {
                    guard found==nil else { return "fallback" }
                    found=match
                }
            }
            guard let (parent,path)=found,let children=parent.children,children.count==request.children.count,
                  zip(children,request.children).allSatisfy({ n,r in n.type=="url" && n.id==r.id && n.name==r.title && n.url==r.url && UUID(uuidString:n.guid) != nil }),
                  let all=AE(descriptorType:code("abso"),data:AE(typeCode:code("all ")).data) else { return "fallback" }
            func props(_ kind:String) throws -> AE {
                let collection=try object(kind,"indx",all,path)
                let property=try object("prop","prop",AE(typeCode:code("pALL")),collection)
                return try send("getd",to:target,["----":property])
            }
            let folders=try props("CrBF"),live=try props("CrBI")
            guard folders.descriptorType==code("list"),folders.numberOfItems==0,live.descriptorType==code("list"),
                  live.numberOfItems==children.count else { return "fallback" }
            for (index,n) in children.enumerated() {
                let row=live.atIndex(index+1)
                guard row?.forKeyword(code("ID  "))?.stringValue?.lowercased()==n.guid.lowercased(),
                      row?.forKeyword(code("pnam"))?.stringValue==n.name,row?.forKeyword(code("URL "))?.stringValue==n.url,
                      row?.forKeyword(code("pidx"))?.int32Value==Int32(index+1) else { return "fallback" }
            }
            let anchor=try object("CrBI","ID  ",AE(string:children[request.index].guid),path)
            let event:String,params:[String:AE]
            switch request.operation {
            case "create":
                guard let title=request.title,let url=request.url, let scheme=URLComponents(string:url)?.scheme?.lowercased(),
                      ["http","https"].contains(scheme),title.utf8.count<=8192,url.utf8.count<=32768 else { return "fallback" }
                let insert=AE.record(),properties=AE.record()
                insert.setDescriptor(anchor,forKeyword:code("kobj"));insert.setDescriptor(AE(enumCode:code("befo")),forKeyword:code("kpos"))
                guard let spec=insert.coerce(toDescriptorType:code("insl")) else { return "fallback" }
                properties.setDescriptor(AE(string:title),forKeyword:code("pnam"));properties.setDescriptor(AE(string:url),forKeyword:code("URL "))
                event="crel";params=["kocl":AE(typeCode:code("CrBI")),"insh":spec,"prdt":properties]
            case "rename":
                guard let title=request.title,title.utf8.count<=8192 else { return "fallback" }
                event="setd";params=["----":try object("prop","prop",AE(typeCode:code("pnam")),anchor),"data":AE(string:title)]
            default: event="delo";params=["----":anchor]
            }
            guard !app.isTerminated else { return "fallback" }
            dispatched=true
            _=try send(event,to:target,params)
            return "sent"
        } catch { return dispatched ? "uncertain" : "fallback:读前核对 \((error as NSError).code)" }
    }
}
#endif
