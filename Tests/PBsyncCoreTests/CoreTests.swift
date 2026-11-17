import XCTest
import Foundation
import CryptoKit
@testable import PBsyncCore

final class CoreTests: XCTestCase {
    let password = "仅用于合成测试-TestPassword-2026"
    func temporary() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pbsync-tests-" + UUID().uuidString)
        try SafeFile.privateDirectory(url); addTeardownBlock { try? FileManager.default.removeItem(at: url) }; return url
    }
    func makeStore(_ directory: URL, name: String = "space", kind: SpaceKind = .vault) async throws -> (VaultStore,String) {
        let (store, recovery) = try VaultStore.create(fileURL: directory.appendingPathComponent(name + ".pbsync"), name: name, kind: kind, password: password, deviceID: UUID())
        try await store.unlock(password: password); return (store,recovery)
    }
    func login(id: UUID = UUID(), title: String = "合成账号", value: String = "SYNTHETIC-SECRET") -> Item {
        Item(id: id, kind: .login, title: title, urls: ["https://example.com"], fields: ["username":"test@example.invalid","password":value], notes: "中文备注", sourceData: ["unknown":Data([1,2,3])])
    }
    func testPBKDF2KnownAnswer() throws {
        let key = try Crypto.derive(password: "password", salt: Data("salt-salt-salt-123".utf8), iterations: 1)
        // 独立 Python hashlib.pbkdf2_hmac 结果会在统一验收中比对。
        XCTAssertEqual(key.bitCount,256)
        let raw = key.withUnsafeBytes { Data($0) }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        try SafeFile.write(raw, to: root.appendingPathComponent("build/pbkdf-vector.bin"))
    }
    func testEncryptionRecoveryAndTamper() throws {
        let created = try Crypto.create(password: password)
        let data = Data("SYNTHETIC-PLAINTEXT".utf8)
        let sealed = try Crypto.seal(data,key:created.key,context:created.header.context("test"))
        XCTAssertEqual(try Crypto.open(sealed,key:Crypto.unlock(created.header,password:password),context:created.header.context("test")),data)
        XCTAssertEqual(try Crypto.open(sealed,key:Crypto.recover(created.header,recovery:created.recovery),context:created.header.context("test")),data)
        XCTAssertThrowsError(try Crypto.unlock(created.header,password:"incorrect-password"))
        XCTAssertThrowsError(try Crypto.recover(created.header,recovery:Data(repeating:0,count:32).base64EncodedString()))
        var corrupt = sealed;corrupt[corrupt.count-1] ^= 1
        XCTAssertThrowsError(try Crypto.open(corrupt,key:created.key,context:created.header.context("test")))
        XCTAssertThrowsError(try Crypto.open(sealed,key:created.key,context:Data("other".utf8)))
        XCTAssertNotEqual(try Crypto.seal(data,key:created.key,context:Data()),try Crypto.seal(data,key:created.key,context:Data()))
    }
    func testHeaderLimitsAndPasswordRewrap() throws {
        let created=try Crypto.create(password:password)
        var invalid=created.header;invalid.iterations=UInt32.max
        XCTAssertThrowsError(try Crypto.unlock(invalid,password:password))
        invalid=created.header;invalid.format=999;XCTAssertThrowsError(try invalid.validate())
        let header=try Crypto.rewrap(created.header,key:created.key,newPassword:"new-password-2026")
        XCTAssertThrowsError(try Crypto.unlock(header,password:password))
        XCTAssertEqual(try Crypto.unlock(header,password:"new-password-2026").withUnsafeBytes { Data($0) },created.key.withUnsafeBytes { Data($0) })
        XCTAssertEqual(try Crypto.recover(header,recovery:created.recovery).withUnsafeBytes { Data($0) },created.key.withUnsafeBytes { Data($0) })
    }
    func testCrossSpaceOperationRejected() throws {
        let a=try Crypto.create(password:password),b=try Crypto.create(password:password)
        let revision=Revision(deviceID:UUID(),time:.init(milliseconds:1),item:login())
        let object=try Crypto.encrypt(revision,header:a.header,key:a.key)
        XCTAssertThrowsError(try Crypto.decrypt(object,header:b.header,key:a.key))
        var replaced=object;replaced.id=UUID()
        XCTAssertThrowsError(try Crypto.decrypt(replaced,header:a.header,key:a.key))
    }
    func testMergeConvergesAcross100Permutations() throws {
        let id=UUID(),device=UUID()
        let base=Revision(deviceID:device,time:.init(milliseconds:100),item:login(id:id,value:"base"))
        let a=Revision(deviceID:UUID(),time:.init(milliseconds:200),parents:[base.id],item:login(id:id,value:"A"))
        let b=Revision(deviceID:UUID(),time:.init(milliseconds:200),parents:[base.id],item:login(id:id,value:"B"))
        let c=Revision(deviceID:UUID(),time:.init(milliseconds:201),parents:[a.id,b.id],item:login(id:id,value:"resolved"))
        var canonical=SpaceState(name:"test",kind:.vault);try canonical.merge([base,a,b,c])
        for _ in 0..<100 {var state=SpaceState(name:"test",kind:.vault);try state.merge([base,a,b,c].shuffled());try state.merge([a,b,c]);XCTAssertEqual(state,canonical)}
        XCTAssertEqual(canonical.items.first?.fields["password"],"resolved")
        XCTAssertEqual(canonical.history(for:id).count,4)
    }
    func testMergeRejectsMissingParentDuplicateIDAndWrongSpace() throws {
        let item=login(),r=Revision(deviceID:UUID(),time:.init(milliseconds:10),parents:[UUID()],item:login())
        var state=SpaceState(name:"t",kind:.vault)
        XCTAssertThrowsError(try state.merge([r]));XCTAssertTrue(state.revisions.isEmpty)
        let base=Revision(deviceID:UUID(),time:.init(milliseconds:1),item:item);try state.merge([base])
        var fake=base;fake.item.title="changed";XCTAssertThrowsError(try state.merge([fake]));XCTAssertEqual(state.revisions,[base])
        let folder=Revision(deviceID:UUID(),time:.init(milliseconds:2),item:Item(kind:.folder,title:"错误类型"))
        XCTAssertThrowsError(try state.merge([folder]))
    }
    func testLogicalClockHandlesRollbackAndTie() {
        let clock=LogicalTime(milliseconds:10000,counter:8)
        XCTAssertGreaterThan(clock.next(now:Date(timeIntervalSince1970:1)),clock)
        let later=clock.next(now:Date(timeIntervalSince1970:20));XCTAssertEqual(later.milliseconds,20000);XCTAssertEqual(later.counter,0)
    }
    func testBookmarkCyclesAndOrphansStayAccessible() throws {
        let a=UUID(),b=UUID()
        let items=[Item(id:a,kind:.folder,title:"A",parentID:b),Item(id:b,kind:.folder,title:"B",parentID:a),Item(kind:.bookmark,title:"孤立",parentID:UUID(),urls:["https://example.com"])]
        var state=SpaceState(name:"t",kind:.bookmarks)
        try state.merge(items.map {Revision(deviceID:UUID(),time:.init(milliseconds:1),item:$0)})
        XCTAssertEqual(state.items.count,3)
        for item in items {XCTAssertNil(state.effectiveParent(of:item))}
        XCTAssertNoThrow(try BookmarkHTML.export(state))
    }
    func testCSVQuotedUnicodeCRLFRoundTrip() throws {
        let data=Data("\u{FEFF}name,url,username,password,note,未知\r\n\"中,文\",https://example.com,user,\"p\"\"ass\",\"第一行\r\n第二行\",保留\r\n".utf8)
        let preview=try PasswordCSV.parse(data);XCTAssertEqual(preview.items.count,1)
        XCTAssertEqual(preview.items[0].fields["password"],"p\"ass");XCTAssertEqual(preview.items[0].title,"中,文")
        XCTAssertFalse(preview.items[0].sourceData.isEmpty)
        var state=SpaceState(name:"test",kind:.vault);try state.merge(preview.items.map {Revision(deviceID:UUID(),time:.init(milliseconds:1),item:$0)})
        let copy=try PasswordCSV.parse(PasswordCSV.export(state));XCTAssertEqual(copy.items[0].fields,preview.items[0].fields);XCTAssertEqual(copy.items[0].notes,preview.items[0].notes)
        XCTAssertThrowsError(try PasswordCSV.rows("name,password\n\"unfinished"))
        XCTAssertThrowsError(try PasswordCSV.parse(Data("name,password\none,two,three".utf8)))
    }
    func testHTMLFoldersDuplicateURLAndUnsafeLink() throws {
        let html="<DL><p><DT><H3>中文 &amp; 文件夹</H3><DL><p><DT><A HREF=\"https://example.com\">一</A><DT><A HREF=\"https://example.com\">一</A></DL><DT><A HREF='javascript:alert(1)'>危险</A></DL>"
        let preview=try BookmarkHTML.parse(Data(html.utf8));XCTAssertEqual(preview.items.count,4)
        XCTAssertEqual(Set(preview.items.map(\.id)).count,4);XCTAssertEqual(preview.warnings.count,1)
        XCTAssertEqual(preview.items[1].parentID,preview.items[0].id)
        XCTAssertEqual(try BookmarkHTML.parse(Data(html.utf8)).items,preview.items)
        XCTAssertFalse(CredentialPolicy.safeBookmarkURL("javascript:alert(1)"))
        let deep=String(repeating:"<DL>",count:65);XCTAssertThrowsError(try BookmarkHTML.parse(Data(deep.utf8)))
    }
    func testTOTPIndependentRFC6238Vectors() throws {
        let config=OTPConfiguration(secret:"GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ",digits:8)
        for (time,answer) in [(59.0,"94287082"),(1111111109.0,"07081804"),(1111111111.0,"14050471"),(1234567890.0,"89005924"),(2000000000.0,"69279037"),(20000000000.0,"65353130")] {XCTAssertEqual(try config.code(at:time),answer)}
        XCTAssertThrowsError(try OTPConfiguration(secret:"invalid!").code())
        XCTAssertThrowsError(try OTPConfiguration(uri:"otpauth://totp/a?secret=X&secret=Y"))
    }
    func testCredentialMatchingRejectsImpostorsAndPorts() {
        let item=login()
        XCTAssertTrue(CredentialPolicy.matches(item:item,pageURL:"https://example.com/login"))
        for value in ["http://example.com","https://example.com.evil.test","https://evil.test/?next=https://example.com","https://example.com:444","https://user@example.com","https://sub.example.com"] {XCTAssertFalse(CredentialPolicy.matches(item:item,pageURL:value))}
        XCTAssertTrue(CredentialPolicy.matchesDomain(item:item,domain:"EXAMPLE.COM"))
        XCTAssertFalse(CredentialPolicy.matchesDomain(item:item,domain:"example.com/"))
    }
    func testPasskeySignsChallengeAndSerializesForIndependentVerification() throws {
        let material=try PasskeyMaterial(relyingParty:"example.com",userName:"test",userHandle:Data("test-user".utf8))
        let hash=Data(SHA256.hash(data:Data("synthetic-challenge".utf8)))
        let response=try material.assertion(clientDataHash:hash)
        let publicKey=try P256.Signing.PrivateKey(rawRepresentation:material.privateKey).publicKey
        XCTAssertTrue(publicKey.isValidSignature(try P256.Signing.ECDSASignature(derRepresentation:response.signature),for:response.authenticatorData+hash))
        XCTAssertFalse(publicKey.isValidSignature(try P256.Signing.ECDSASignature(derRepresentation:response.signature),for:response.authenticatorData+Data(repeating:0,count:32)))
        let registration=try material.registration();XCTAssertEqual(registration.authenticatorData.prefix(32),Data(SHA256.hash(data:Data("example.com".utf8))))
        XCTAssertEqual(registration.authenticatorData[32],0x5d)
        let root=URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        try SafeFile.write(Coding.encode(["publicKey":publicKey.x963Representation,"authenticatorData":response.authenticatorData,"clientDataHash":hash,"signature":response.signature,"attestation":registration.attestationObject]),to:root.appendingPathComponent("build/passkey-vector.json"))
    }
    func testPairingExpiresAndRejectsReplayOrWrongFingerprint() throws {
        let session=PairingSession(),payload=Data("synthetic-pairing-payload".utf8)
        XCTAssertThrowsError(try PairingSession.respond(to:session.invitation,payload:payload,confirmedFingerprint:"incorrect"))
        let response=try PairingSession.respond(to:session.invitation,payload:payload,confirmedFingerprint:PairingSession.fingerprint(session.invitation))
        XCTAssertEqual(try session.receive(response),payload)
        XCTAssertThrowsError(try session.receive(response))
        let expired=PairingInvitation(publicKey:Data(repeating:1,count:32),expiresAt:Date().addingTimeInterval(-1))
        XCTAssertThrowsError(try PairingSession.respond(to:expired,payload:payload,confirmedFingerprint:PairingSession.fingerprint(expired)))
    }
    func testBridgeEncryptionContextAndExpiry() throws {
        let token=try Crypto.random(32),payload=Data("{\"command\":\"test\"}".utf8)
        let wire=try BridgeWire.make(payload:payload,token:token)
        XCTAssertEqual(try wire.open(token:token),payload)
        XCTAssertThrowsError(try wire.open(token:try Crypto.random(32)))
        XCTAssertThrowsError(try wire.open(token:token,response:true))
        XCTAssertThrowsError(try wire.open(token:token,now:Date().addingTimeInterval(200)))
        let reply=try BridgeWire.make(payload:payload,token:token,responseTo:wire)
        XCTAssertEqual(try reply.open(token:token,response:true),payload)
    }
    func testLocalHistoryDeleteRestoreAndSecretNeverStoredPlaintext() async throws {
        let root=try temporary(),(store,_)=try await makeStore(root)
        let item=login();let original=try await store.save(item)
        var edited=item;edited.fields["password"]="new-secret";_ = try await store.save(edited)
        _ = try await store.delete(item.id);var state=try await store.snapshot();XCTAssertEqual(state.items.count,0)
        try await store.restore(original.id);state=try await store.snapshot()
        XCTAssertEqual(state.items.first?.fields["password"],"SYNTHETIC-SECRET");XCTAssertEqual(state.revisions.count,4)
        let bytes=try await store.exportArchive();XCTAssertFalse(String(decoding:bytes,as:UTF8.self).contains("SYNTHETIC-SECRET"))
        await store.lock()
        do {_ = try await store.snapshot();XCTFail("锁定后不得访问")}catch{XCTAssertEqual(error as? PBError,.locked)}
    }
    func testTwoInstancesDoNotLoseConcurrentLocalEdits() async throws {
        let root=try temporary(),(first,_)=try await makeStore(root)
        let second=try VaultStore(fileURL:root.appendingPathComponent("space.pbsync"),deviceID:UUID());try await second.unlock(password:password)
        async let a=first.save(login(title:"A"));async let b=second.save(login(title:"B"));_ = try await(a,b)
        let state=try await first.snapshot();XCTAssertEqual(state.items.count,2)
    }
    func testFolderSyncOfflineEditsAndRecovery() async throws {
        let root=try temporary(),(first,recovery)=try await makeStore(root,name:"first")
        let remote=root.appendingPathComponent("remote");try SafeFile.privateDirectory(remote);let storage=FolderStorage(directory:remote)
        _ = try await first.save(login(title:"initial"));_ = try await first.synchronize(with:storage)
        let second=try await VaultStore.connect(storage:storage,fileURL:root.appendingPathComponent("second.pbsync"),password:password,deviceID:UUID())
        _ = try await first.save(login(title:"offline-A"));_ = try await second.save(login(title:"offline-B"))
        _ = try await second.synchronize(with:storage);_ = try await first.synchronize(with:storage);_ = try await second.synchronize(with:storage)
        let a=try await first.snapshot(),b=try await second.snapshot();XCTAssertEqual(a,b);XCTAssertEqual(a.items.count,3)
        let backup=try await first.exportArchive(),archive=try Coding.decode(Archive.self,from:backup)
        XCTAssertEqual(try Crypto.restore(archive,key:Crypto.recover(archive.header,recovery:recovery)),a)
        let repeated=try await first.synchronize(with:storage);XCTAssertEqual(repeated.uploaded,0);XCTAssertEqual(repeated.downloaded,0)
    }
    func testRemoteTamperDoesNotOverwriteLocalData() async throws {
        let root=try temporary(),(store,_)=try await makeStore(root),remote=root.appendingPathComponent("remote")
        try SafeFile.privateDirectory(remote);let storage=FolderStorage(directory:remote)
        _ = try await store.synchronize(with:storage);_ = try await store.save(login());_ = try await store.synchronize(with:storage)
        let before=try await store.snapshot(),names=try await storage.list()
        let name=try XCTUnwrap(names.first(where:{$0.hasSuffix(".pbop")})),blob=try await storage.read(name)
        var object=try Coding.decode(EncryptedObject.self,from:blob.data);object.sealed[0] ^= 1
        try await storage.replace(name,data:Coding.encode(object),version:blob.version!)
        do{_ = try await store.synchronize(with:storage);XCTFail("篡改应拒绝")}catch{}
        let after=try await store.snapshot();XCTAssertEqual(before,after)
    }
    func testFolderConditionalWritesAndPathTraversal() async throws {
        let root=try temporary(),storage=FolderStorage(directory:root),name="space.pbsync"
        try await storage.create(name,data:Data("first".utf8))
        do{try await storage.create(name,data:Data());XCTFail()}catch{XCTAssertEqual(error as? PBError,.conflict)}
        do{try await storage.replace(name,data:Data(),version:"wrong");XCTFail()}catch{XCTAssertEqual(error as? PBError,.conflict)}
        do{_ = try await storage.read("../secret");XCTFail()}catch{}
        let readback = try await storage.read(name);XCTAssertEqual(readback.data,Data("first".utf8))
    }
    func testAttachmentUnknownFieldsAndFullArchiveRecovery() async throws {
        let root=try temporary(),(store,recovery)=try await makeStore(root)
        var item=login();item.attachments=[try Attachment(name:"测试附件.txt",data:Data("附件内容".utf8)),try Attachment(name:"空文件",data:Data())]
        _ = try await store.save(item)
        let archive=try Coding.decode(Archive.self,from:await store.exportArchive())
        let restored=try Crypto.restore(archive,key:Crypto.recover(archive.header,recovery:recovery))
        XCTAssertEqual(restored.items,[item])
        var invalid=item;invalid.attachments[0].data.append(1)
        do{_ = try await store.save(invalid);XCTFail()}catch{}
        let after=try await store.snapshot();XCTAssertEqual(after.items,[item])
    }
    func testImportIsIdempotentAndDoesNotDeleteMissingRecords() async throws {
        let root=try temporary(),(store,_)=try await makeStore(root,kind:.bookmarks)
        let first=try BookmarkHTML.parse(Data("<DL><A HREF='https://example.com/a'>A</A><A HREF='https://example.com/b'>B</A></DL>".utf8))
        let inserted = try await store.importItems(first.items);XCTAssertEqual(inserted,2)
        let repeated = try await store.importItems(first.items);XCTAssertEqual(repeated,0)
        let subset = try await store.importItems([first.items[0]]);XCTAssertEqual(subset,0)
        let state=try await store.snapshot();XCTAssertEqual(state.items.count,2)
    }
    func testMigrationRotatesKeyAndFreezesOldStorage() async throws {
        let root=try temporary(),(store,_)=try await makeStore(root),oldURL=root.appendingPathComponent("old"),newURL=root.appendingPathComponent("new")
        try SafeFile.privateDirectory(oldURL);try SafeFile.privateDirectory(newURL)
        let old=FolderStorage(directory:oldURL),new=FolderStorage(directory:newURL)
        _ = try await store.save(login());_ = try await store.synchronize(with:old)
        let oldDevice=try await VaultStore.connect(storage:old,fileURL:root.appendingPathComponent("old-device.pbsync"),password:password,deviceID:UUID())
        let recovery=try await store.migrate(from:old,to:new,newPassword:"new-migrated-password")
        let state=try await store.snapshot();XCTAssertEqual(state.items.count,1);XCTAssertEqual(state.generation,2)
        let connected=try await VaultStore.connect(storage:new,fileURL:root.appendingPathComponent("new-device.pbsync"),password:"new-migrated-password",deviceID:UUID())
        let newState=try await connected.snapshot();XCTAssertEqual(newState,state)
        let archive=try Coding.decode(Archive.self,from:await new.read("space.pbsync").data)
        XCTAssertNoThrow(try Crypto.recover(archive.header,recovery:recovery))
        do{_ = try await oldDevice.synchronize(with:old);XCTFail()}catch{}
    }
    func testIndependentSpaceLocks() async throws {
        let root=try temporary(),(bookmarks,_)=try await makeStore(root,name:"bookmarks",kind:.bookmarks),(vault,_)=try await makeStore(root,name:"vault")
        await vault.lock();let bookmarkUnlocked = await bookmarks.isUnlocked(), vaultUnlocked = await vault.isUnlocked();XCTAssertTrue(bookmarkUnlocked);XCTAssertFalse(vaultUnlocked)
    }
    func testDeviceKeyUnlockOnlyOpensItsOwnEncryptedArchive() async throws {
        let root = try temporary()
        let (vault, _) = try await makeStore(root, name: "vault")
        let (bookmarks, _) = try await makeStore(root, name: "bookmarks", kind: .bookmarks)
        let item = login()
        _ = try await vault.save(item)
        let key = try await vault.deviceUnlockKey()
        await vault.lock()
        await bookmarks.lock()
        do {
            try await bookmarks.unlock(deviceKey: key)
            XCTFail("密码库的解锁密钥不应打开收藏夹")
        } catch {}
        let otherUnlocked = await bookmarks.isUnlocked()
        XCTAssertFalse(otherUnlocked)
        try await vault.unlock(deviceKey: key)
        let snapshot = try await vault.snapshot()
        XCTAssertEqual(snapshot.items.map(\.id), [item.id])
    }
    func testWebDAVAndCloudWhenLocalServiceProvided() async throws {
        guard let address=ProcessInfo.processInfo.environment["PBSYNC_TEST_DAV_URL"],let url=URL(string:address) else { throw XCTSkip("本地服务集成由 scripts/validate.py 单独启动执行") }
        let storage=try WebDAVStorage(url:url,username:"test-user",password:"synthetic-dav-secret-2026")
        let root=try temporary(),(store,_)=try await makeStore(root)
        _ = try await store.save(login());_ = try await store.synchronize(with:storage)
        let second=try await VaultStore.connect(storage:storage,fileURL:root.appendingPathComponent("other.pbsync"),password:password,deviceID:UUID())
        let state=try await second.snapshot();XCTAssertEqual(state.items.count,1)
    }
}

extension CoreTests {
    func testExternalSourceThreeWayAndMissing() async throws {
        let (store, _) = try await makeStore(temporary())
        let source = "keepass:test"
        var remote = login(id: Coding.stableID(source + ":entry"))
        remote.sourceData = [source: Data("original".utf8), "pbsync.external-id": Data("entry".utf8)]
        func read(_ rows: [Item], apply: Bool = true) async throws -> SourceChanges {
            try await store.reconcileSource(.init(items: rows, source: source), apply: apply)
        }
        let preview = try await read([remote], apply: false)
        let empty = try await store.snapshot()
        XCTAssertEqual(preview.imported, 1)
        XCTAssertTrue(empty.items.isEmpty)
        let first = try await read([remote])
        let repeated = try await read([remote])
        XCTAssertEqual(first.imported, 1)
        XCTAssertEqual(repeated.imported, 0)
        remote.title = "来源更新"
        let update = try await read([remote])
        XCTAssertEqual(update.imported, 1)
        var local = try await store.snapshot().items[0]
        local.fields["password"] = "local"
        _ = try await store.save(local)
        let candidate = try await read([remote])
        XCTAssertEqual(candidate.patches.first?["password"], "local")
        remote.fields["password"] = "remote"
        let conflict = try await read([remote])
        XCTAssertEqual(conflict.conflicts, 1)
        let missing = try await read([])
        XCTAssertEqual(missing.missing, 1)
        let state = try await store.snapshot()
        XCTAssertEqual(state.items[0].fields["password"], "local")
    }

    func testChineseSimulatorSafariExport() throws {
        let root = URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf:root.appendingPathComponent("fixtures/safari-zh-simulator.zip"))
        let result = try SafariBookmarks.preview(data)
        XCTAssertEqual(result.items.map(\.title), ["个人收藏"])
    }

    func testSafariZIPRoundTrip() async throws {
        let (store, _) = try await makeStore(temporary(), kind: .bookmarks)
        let folder = Item(kind: .folder, title: "验收目录")
        _ = try await store.save(folder)
        _ = try await store.save(Item(kind:.bookmark,title:"中文书签",parentID:folder.id,urls:["https://example.invalid/test"]))
        let zip = try SafariBookmarks.export(await store.snapshot())
        let preview = try SafariBookmarks.preview(zip)
        XCTAssertEqual(preview.items.count, 2)
        XCTAssertEqual(preview.items.last?.parentID, preview.items.first?.id)
        XCTAssertEqual(preview.items.last?.title, "中文书签")
        XCTAssertThrowsError(try SafariBookmarks.preview(zip.prefix(10)))
    }
}
