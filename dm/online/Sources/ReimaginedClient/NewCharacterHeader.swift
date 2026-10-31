import Foundation
import CryptoKit

public enum NewCharacterError: Error, Equatable {
    case invalidName, unsupportedHeader, checksumMismatch
}

/// Preflight for the original engine's version-105 creation header, before a
/// character has entered a world. Not a save editor or proof of provenance.
/// The caller must obtain it from a fresh isolated creation, never an offline
/// character import. Only the server can accept registration or own progress.
public struct NewCharacterHeader {
    public let characterName: String
    public let bytes: Data
    public let sha256: String
    public var fileName: String { characterName + ".d2s" }

    public init(characterName: String, bytes: Data) throws {
        let name = Array(characterName.utf8)
        // Deliberately restrict the initial registration path to ASCII letters.
        guard (2...15).contains(name.count), name.allSatisfy({
            (65...90).contains($0) || (97...122).contains($0)
        }) else { throw NewCharacterError.invalidName }
        let data = Array(bytes)
        guard data.count == 403 else { throw NewCharacterError.unsupportedHeader }
        func word(_ start: Int) -> UInt32 {
            (0..<4).reduce(0) { $0 | UInt32(data[start + $1]) << (8 * $1) }
        }
        let flags = word(20)
        guard word(0) == 0xaa55aa55, word(4) == 105, word(8) == 403,
              flags & 1 == 1, flags & ~UInt32(0x25) == 0,
              (1...3).contains(data[248]), data[24] < (data[248] == 1 ? 5 : data[248] == 2 ? 7 : 8),
              data[25] == 16, data[26] == 30, data[27] == 1,
              Array(data[299..<(299 + name.count)]) == name,
              data[(299 + name.count)..<395].allSatisfy({ $0 == 0 }) else {
            throw NewCharacterError.unsupportedHeader
        }
        var checksum: UInt32 = 0
        for (index, byte) in data.enumerated() {
            checksum = ((checksum << 1) | (checksum >> 31)) &+
                UInt32((12..<16).contains(index) ? 0 : byte)
        }
        guard checksum == word(12) else { throw NewCharacterError.checksumMismatch }
        self.characterName = characterName
        self.bytes = bytes
        self.sha256 = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }
}
