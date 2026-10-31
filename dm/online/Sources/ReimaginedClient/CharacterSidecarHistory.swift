import Foundation
import CryptoKit
import Security

public enum CharacterSidecarHistoryError: Error, Equatable {
    case signedCurrentCandidate, timestamp, historyID, counterExhausted, unsignedPredecessorNotTrusted, randomFailure(Int32)
}

extension CharacterSidecar {
    public var historyIdentifier: Data { fixedFields.subdata(in: 48..<64) }
    public var historyCounter: UInt64 { SidecarHistoryFields.number(fixedFields, 80, 8) }

    /// Original clock is Unix time in whole seconds, with values below2
    /// clamped to1. Explicit timestamps make transaction/reference tests exact.
    public static func historyTimestamp(date: Date = Date()) throws -> UInt64 {
        let seconds = date.timeIntervalSince1970.rounded(.towardZero)
        guard seconds.isFinite, seconds < Double(UInt64.max) else { throw CharacterSidecarHistoryError.timestamp }
        return seconds < 2 ? 1 : UInt64(seconds)
    }

    /// Start a new history only after an explicit namespace/coordinator decision.
    /// Never use this as a fallback for an unreadable or differently signed prior
    /// save. No file is written and no server provenance is inferred here.
    public func startingSignedHistory(using key: P256.Signing.PrivateKey, timestamp: UInt64,
                                     historyID: Data? = nil, isRestart: Bool = false,
                                     markDiscontinuity: Bool = false) throws -> CharacterSidecar {
        guard sealPublicKey == nil else { throw CharacterSidecarHistoryError.signedCurrentCandidate }
        let identifier: Data
        if let historyID { identifier = historyID }
        else {
            var bytes = [UInt8](repeating: 0, count: 16)
            let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
            guard status == errSecSuccess else { throw CharacterSidecarHistoryError.randomFailure(status) }
            identifier = Data(bytes)
        }
        let fields = try SidecarHistoryFields.initial(fixedFields, timestamp: timestamp,
            identifier: identifier, restart: isRestart, discontinuity: markDiscontinuity)
        return try withHistoryFields(fields).sealed(using: key)
    }

    /// Advance a previously valid file signed by this same trusted key. The
    /// original also accepts an unsealed predecessor; that path requires its
    /// exact digest from a separately authenticated server-snapshot manifest.
    /// The chain hashes the exact previous file bytes, including its header;
    /// it never substitutes a re-encoded representation. Failures require an
    /// explicit caller decision, not automatic rotation/reset/import.
    public func advancingSignedHistory(from previousFile: Data, using key: P256.Signing.PrivateKey,
                                      timestamp: UInt64, markDiscontinuity: Bool = false,
                                      trustedUnsignedPredecessorSHA256: Data? = nil) throws -> CharacterSidecar {
        guard sealPublicKey == nil else { throw CharacterSidecarHistoryError.signedCurrentCandidate }
        let previous = try CharacterSidecar.decode(previousFile)
        if previous.sealPublicKey != nil {
            try previous.verifySeal(expectedPublicKey: key.publicKey.rawRepresentation)
        } else {
            guard let digest = trustedUnsignedPredecessorSHA256, digest.count == 32,
                  digest == Data(SHA256.hash(data: previousFile)) else {
                throw CharacterSidecarHistoryError.unsignedPredecessorNotTrusted
            }
        }
        let fields = try SidecarHistoryFields.advance(fixedFields, previous: previous.fixedFields,
            previousFile: previousFile, timestamp: timestamp, discontinuity: markDiscontinuity)
        return try withHistoryFields(fields).sealed(using: key)
    }

    private func withHistoryFields(_ fields: Data) throws -> CharacterSidecar {
        try CharacterSidecar(fixedFields: fields, texts: texts, mod: mod, plugins: plugins, stats: stats)
    }
}

// Pure projection used after the public API verifies its predecessor. Reference
// tests exercise this independently of OS sign/verify callbacks. It cannot
// write files, select a namespace, sign data or grant server authority.
enum SidecarHistoryFields {
    static func number(_ data: Data, _ offset: Int, _ bytes: Int) -> UInt64 {
        (0..<bytes).reduce(0) { $0 | UInt64(data[offset + $1]) << (8 * $1) }
    }
    private static func put(_ data: inout Data, _ offset: Int, _ value: UInt64, _ bytes: Int) {
        for i in 0..<bytes { data[offset + i] = UInt8(truncatingIfNeeded: value >> (8 * i)) }
    }
    private static func unsigned(_ data: inout Data) {
        data[120] |= 4
        data.replaceSubrange(160..<296, with: Data(repeating: 0, count: 136))
    }

    static func initial(_ current: Data, timestamp: UInt64, identifier: Data,
                        restart: Bool, discontinuity: Bool) throws -> Data {
        guard timestamp > 0 else { throw CharacterSidecarHistoryError.timestamp }
        guard identifier.count == 16, identifier.contains(where: { $0 != 0 }) else { throw CharacterSidecarHistoryError.historyID }
        var fields = current
        fields.replaceSubrange(48..<64, with: identifier)
        put(&fields, 64, timestamp, 8); put(&fields, 72, timestamp, 8); put(&fields, 80, 1, 8)
        fields.replaceSubrange(88..<120, with: Data(repeating: 0, count: 32))
        put(&fields, 120, (restart ? 1 : 0) | (discontinuity ? 2 : 0), 4)
        unsigned(&fields)
        return fields
    }

    static func advance(_ current: Data, previous: Data, previousFile: Data,
                        timestamp: UInt64, discontinuity: Bool) throws -> Data {
        guard timestamp > 0 else { throw CharacterSidecarHistoryError.timestamp }
        let count = number(previous, 80, 8)
        guard count < UInt64.max else { throw CharacterSidecarHistoryError.counterExhausted }
        var fields = current
        fields.replaceSubrange(48..<128, with: previous[48..<128])
        put(&fields, 72, timestamp, 8); put(&fields, 80, count + 1, 8)
        fields.replaceSubrange(88..<120, with: Data(SHA256.hash(data: previousFile)))
        let currentCount = number(current, 136, 4), oldCount = number(previous, 136, 4)
        let currentFirst = number(current, 144, 8), oldFirst = number(previous, 144, 8)
        let currentLast = number(current, 152, 8), oldLast = number(previous, 152, 8)
        if timestamp < number(previous, 72, 8) || discontinuity || (currentCount != 0 && oldLast != 0 && currentFirst < oldLast) {
            fields[120] |= 2
        }
        put(&fields, 128, number(current, 128, 8) | number(previous, 128, 8), 8)
        put(&fields, 136, min(UInt64(UInt32.max), currentCount + oldCount), 4)
        put(&fields, 144, oldFirst != 0 && (currentFirst == 0 || oldFirst < currentFirst) ? oldFirst : currentFirst, 8)
        put(&fields, 152, max(currentLast, oldLast), 8)
        unsigned(&fields)
        return fields
    }
}
