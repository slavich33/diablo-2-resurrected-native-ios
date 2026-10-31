import Foundation
import CryptoKit

public enum CharacterSidecarSealError: Error, Equatable {
    case missingSeal, invalidPublicKey, invalidSignature, keyMismatch
}

extension CharacterSidecar {
    /// Exact original v2 signing digest. It covers the complete canonical
    /// payload, including the public key, with only the signature zeroed.
    /// The domain's terminating NUL is part of the input. This is distinct
    /// from the plain SHA256 in the sidecar file header.
    public func signingDigest() -> SHA256.Digest {
        var payload = Data(encoded().dropFirst(44))
        payload.replaceSubrange(232..<296, with: Data(repeating: 0, count: 64))
        var input = Data("D2RL-SEAL-V2\0".utf8); input.append(payload)
        return SHA256.hash(data: input)
    }

    public var sealPublicKey: Data? {
        fixedFields[160] == 1 ? fixedFields.subdata(in: 168..<232) : nil
    }

    /// Cryptographic integrity only. A valid local signature does not prove
    /// server ownership, a server receipt, mod compatibility or ladder admission.
    /// Supply the previously trusted key to enforce that history's identity.
    public func verifySeal(expectedPublicKey: Data? = nil) throws {
        guard let publicBytes = sealPublicKey else { throw CharacterSidecarSealError.missingSeal }
        if let expectedPublicKey, expectedPublicKey != publicBytes { throw CharacterSidecarSealError.keyMismatch }
        let key: P256.Signing.PublicKey
        do { key = try P256.Signing.PublicKey(rawRepresentation: publicBytes) }
        catch { throw CharacterSidecarSealError.invalidPublicKey }
        let signature: P256.Signing.ECDSASignature
        do { signature = try P256.Signing.ECDSASignature(rawRepresentation: fixedFields.subdata(in: 232..<296)) }
        catch { throw CharacterSidecarSealError.invalidSignature }
        guard key.isValidSignature(signature, for: signingDigest()) else { throw CharacterSidecarSealError.invalidSignature }
    }

    /// Seal with the caller's own P-256 key. Existing signed history cannot
    /// silently move to a different key. This method does not create/reset
    /// lineage or infer server authority from an otherwise unsigned file.
    public func sealed(using key: P256.Signing.PrivateKey) throws -> CharacterSidecar {
        let publicBytes = key.publicKey.rawRepresentation
        guard publicBytes.count == 64 else { throw CharacterSidecarSealError.invalidPublicKey }
        if let existing = sealPublicKey {
            guard existing == publicBytes else { throw CharacterSidecarSealError.keyMismatch }
            try verifySeal(expectedPublicKey: publicBytes)
        }
        var fields = fixedFields
        fields[120] &= 0xfb // Clear original history's unsealed flag; retain other flags.
        fields.replaceSubrange(160..<164, with: Data([1, 0, 0, 0]))
        fields.replaceSubrange(168..<232, with: publicBytes)
        // The public model requires a nonzero signature-shaped field. The
        // signing digest always zeroes it, as the original payload writer does.
        fields.replaceSubrange(232..<296, with: Data(repeating: 1, count: 64))
        let candidate = try CharacterSidecar(fixedFields: fields, texts: texts, mod: mod, plugins: plugins, stats: stats)
        let signature = try key.signature(for: candidate.signingDigest()).rawRepresentation
        guard signature.count == 64 else { throw CharacterSidecarSealError.invalidSignature }
        fields.replaceSubrange(232..<296, with: signature)
        let result = try CharacterSidecar(fixedFields: fields, texts: texts, mod: mod, plugins: plugins, stats: stats)
        try result.verifySeal(expectedPublicKey: publicBytes)
        return result
    }
}
