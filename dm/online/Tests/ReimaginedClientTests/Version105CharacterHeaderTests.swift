import XCTest
@testable import ReimaginedClient

final class Version105CharacterHeaderTests: XCTestCase {
    /// Synthetic bytes only; no original character, quest or item data.
    private func fixture(count: Int = 1_237, level: UInt8 = 7, flags: UInt32 = 0,
                         version: UInt32 = 105, edition: UInt8 = 3, characterClass: UInt8 = 4) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        func word(_ offset: Int, _ value: UInt32) {
            for i in 0..<4 { bytes[offset + i] = UInt8(truncatingIfNeeded: value >> (i * 8)) }
        }
        word(0, 0xaa55aa55); word(4, version); word(8, UInt32(count)); word(20, flags)
        bytes[24] = characterClass; bytes[27] = level; bytes[248] = edition
        for (i, byte) in "Fixture".utf8.enumerated() { bytes[299 + i] = byte }
        if count > 403 { bytes[403] = 77; bytes[count - 1] = 91 }
        var checksum: UInt32 = 0
        for byte in bytes { checksum = ((checksum << 1) | (checksum >> 31)) &+ UInt32(byte) }
        word(12, checksum)
        return Data(bytes)
    }

    func testCreationAndProgressHeadersHaveDistinctFreshnessRequirements() throws {
        let created = fixture(count: 403, level: 1, flags: 1)
        let progress = fixture()
        for data in [created, progress] {
            let header = try Version105CharacterHeader(bytes: (Data([99]) + data).dropFirst(), expectedCharacterName: "fixture")
            XCTAssertEqual(header.byteCount, data.count)
            XCTAssertEqual(header.characterClass, 4); XCTAssertEqual(header.edition, 3)
            XCTAssertEqual(header.sha256.count, 64)
        }
        XCTAssertEqual(try Version105CharacterHeader(bytes: progress, expectedCharacterName: "Fixture").level, 7)
        XCTAssertFalse(try Version105CharacterHeader(bytes: progress, expectedCharacterName: "Fixture").hardcore)
        XCTAssertTrue(try Version105CharacterHeader(bytes: fixture(flags: 4), expectedCharacterName: "Fixture").hardcore)
        XCTAssertThrowsError(try NewCharacterHeader(characterName: "Fixture", bytes: progress))
    }

    func testCorruptionAndWrongIdentityAreRejectedWithoutEditingBytes() throws {
        var corrupt = fixture(); corrupt[500] ^= 1
        XCTAssertThrowsError(try Version105CharacterHeader(bytes: corrupt, expectedCharacterName: "Fixture")) {
            XCTAssertEqual($0 as? Version105CharacterHeaderError, .checksumMismatch)
        }
        XCTAssertThrowsError(try Version105CharacterHeader(bytes: fixture(), expectedCharacterName: "Other")) {
            XCTAssertEqual($0 as? Version105CharacterHeaderError, .identityMismatch)
        }
        for name in ["A", "../Fixture", "Fixture2", String(repeating: "A", count: 16)] {
            XCTAssertThrowsError(try Version105CharacterHeader(bytes: fixture(), expectedCharacterName: name)) {
                XCTAssertEqual($0 as? Version105CharacterHeaderError, .invalidName)
            }
        }
    }

    func testUnsupportedFormatsAndDeclaredLengthsAreRejected() {
        for data in [Data(count: 402), fixture() + Data([0]), fixture(version: 104),
                     fixture(level: 0), fixture(edition: 0), fixture(edition: 4),
                     fixture(edition: 1, characterClass: 5), fixture(edition: 2, characterClass: 7)] {
            XCTAssertThrowsError(try Version105CharacterHeader(bytes: data, expectedCharacterName: "Fixture")) {
                XCTAssertEqual($0 as? Version105CharacterHeaderError, .unsupportedFormat)
            }
        }
    }
}
