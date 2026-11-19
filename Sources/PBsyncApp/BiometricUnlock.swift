import Foundation
import LocalAuthentication
import PBsyncCore
import Security

enum BiometricUnlock {
    static func checkAvailability() throws {
        #if os(macOS)
        try MacBiometricUnlock.checkAvailability()
        #endif
    }

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
        #if os(macOS)
        return MacBiometricUnlock.configured(file)
        #else
        var attributes = query(file)
        let context = LAContext()
        context.interactionNotAllowed = true
        attributes[kSecUseAuthenticationContext] = context
        attributes[kSecReturnAttributes] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(attributes as CFDictionary, &result)
        return status == errSecSuccess || status == errSecInteractionNotAllowed
        #endif
    }

    static func authenticate(context: LAContext, reason: String) async throws {
        context.localizedFallbackTitle = ""
        context.touchIDAuthenticationAllowableReuseDuration = 0
        guard try await context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics,
                                               localizedReason: reason) else {
            throw PBError.unavailable
        }
    }

    static func save(_ key: Data, file: URL, context: LAContext) throws {
        #if os(macOS)
        try MacBiometricUnlock.save(key, file: file, authentication: context)
        #else
        let accessibility = kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly
        guard let control = SecAccessControlCreateWithFlags(nil, accessibility,
                                                           .biometryCurrentSet, nil) else {
            throw PBError.unavailable
        }
        let attributes = query(file)
        var entry = attributes
        entry[kSecAttrAccessControl] = control
        entry[kSecValueData] = key
        entry[kSecUseAuthenticationContext] = context
        var status = SecItemAdd(entry as CFDictionary, nil)
        if status == errSecDuplicateItem {
            try remove(file)
            status = SecItemAdd(entry as CFDictionary, nil)
        }
        if status == errSecMissingEntitlement {
            throw PBError.invalid("系统钥匙串尚未授权此应用签名，请使用具备钥匙串权限的开发签名版本。")
        }
        guard status == errSecSuccess else {
            throw PBError.invalid("无法保存本机生物识别密钥（钥匙串状态 \(status)）。")
        }
        #endif
    }

    static func read(_ file: URL, context: LAContext) throws -> Data? {
        context.localizedFallbackTitle = ""
        context.localizedReason = "解锁 PBsync 当前空间"
        #if os(macOS)
        return try MacBiometricUnlock.read(file, authentication: context)
        #else
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
        #endif
    }

    static func remove(_ file: URL) throws {
        #if os(macOS)
        try MacBiometricUnlock.remove(file)
        #else
        let status = SecItemDelete(query(file) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw PBError.unavailable }
        #endif
    }
}
