import Foundation
import LocalAuthentication
import PBsyncCore
import Security

enum BiometricUnlock {
    static func checkStorageAuthorization() throws {
        #if os(macOS)
        var code: SecCode?
        var staticCode: SecStaticCode?
        var information: CFDictionary?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation),
                                           &information) == errSecSuccess,
              let details = information as? [String: Any],
              let rights = details[kSecCodeInfoEntitlementsDict as String] as? [String: Any],
              let identifier = rights["com.apple.application-identifier"] as? String,
              !identifier.isEmpty else {
            throw PBError.invalid("当前 Mac 构建缺少受保护钥匙串的签名授权。请使用具备项目开发描述文件的签名版本启用 Touch ID。")
        }
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
        var attributes = query(file)
        let context = LAContext()
        context.interactionNotAllowed = true
        attributes[kSecUseAuthenticationContext] = context
        attributes[kSecReturnAttributes] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(attributes as CFDictionary, &result)
        return status == errSecSuccess || status == errSecInteractionNotAllowed
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
