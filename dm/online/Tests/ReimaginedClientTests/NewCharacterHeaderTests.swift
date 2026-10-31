import XCTest
@testable import ReimaginedClient

final class NewCharacterHeaderTests: XCTestCase {
    /// Synthetic layout-only bytes. No original character or game data.
    private func fixture(name: String = "Fixture", flags: UInt32 = 1,
                         level: UInt8 = 1, version: UInt32 = 105,
                         edition: UInt8 = 3, characterClass: UInt8 = 4) -> Data {
        var bytes = [UInt8](repeating: 0, count: 403)
        func word(_ offset: Int, _ value: UInt32) {
            for i in 0..<4 { bytes[offset + i] = UInt8(truncatingIfNeeded: value >> (i * 8)) }
        }
        word(0, 0xaa55aa55); word(4, version); word(8, 403); word(20, flags)
        bytes[24] = characterClass; bytes[25] = 16; bytes[26] = 30; bytes[27] = level; bytes[248] = edition
        for (i, byte) in name.utf8.enumerated() { bytes[299 + i] = byte }
        var checksum: UInt32 = 0
        for byte in bytes { checksum = ((checksum << 1) | (checksum >> 31)) &+ UInt32(byte) }
        word(12, checksum)
        return Data(bytes)
    }

    func testAcceptsOnlyMatchingFreshCreationHeader() throws {
        for flags: UInt32 in [1, 5, 0x21, 0x25] {
            let bytes = fixture(flags: flags)
            let header = try NewCharacterHeader(characterName: "Fixture", bytes: bytes)
            XCTAssertEqual(header.bytes, bytes)
            XCTAssertEqual(header.fileName, "Fixture.d2s")
            XCTAssertEqual(header.sha256.count, 64)
        }
        XCTAssertThrowsError(try NewCharacterHeader(characterName: "Other", bytes: fixture()))
        for name in ["A", "../Fixture", "Fixture.d2s", "Éxample", "Fixture2", String(repeating: "A", count: 16)] {
            XCTAssertThrowsError(try NewCharacterHeader(characterName: name, bytes: fixture())) {
                XCTAssertEqual($0 as? NewCharacterError, .invalidName)
            }
        }
    }

    func testRejectsProgressOldFormatAndCorruption() {
        for bytes in [fixture(flags: 0x20), fixture(flags: 9), fixture(flags: 0x101),
                      fixture(flags: 3), fixture(flags: 0x41), fixture(level: 2),
                      fixture(version: 104), fixture(edition: 0), fixture(edition: 4),
                      fixture(edition: 1, characterClass: 5), fixture(edition: 2, characterClass: 7),
                      fixture() + Data([0]), Data(fixture().dropLast())] {
            XCTAssertThrowsError(try NewCharacterHeader(characterName: "Fixture", bytes: bytes)) {
                XCTAssertEqual($0 as? NewCharacterError, .unsupportedHeader)
            }
        }
        var corrupt = fixture(); corrupt[40] ^= 1
        XCTAssertThrowsError(try NewCharacterHeader(characterName: "Fixture", bytes: corrupt)) {
            XCTAssertEqual($0 as? NewCharacterError, .checksumMismatch)
        }
    }
}
