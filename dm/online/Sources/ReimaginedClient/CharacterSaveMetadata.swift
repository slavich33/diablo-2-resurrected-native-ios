import Foundation
import CryptoKit

public enum CharacterSaveMetadataError: Error, Equatable {
    case invalidSize, invalidVersion, invalidName, invalidSaveIdentity, invalidContract
    case invalidFlag, invalidBlob, truncated, trailingBytes, wrongControlKind, failedTransfer
    case saveMismatch
}

/// The version-7 metadata body carried by D2RL kind10. The four contract words,
/// flag remain opaque. The two fixed-capacity blobs contain item/player stat
/// usage bitmaps (see statUsage). Structural validity does not establish their
/// completeness, provenance, a valid seal, sidecar support or admission.
public struct CharacterSaveMetadata: Equatable {
    public static let maximumBlobBytes = 4096
    public static let maximumBytes = 76 + 61 + 2 * maximumBlobBytes
    public let characterName: Data
    public let saveChecksum: UInt32
    public let saveByteCount: UInt32
    public let gameEdition: UInt8
    public let saveSHA256: Data
    public let word50: UInt64
    public let word58: UInt32
    public let word60: UInt64
    public let word68: UInt64
    public let flag70: Bool
    public let blob71: Data
    public let blob1071: Data

    public init(characterName: Data, saveChecksum: UInt32, saveByteCount: UInt32,
                gameEdition: UInt8, saveSHA256: Data, word50: UInt64, word58: UInt32,
                word60: UInt64, word68: UInt64, flag70: Bool, blob71: Data, blob1071: Data) throws {
        guard (1...61).contains(characterName.count) else { throw CharacterSaveMetadataError.invalidName }
        guard saveByteCount > 0, (1...3).contains(gameEdition), saveSHA256.count == 32,
              saveSHA256.contains(where: { $0 != 0 }) else { throw CharacterSaveMetadataError.invalidSaveIdentity }
        guard word50 <= 63,
              word58 == 0 ? (word50 == 0 && word60 == 0 && word68 == 0) : (word50 > 0 && word60 > 0 && word68 >= word60) else {
            throw CharacterSaveMetadataError.invalidContract
        }
        guard blob71.count <= Self.maximumBlobBytes, blob1071.count <= Self.maximumBlobBytes else {
            throw CharacterSaveMetadataError.invalidBlob
        }
        self.characterName = Data(characterName); self.saveChecksum = saveChecksum
        self.saveByteCount = saveByteCount; self.gameEdition = gameEdition; self.saveSHA256 = Data(saveSHA256)
        self.word50 = word50; self.word58 = word58; self.word60 = word60; self.word68 = word68; self.flag70 = flag70
        // The original sender trims trailing zeros from each fixed 4096-byte
        // array; the receiver zero-fills the rest. Store that canonical form.
        func trimmed(_ value: Data) -> Data {
            let bytes = Array(value)
            return bytes.lastIndex(where: { $0 != 0 }).map { Data(bytes[...$0]) } ?? Data()
        }
        self.blob71 = trimmed(blob71); self.blob1071 = trimmed(blob1071)
    }

    public func encoded() -> Data {
        var data = Data([7, UInt8(characterName.count)]); data.append(characterName)
        func append(_ value: UInt64, bytes: Int) {
            for shift in stride(from: 0, to: bytes * 8, by: 8) { data.append(UInt8(truncatingIfNeeded: value >> shift)) }
        }
        append(UInt64(saveChecksum), bytes: 4); append(UInt64(saveByteCount), bytes: 4)
        data.append(gameEdition); data.append(saveSHA256)
        append(word50, bytes: 8); append(UInt64(word58), bytes: 4); append(word60, bytes: 8); append(word68, bytes: 8)
        data.append(flag70 ? 1 : 0)
        for blob in [blob71, blob1071] { append(UInt64(blob.count), bytes: 2); data.append(blob) }
        return data
    }

    public static func decode(_ data: Data) throws -> CharacterSaveMetadata {
        guard (77...maximumBytes).contains(data.count) else { throw CharacterSaveMetadataError.invalidSize }
        let bytes = Array(data); var offset = 0
        func take(_ count: Int) throws -> Data {
            guard count >= 0, count <= bytes.count - offset else { throw CharacterSaveMetadataError.truncated }
            defer { offset += count }; return Data(bytes[offset..<(offset + count)])
        }
        func number(_ count: Int) throws -> UInt64 {
            try take(count).enumerated().reduce(0) { $0 | UInt64($1.element) << (8 * $1.offset) }
        }
        guard try number(1) == 7 else { throw CharacterSaveMetadataError.invalidVersion }
        let name = try take(Int(number(1)))
        let checksum = try UInt32(number(4)), size = try UInt32(number(4)), edition = try UInt8(number(1))
        let digest = try take(32), word50 = try number(8), word58 = try UInt32(number(4))
        let word60 = try number(8), word68 = try number(8), flag = try number(1)
        guard flag <= 1 else { throw CharacterSaveMetadataError.invalidFlag }
        func blob() throws -> Data {
            let count = try Int(number(2))
            guard count <= maximumBlobBytes else { throw CharacterSaveMetadataError.invalidBlob }
            return try take(count)
        }
        let first = try blob(), second = try blob()
        guard offset == bytes.count else { throw CharacterSaveMetadataError.trailingBytes }
        return try CharacterSaveMetadata(characterName: name, saveChecksum: checksum, saveByteCount: size,
            gameEdition: edition, saveSHA256: digest, word50: word50, word58: word58,
            word60: word60, word68: word68, flag70: flag == 1, blob71: first, blob1071: second)
    }

    public func controlMessages() throws -> [ControlMessage] {
        try EnvironmentFragment.split(encoded()).map { try ControlMessage(kind: 10, payload: $0.encoded()) }
    }

    /// Local identity/integrity preflight for this port's version-105 D2S. It
    /// never imports a file or establishes server ownership/accepted progress.
    /// Expected name must come from the selected isolated server character.
    public func verifyVersion105Save(_ data: Data, expectedCharacterName: String) throws {
        let name = Array(expectedCharacterName.utf8)
        guard (2...15).contains(name.count), name.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) }),
              characterName == Data(name), data.count >= 403, data.count <= 8 * 1024 * 1024,
              data.count == Int(saveByteCount) else { throw CharacterSaveMetadataError.saveMismatch }
        let bytes = Array(data)
        func word(_ at: Int) -> UInt32 { (0..<4).reduce(0) { $0 | UInt32(bytes[at + $1]) << (8 * $1) } }
        guard word(0) == 0xaa55aa55, word(4) == 105, word(8) == saveByteCount,
              word(12) == saveChecksum, bytes[248] == gameEdition,
              Data(bytes[299..<(299 + name.count)]) == characterName,
              bytes[(299 + name.count)..<395].allSatisfy({ $0 == 0 }),
              Data(SHA256.hash(data: data)) == saveSHA256 else { throw CharacterSaveMetadataError.saveMismatch }
        var checksum: UInt32 = 0
        for (index, byte) in bytes.enumerated() {
            checksum = ((checksum << 1) | (checksum >> 31)) &+ UInt32((12..<16).contains(index) ? 0 : byte)
        }
        guard checksum == saveChecksum else { throw CharacterSaveMetadataError.saveMismatch }
    }
}

/// One ordered metadata transfer for one connection/save transaction. This is
/// a stricter local policy than the original overlap-tolerant reassembler.
/// Rejection leaves it failed until explicit reset; it never writes a sidecar.
public struct CharacterMetadataAssembly {
    private var assembly = EnvironmentAssembly()
    private var failed = false
    public init() {}

    public mutating func append(_ control: ControlMessage) throws -> CharacterSaveMetadata? {
        guard !failed else { throw CharacterSaveMetadataError.failedTransfer }
        do {
            guard control.kind == 10 else { throw CharacterSaveMetadataError.wrongControlKind }
            let fragment = try EnvironmentFragment.decode(control.payload)
            guard fragment.total <= CharacterSaveMetadata.maximumBytes else { throw CharacterSaveMetadataError.invalidSize }
            guard let data = try assembly.append(fragment) else { return nil }
            return try CharacterSaveMetadata.decode(data)
        } catch { failed = true; throw error }
    }

    public mutating func reset() { assembly.reset(); failed = false }
}
