import Foundation
import LocalAuthentication
import PBsyncCore
import Security

enum BiometricUnlock {
    static var name: String? {
        let context = LAContext()
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil) else { return nil }
        switch context.biometryType {
        case .faceID: return "Face ID"
        case .touchID: return "Touch ID"
        default: return nil
        }
    }

    private static func query(_ file: URL) -> [CFString: Any] {
        [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: "com.gcsa.pbsync.biometric-unlock.v1",
            kSecAttrAccount: Crypto.digest(Data(file.standardizedFileURL.path.utf8)),
            kSecUseDataProtectionKeychain: true
        ]
    }

    static func configured(_ file: URL) -> Bool {
        var attributes = query(file)
        let context = LAContext()
        context.interactionNotAllowed = true
        attributes[kSecUseAuthenticationContext] = context
        attributes[kSecReturnAttributes] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(attributes as CFDictionary, &result)
        return status == errSecSuccess || status == errSecInteractionNotAllowed
    }

    static func authorizeEnrollment() async throws -> LAContext {
        let context = LAContext()
        context.localizedFallbackTitle = ""
        guard try await context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics,
                                               localizedReason: "为当前空间启用生物识别解锁") else {
            throw PBError.unavailable
        }
        return context
    }

    static func save(_ key: Data, file: URL, context: LAContext) throws {
        #if os(macOS)
        let accessibility = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        #else
        let accessibility = kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly
        #endif
        guard let control = SecAccessControlCreateWithFlags(nil, accessibility,
                                                           .biometryCurrentSet, nil) else {
            throw PBError.unavailable
        }
        let attributes = query(file)
        var entry = attributes
        entry[kSecAttrAccessControl] = control
        entry[kSecValueData] = key
        entry[kSecUseAuthenticationContext] = context
        let status = SecItemAdd(entry as CFDictionary, nil)
        if status == errSecDuplicateItem {
            try remove(file)
            guard SecItemAdd(entry as CFDictionary, nil) == errSecSuccess else { throw PBError.unavailable }
        } else if status != errSecSuccess {
            throw PBError.unavailable
        }
    }

    static func read(_ file: URL, context: LAContext) throws -> Data? {
        context.localizedFallbackTitle = ""
        context.localizedReason = "解锁 PBsync 当前空间"
        var entry = query(file)
        entry[kSecUseAuthenticationContext] = context
        entry[kSecReturnData] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(entry as CFDictionary, &result)
        if status == errSecUserCanceled { return nil }
        guard status == errSecSuccess, let key = result as? Data, key.count == 32 else {
            throw PBError.invalid("本机生物识别解锁不可用。请使用主密码或恢复密钥。")
        }
        return key
    }

    static func remove(_ file: URL) throws {
        let status = SecItemDelete(query(file) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw PBError.unavailable }
    }
}
