import XCTest
@testable import PBsyncCore

extension CoreTests {
    func testAuthenticatedLazyAttachmentAndCompleteRecovery() async throws {
        let root = try temporary(), (first,_) = try await makeStore(root)
        let dir = root.appendingPathComponent("remote"); try SafeFile.privateDirectory(dir)
        let remote = FolderStorage(directory:dir)
        let bytes = Data(repeating:0xa7,count:10*1024*1024-1)
        var item = login()
        item.attachments = [try Attachment(name:"同名.bin",data:bytes),try Attachment(name:"同名.bin",data:Data())]
        let saved = try await first.attachedItem(item)
        _ = try await first.save(saved); _ = try await first.synchronize(with:remote)
        let names = try await remote.list()
        let name = try XCTUnwrap(names.first(where:{$0.hasSuffix(".pbatt")}))
        let remoteHeader = try await remote.read("space.pbsync")
        XCTAssertLessThan(remoteHeader.data.count,65536)
        let file = root.appendingPathComponent("second.pbsync")
        let second = try await VaultStore.connect(storage:remote,fileURL:file,password:password,deviceID:UUID())
        let state = try await second.snapshot(), ref = try XCTUnwrap(state.items.first?.attachments.first)
        XCTAssertEqual(ref.remoteSize,bytes.count); XCTAssertTrue(ref.data.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath:file.appendingPathExtension("attachments").path))
        let blob = try await remote.read(name)
        try SafeFile.write(Data(blob.data.dropLast(1)),to:dir.appendingPathComponent(name))
        do { _ = try await second.attachmentBytes(ref,storage:remote); XCTFail("截断附件被错误接受") } catch {}
        do { _ = try await second.exportArchive(storage:remote); XCTFail("不能导出不完整备份") } catch {}
        try SafeFile.write(blob.data,to:dir.appendingPathComponent(name))
        let fetched = try await second.attachmentBytes(ref,storage:remote); XCTAssertEqual(fetched,bytes)
        _ = try await second.delete(item.id); _ = try await second.restore(state.revisions[0].id)
        let full = try await second.exportArchive()
        let archive = try Coding.decode(Archive.self,from:full)
        let recovered = try Crypto.restore(archive,key:Crypto.unlock(archive.header,password:password))
        XCTAssertEqual(recovered.items[0].attachments.map(\.data),[bytes,Data()])
        XCTAssertTrue(recovered.revisions.allSatisfy{$0.item.attachments[0].data == bytes})
    }
}
