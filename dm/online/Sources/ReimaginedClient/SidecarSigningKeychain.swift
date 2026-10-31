import Foundation
import Security
import LocalAuthentication
import CryptoKit

/// Dedicated native signing key, independent of launcher credentials. Keys
/// stay in this device's local Keychain. Errors never silently replace a key:
/// a different key would sever an existing character's signed history.
public struct SidecarSigningKeychain {
    public enum Failure: Error { case invalidScope, keychain(OSStatus), invalidStoredKey }
    private let service: String
    public init(service: String = "org.d2rmobile.reimagined.sidecar-signing.v2") { self.service = service }

    static func scopedAccount(origin: URL, accountID: String) throws -> String {
        guard var canonical = URLComponents(url: origin, resolvingAgainstBaseURL: false),
              canonical.scheme?.lowercased() == "https", let host = canonical.host, !host.isEmpty,
              canonical.user == nil, canonical.password == nil, canonical.query == nil, canonical.fragment == nil,
              canonical.path.isEmpty || canonical.path == "/", !accountID.isEmpty,
              accountID.utf8.count <= 1024, !accountID.utf8.contains(0) else {
            throw Failure.invalidScope
        }
        canonical.scheme = "https"; canonical.host = host.lowercased(); canonical.path = ""
        if canonical.port == 443 { canonical.port = nil }
        guard let originText = canonical.string else { throw Failure.invalidScope }
        // The opaque account identifier and origin are never used as a path
        // or logged. Framing prevents concatenation collisions between scopes.
        var scope = Data(originText.utf8); scope.append(0); scope.append(contentsOf: accountID.utf8)
        return SHA256.hash(data: scope).map { String(format: "%02x", $0) }.joined()
    }

    private func query(origin: URL, accountID: String) throws -> [String: Any] {
        let account = try Self.scopedAccount(origin: origin, accountID: accountID)
        return [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                kSecAttrAccount as String: account, kSecAttrSynchronizable as String: false]
    }

    private func load(_ base: [String: Any]) throws -> P256.Signing.PrivateKey? {
        var query = base; query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        let context = LAContext(); context.interactionNotAllowed = true
        query[kSecUseAuthenticationContext as String] = context
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw Failure.keychain(status) }
        guard let bytes = result as? Data, bytes.count == 32,
              let key = try? P256.Signing.PrivateKey(rawRepresentation: bytes) else { throw Failure.invalidStoredKey }
        return key
    }

    public func loadOrCreate(origin: URL, accountID: String) throws -> P256.Signing.PrivateKey {
        let base = try query(origin: origin, accountID: accountID)
        if let existing = try load(base) { return existing }
        let key = P256.Signing.PrivateKey()
        var item = base; item[kSecValueData as String] = key.rawRepresentation
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let status = SecItemAdd(item as CFDictionary, nil)
        if status == errSecDuplicateItem {
            // Another caller won creation. Return that same key, never ours.
            guard let existing = try load(base) else { throw Failure.keychain(errSecItemNotFound) }
            return existing
        }
        guard status == errSecSuccess else { throw Failure.keychain(status) }
        return key
    }
}
