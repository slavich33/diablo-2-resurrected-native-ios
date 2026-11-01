import Foundation
import CryptoKit

public enum Version105CharacterHeaderError: Error, Equatable {
    case invalidName, unsupportedFormat, identityMismatch, checksumMismatch
}

/// Read-only identity/header/integrity preflight for this port's version105
/// character saves, including saves after initial creation. It does not parse
/// items/quests, migrate formats, authorize uploads or establish server ownership.
/// A server coordinator must separately verify the fresh manifest/download and
/// retain the original bytes in its isolated server-save namespace.
public struct Version105CharacterHeader {
    public let characterClass: UInt8
    public let edition: UInt8
    public let level: UInt8
    public let hardcore: Bool
    public let byteCount: Int
    public let checksum: UInt32
    public let sha256: String

    public init(bytes: Data, expectedCharacterName: String) throws {
        let expected = Array(expectedCharacterName.utf8)
        guard (2...15).contains(expected.count), expected.allSatisfy({
            (65...90).contains($0) || (97...122).contains($0)
        }) else { throw Version105CharacterHeaderError.invalidName }
        guard (403...(8 * 1024 * 1024)).contains(bytes.count) else {
            throw Version105CharacterHeaderError.unsupportedFormat
        }
        let data = Array(bytes)
        func word(_ offset: Int) -> UInt32 {
            (0..<4).reduce(0) { $0 | UInt32(data[offset + $1]) << (8 * $1) }
        }
        guard word(0) == 0xaa55aa55, word(4) == 105, word(8) == bytes.count,
              (1...3).contains(data[248]), data[27] > 0,
              data[24] < (data[248] == 1 ? 5 : data[248] == 2 ? 7 : 8) else {
            throw Version105CharacterHeaderError.unsupportedFormat
        }
        func folded(_ byte: UInt8) -> UInt8 { (65...90).contains(byte) ? byte + 32 : byte }
        guard data[299..<(299 + expected.count)].map(folded) == expected.map(folded),
              data[(299 + expected.count)..<395].allSatisfy({ $0 == 0 }) else {
            throw Version105CharacterHeaderError.identityMismatch
        }
        var calculated: UInt32 = 0
        for (index, byte) in data.enumerated() {
            calculated = ((calculated << 1) | (calculated >> 31)) &+
                UInt32((12..<16).contains(index) ? 0 : byte)
        }
        guard calculated == word(12) else { throw Version105CharacterHeaderError.checksumMismatch }
        characterClass = data[24]; edition = data[248]; level = data[27]
        hardcore = word(20) & 4 != 0
        byteCount = data.count; checksum = calculated
        sha256 = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }
}
