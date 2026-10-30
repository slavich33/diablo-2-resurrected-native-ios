// 使用固定信任根校验签名原文；采用 .NET ECDsa 的 P1363 签名格式。
// Verify exact signed bytes against pinned trust roots, using .NET ECDsa's P1363 signature format.
import Foundation
import CryptoKit

public enum ManifestError: Error, Equatable {
    case unknownKey, invalidDigest, digestMismatch, invalidSignature
}

public struct ManifestVerifier {
    private let trustedKeys: [String: P256.Signing.PublicKey]

    public init(trustedKeys: [String: P256.Signing.PublicKey]) { self.trustedKeys = trustedKeys }

    public func verify(manifest: Data, expectedSHA256: String, signatureBase64: String, signingKeyID: String) throws {
        guard let key = trustedKeys[signingKeyID] else { throw ManifestError.unknownKey }
        guard expectedSHA256.count == 64, expectedSHA256.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }) else {
            throw ManifestError.invalidDigest
        }
        let actual = SHA256.hash(data: manifest).map { String(format: "%02x", $0) }.joined()
        guard actual == expectedSHA256.lowercased() else { throw ManifestError.digestMismatch }
        guard let bytes = Data(base64Encoded: signatureBase64),
              let signature = try? P256.Signing.ECDSASignature(rawRepresentation: bytes),
              key.isValidSignature(signature, for: manifest) else { throw ManifestError.invalidSignature }
    }
}
