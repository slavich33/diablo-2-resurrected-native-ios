import Foundation
import CryptoKit
import Security

public enum SaveCommitSessionError: Error, Equatable {
    case generation, invalidSnapshot, wrongCharacter, conflictingMetadata, metadataLimit
    case waitingForMetadata, digestMismatch, stalePreparation, missingTrustedPredecessor
}

/// One caller-serialized, admitted connection/selected-character save session.
/// The caller must supply an authenticated server download and actual admitted
/// environment/client inventory, then keep its namespace/table leases through
/// the filesystem prepare/finished pair. This API grants no admission, mounts
/// no directory and performs no upload or offline import.
public final class CharacterSaveCommitSession {
    public static let maximumPendingMetadata = 64
    public let generation: UInt64
    public let characterName: String
    public let gameEdition: UInt8
    private let owner = UUID()
    private let key: P256.Signing.PrivateKey
    private let environment: EnvironmentMetadata
    private let clientPlugins: [CharacterSidecar.Plugin]
    private var active = true
    private var assembly = CharacterMetadataAssembly()
    private var pending: [CharacterSaveMetadata] = []
    private var consumed: [Data] = []
    private var committedSaveDigest: Data
    private var committedSidecar: Data?
    private var trustedUnsignedDigest: Data?
    private var prepared: PreparedCharacterSave?

    public var pendingMetadataCount: Int { pending.count }

    /// With no predecessor, only a separately registered, pristine initial
    /// creation header is supported. A progressed download without its trusted
    /// sidecar must not silently acquire a new history.
    public init(generation: UInt64, characterName: String, initialSave: VerifiedServerSave,
                previousSidecar: Data? = nil, trustedUnsignedSidecarSHA256: Data? = nil,
                environment: EnvironmentMetadata, clientPlugins: [CharacterSidecar.Plugin],
                signingKey: P256.Signing.PrivateKey) throws {
        guard generation > 0 else { throw SaveCommitSessionError.generation }
        guard initialSave.metadata.fileName == characterName + ".d2s",
              initialSave.metadata.characterName == nil || initialSave.metadata.characterName == characterName,
              initialSave.bytes.count >= 403, initialSave.bytes.count <= 8 * 1024 * 1024 else {
            throw SaveCommitSessionError.invalidSnapshot
        }
        let bytes = initialSave.bytes, edition = bytes[bytes.startIndex + 248]
        let digest = Data(SHA256.hash(data: bytes))
        let identity = try Self.identity(bytes, name: characterName, edition: edition)
        try identity.verifyVersion105Save(bytes, expectedCharacterName: characterName)
        if let previousSidecar {
            let prior = try CharacterSidecar.decode(previousSidecar)
            guard prior.saveChecksum == identity.saveChecksum, prior.saveByteCount == identity.saveByteCount,
                  prior.saveSHA256 == digest else { throw SaveCommitSessionError.invalidSnapshot }
            if prior.sealPublicKey != nil {
                try prior.verifySeal(expectedPublicKey: signingKey.publicKey.rawRepresentation)
            } else {
                guard trustedUnsignedSidecarSHA256 == Data(SHA256.hash(data: previousSidecar)) else {
                    throw SaveCommitSessionError.missingTrustedPredecessor
                }
            }
        } else {
            guard initialSave.metadata.version == 1 else { throw SaveCommitSessionError.missingTrustedPredecessor }
            _ = try NewCharacterHeader(characterName: characterName, bytes: bytes)
            guard trustedUnsignedSidecarSHA256 == nil else { throw SaveCommitSessionError.invalidSnapshot }
        }
        self.generation = generation; self.characterName = characterName; gameEdition = edition
        key = signingKey; self.environment = environment; self.clientPlugins = clientPlugins
        committedSaveDigest = digest; committedSidecar = previousSidecar
        trustedUnsignedDigest = trustedUnsignedSidecarSHA256
    }

    public func invalidate() {
        active = false; assembly.reset(); pending.removeAll(); consumed.removeAll(); prepared = nil
    }

    /// Feed only kind10 messages from this verified connection, in wire order.
    /// A malformed transfer invalidates this session, requiring an explicit new
    /// binding instead of resuming fragments in an ambiguous save transaction.
    public func receive(_ message: ControlMessage, generation: UInt64) throws {
        try require(generation)
        do {
            if let metadata = try assembly.append(message) {
                assembly.reset()
                guard Self.fold(metadata.characterName) == Self.fold(Data(characterName.utf8)),
                      metadata.gameEdition == gameEdition else { throw SaveCommitSessionError.wrongCharacter }
                let stamp = Data(SHA256.hash(data: metadata.encoded()))
                if consumed.contains(stamp) || pending.contains(metadata) { return }
                if pending.contains(where: {
                    Self.fold($0.characterName) == Self.fold(metadata.characterName) &&
                    $0.saveChecksum == metadata.saveChecksum && $0.saveByteCount == metadata.saveByteCount &&
                    $0.saveSHA256 == metadata.saveSHA256
                }) { throw SaveCommitSessionError.conflictingMetadata }
                guard pending.count < Self.maximumPendingMetadata else { throw SaveCommitSessionError.metadataLimit }
                pending.append(metadata)
            }
        } catch { invalidate(); throw error }
    }

    /// Call on final complete bytes, after all legacy side-file hooks. A close
    /// sequence alone is insufficient. No metadata is consumed until complete
    /// reports that the same D2S+sidecar directory transaction actually committed.
    public func prepare(_ save: Data, generation: UInt64,
                                 table: ItemStatCostSnapshot, timestamp: UInt64) throws -> PreparedCharacterSave? {
        try require(generation)
        guard save.count >= 403, save.count <= 8 * 1024 * 1024 else { throw CharacterSaveMetadataError.saveMismatch }
        let checksum = Self.word(save, 12), digest = Data(SHA256.hash(data: save))
        let candidates = pending.filter { $0.saveChecksum == checksum && Int($0.saveByteCount) == save.count }
        guard let metadata = candidates.first(where: { $0.saveSHA256 == digest }) else {
            if digest == committedSaveDigest { return nil }
            throw candidates.isEmpty ? SaveCommitSessionError.waitingForMetadata : SaveCommitSessionError.digestMismatch
        }
        try metadata.verifyVersion105Save(save, expectedCharacterName: characterName)
        let stats = try table.descriptors(for: metadata)
        if let prepared, prepared.saveBytes == save, prepared.metadata == metadata, prepared.stats == stats { return prepared }
        var fields = Data(count: 296)
        func put(_ offset: Int, _ value: UInt64, _ count: Int) {
            for i in 0..<count { fields[offset + i] = UInt8(truncatingIfNeeded: value >> (8 * i)) }
        }
        put(8, UInt64(metadata.saveChecksum), 4); put(12, UInt64(metadata.saveByteCount), 4)
        fields.replaceSubrange(16..<48, with: metadata.saveSHA256)
        put(128, metadata.word50, 8); put(136, UInt64(metadata.word58), 4)
        put(144, metadata.word60, 8); put(152, metadata.word68, 8)
        let historyID: Data
        if let committedSidecar { historyID = try CharacterSidecar.decode(committedSidecar).historyIdentifier }
        else {
            var random = [UInt8](repeating: 0, count: 16)
            let status = SecRandomCopyBytes(kSecRandomDefault, random.count, &random)
            guard status == errSecSuccess else { throw CharacterSidecarHistoryError.randomFailure(status) }
            historyID = Data(random)
        }
        fields = try SidecarHistoryFields.initial(fields, timestamp: timestamp, identifier: historyID,
            restart: false, discontinuity: metadata.flag70)
        let candidate = try CharacterSidecar(fixedFields: fields, environmentMetadata: environment,
                                            clientPlugins: clientPlugins, stats: stats)
        let signed: CharacterSidecar
        if let committedSidecar {
            signed = try candidate.advancingSignedHistory(from: committedSidecar, using: key, timestamp: timestamp,
                markDiscontinuity: metadata.flag70, trustedUnsignedPredecessorSHA256: trustedUnsignedDigest)
        } else { signed = try candidate.sealed(using: key) }
        try signed.verifySignedVersion105Save(save, expectedCharacterName: characterName,
                                            expectedPublicKey: key.publicKey.rawRepresentation)
        let result = PreparedCharacterSave(owner: owner, token: UUID(), generation: generation,
            saveBytes: Data(save), sidecarBytes: signed.encoded(), metadata: metadata, stats: stats)
        prepared = result
        return result
    }

    public func complete(_ candidate: PreparedCharacterSave, generation: UInt64, committed: Bool) throws {
        try require(generation)
        guard candidate.owner == owner, prepared?.token == candidate.token else { throw SaveCommitSessionError.stalePreparation }
        guard committed else { return } // Retry reuses the same signed candidate.
        committedSaveDigest = candidate.metadata.saveSHA256; committedSidecar = candidate.sidecarBytes
        trustedUnsignedDigest = nil
        pending.removeAll { $0 == candidate.metadata }
        consumed.append(Data(SHA256.hash(data: candidate.metadata.encoded())))
        if consumed.count > Self.maximumPendingMetadata { consumed.removeFirst() }
        prepared = nil
    }

    private func require(_ value: UInt64) throws {
        guard active, value == generation else { throw SaveCommitSessionError.generation }
    }
    private static func word(_ data: Data, _ at: Int) -> UInt32 {
        (0..<4).reduce(0) { $0 | UInt32(data[data.startIndex + at + $1]) << (8 * $1) }
    }
    private static func fold(_ data: Data) -> Data { Data(data.map { (65...90).contains($0) ? $0 + 32 : $0 }) }
    private static func identity(_ data: Data, name: String, edition: UInt8) throws -> CharacterSaveMetadata {
        try CharacterSaveMetadata(characterName: Data(name.utf8), saveChecksum: word(data, 12),
            saveByteCount: UInt32(data.count), gameEdition: edition, saveSHA256: Data(SHA256.hash(data: data)),
            word50: 0, word58: 0, word60: 0, word68: 0, flag70: false, blob71: Data(), blob1071: Data())
    }
}

public struct PreparedCharacterSave {
    fileprivate let owner: UUID, token: UUID
    public let generation: UInt64
    public let saveBytes: Data, sidecarBytes: Data
    public let metadata: CharacterSaveMetadata
    fileprivate let stats: [CharacterSidecar.Stat]
}
