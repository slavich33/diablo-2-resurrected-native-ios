// 会话仅存入本机应用钥匙串，不写入游戏文件、iCloud 或日志。
// Store sessions only in the local application Keychain, never game files, iCloud or logs.
import Foundation
import Security
import LocalAuthentication

public struct SessionKeychain {
    public struct Failure: Error { public let status: OSStatus }
    private let service: String
    public init(service: String = "org.d2rmobile.reimagined.session") { self.service = service }

    private func query(_ origin: URL) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: origin.absoluteString, kSecAttrSynchronizable as String: false]
    }

    public func save(_ session: LauncherSession, origin: URL) throws {
        let bytes = try JSONEncoder().encode(session)
        let base = query(origin)
        let status = SecItemUpdate(base as CFDictionary, [kSecValueData as String: bytes] as CFDictionary)
        if status == errSecItemNotFound {
            var item = base
            item[kSecValueData as String] = bytes
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            let added = SecItemAdd(item as CFDictionary, nil)
            guard added == errSecSuccess else { throw Failure(status: added) }
        } else if status != errSecSuccess { throw Failure(status: status) }
    }

    public func load(origin: URL) throws -> LauncherSession? {
        var item = query(origin)
        item[kSecReturnData as String] = true
        item[kSecMatchLimit as String] = kSecMatchLimitOne
        let context = LAContext()
        context.interactionNotAllowed = true
        item[kSecUseAuthenticationContext as String] = context
        var result: CFTypeRef?
        let status = SecItemCopyMatching(item as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let bytes = result as? Data else { throw Failure(status: status) }
        return try JSONDecoder().decode(LauncherSession.self, from: bytes)
    }

    public func remove(origin: URL) throws {
        let status = SecItemDelete(query(origin) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw Failure(status: status) }
    }
}
