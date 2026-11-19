import CryptoKit
import Foundation
import LocalAuthentication
import PBsyncCore
import XCTest
@testable import PBsyncApp

final class MacBiometricUnlockTests: XCTestCase {
    private func fixture() throws -> (URL, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pbsync-enclave-tests-" + UUID().uuidString)
        try SafeFile.privateDirectory(root)
        return (root, root.appendingPathComponent("synthetic.pbsync"))
    }

    // 仅用于解析与文件防护测试的元数据，不表示可通过硬件验证的密钥。
    private func metadata(for file: URL) -> MacBiometricUnlock.Envelope {
        MacBiometricUnlock.Envelope(binding: Crypto.digest(Data(file.standardizedFileURL.path.utf8)),
            handle: Data(repeating: 1, count: 32), peer: P256.KeyAgreement.PrivateKey().publicKey.x963Representation,
            salt: Data(repeating: 2, count: 32), sealed: Data(repeating: 3, count: 60))
    }

    func testEnvelopeRejectsOtherSpaceAndUnsupportedFormat() throws {
        let (root, file) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        var envelope = metadata(for: file)
        try envelope.validate(for: file)
        XCTAssertThrowsError(try envelope.validate(for: root.appendingPathComponent("other.pbsync")))
        envelope.version = 2
        XCTAssertThrowsError(try envelope.validate(for: file))
    }

    func testMetadataRejectsCorruptionAndExcessiveSize() throws {
        let (root, file) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let url = MacBiometricUnlock.storageURL(file)
        try SafeFile.write(Data("{damaged".utf8), to: url)
        XCTAssertThrowsError(try MacBiometricUnlock.load(file))
        XCTAssertFalse(BiometricUnlock.configured(file))
        try SafeFile.write(Data(repeating: 0, count: 65_537), to: url)
        XCTAssertThrowsError(try MacBiometricUnlock.load(file))
    }

    func testMetadataRequiresPrivateRegularFile() throws {
        let (root, file) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let url = MacBiometricUnlock.storageURL(file)
        try SafeFile.write(JSONEncoder().encode(metadata(for: file)), to: url)
        XCTAssertNoThrow(try MacBiometricUnlock.load(file))
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
        XCTAssertThrowsError(try MacBiometricUnlock.load(file))
        try FileManager.default.removeItem(at: url)
        let target = root.appendingPathComponent("symlink-target")
        try SafeFile.write(JSONEncoder().encode(metadata(for: file)), to: target)
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: target)
        XCTAssertThrowsError(try MacBiometricUnlock.load(file))
    }

    func testDisableOnlyRemovesCurrentSpaceRecord() throws {
        let (root, file) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let other = root.appendingPathComponent("other.pbsync")
        for item in [file, other] {
            try SafeFile.write(JSONEncoder().encode(metadata(for: item)), to: MacBiometricUnlock.storageURL(item))
        }
        try BiometricUnlock.remove(file)
        XCTAssertFalse(FileManager.default.fileExists(atPath: MacBiometricUnlock.storageURL(file).path))
        XCTAssertNoThrow(try MacBiometricUnlock.load(other))
        XCTAssertNoThrow(try BiometricUnlock.remove(file))
    }

    func testSymbolicDirectoryCannotReadOrRemoveOutsideRecord() throws {
        let (root, file) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let url = MacBiometricUnlock.storageURL(file)
        let outside = root.appendingPathComponent("outside", isDirectory: true)
        try SafeFile.privateDirectory(outside)
        let target = outside.appendingPathComponent(url.lastPathComponent)
        try SafeFile.write(JSONEncoder().encode(metadata(for: file)), to: target)
        try FileManager.default.createSymbolicLink(at: url.deletingLastPathComponent(), withDestinationURL: outside)
        XCTAssertThrowsError(try MacBiometricUnlock.load(file))
        XCTAssertThrowsError(try MacBiometricUnlock.remove(file))
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.path))
    }

    func testHardwareRejectsUnauthenticatedReadAndPreservesPriorRecord() throws {
        let (root, file) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let context = LAContext(); context.interactionNotAllowed = true
        let key = Data(repeating: 0x53, count: 32)
        let url = MacBiometricUnlock.storageURL(file)
        let previous = Data("previous-synthetic-record".utf8)
        try SafeFile.write(previous, to: url)
        if SecureEnclave.isAvailable && context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil) {
            let envelope = try MacBiometricUnlock.makeEnvelope(key, file: file, authentication: context)
            XCTAssertThrowsError(try MacBiometricUnlock.open(envelope, file: file, authentication: context))
        }
        XCTAssertThrowsError(try MacBiometricUnlock.save(key, file: file, authentication: context))
        XCTAssertEqual(try Data(contentsOf: url), previous, "认证失败不能覆盖已有记录")
    }
}
