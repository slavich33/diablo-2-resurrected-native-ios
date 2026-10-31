import XCTest
import CryptoKit
@testable import ReimaginedClient

final class CharacterSaveMetadataTests: XCTestCase {
    private func metadata(first: Data = Data(), second: Data = Data()) throws -> CharacterSaveMetadata {
        try CharacterSaveMetadata(characterName: Data("NativeFixture".utf8), saveChecksum: 0x12345678,
            saveByteCount: 403, gameEdition: 3, saveSHA256: Data(repeating: 42, count: 32),
            word50: 0, word58: 0, word60: 0, word68: 0, flag70: false, blob71: first, blob1071: second)
    }

    func testOriginalMetadataDecoderAndCanonicalEncoderReference() throws {
        struct Corpus: Decodable {
            struct Entry: Decodable { let label: String; let inputHex: String; let accepted: Bool; let canonicalHex: String? }
            let referenceSHA256: String
            let cases: [Entry]
            let liveAdmissionVerified: Bool
        }
        func hex(_ text: String) throws -> Data {
            let chars = Array(text); XCTAssertTrue(chars.count.isMultiple(of: 2))
            return try Data(stride(from: 0, to: chars.count, by: 2).map {
                try XCTUnwrap(UInt8(String(chars[$0...$0+1]), radix: 16))
            })
        }
        let url = try XCTUnwrap(Bundle.module.url(forResource: "character-metadata-reference", withExtension: "json"))
        let corpus = try JSONDecoder().decode(Corpus.self, from: Data(contentsOf: url))
        XCTAssertEqual(corpus.referenceSHA256, "2a868d013d2e0830bd2d9e04b918b19e46a73cf726c833e70d089b948fdeb5a2")
        XCTAssertFalse(corpus.liveAdmissionVerified); XCTAssertGreaterThan(corpus.cases.count, 1000)
        for entry in corpus.cases {
            let input = try hex(entry.inputHex)
            let decoded = try? CharacterSaveMetadata.decode(input)
            XCTAssertEqual(decoded != nil, entry.accepted, entry.label)
            if let decoded {
                XCTAssertEqual(decoded.encoded(), try hex(XCTUnwrap(entry.canonicalHex)), entry.label)
                XCTAssertEqual(try CharacterSaveMetadata.decode(decoded.encoded()), decoded, entry.label)
            }
        }
    }

    func testKind10TransferAcrossEveryCarrierSplit() throws {
        let value = try metadata(first: Data(repeating: 43, count: 300), second: Data(repeating: 44, count: 200))
        let controls = try value.controlMessages()
        XCTAssertEqual(controls.count, 3); XCTAssertTrue(controls.allSatisfy { $0.kind == 10 })
        let carriers = controls.reduce(Data()) { $0 + $1.gameCarrier() }
        for split in 0...carriers.count {
            let stream = GamePacketStream(nativeSystemPackets: true, resolvePacketLength: StockServerPacketLengths.resolve)
            var assembly = CharacterMetadataAssembly(), results: [CharacterSaveMetadata] = []
            func drain() throws {
                while let decoded = try stream.nextPacket() {
                    guard case .control(let control) = decoded else { return XCTFail("Metadata misrouted") }
                    if let complete = try assembly.append(control) { results.append(complete) }
                }
            }
            try stream.append(carriers.prefix(split)); try drain()
            try stream.append(carriers.dropFirst(split)); stream.endOfInput(); try drain()
            XCTAssertEqual(results, [value])
        }
    }

    func testInvalidTransferCannotResumeWithoutReset() throws {
        let value = try metadata(first: Data(repeating: 42, count: 300))
        let controls = try value.controlMessages()
        var assembly = CharacterMetadataAssembly()
        XCTAssertThrowsError(try assembly.append(ControlMessage(kind: 8, payload: Data())))
        XCTAssertThrowsError(try assembly.append(controls[0])) { XCTAssertEqual($0 as? CharacterSaveMetadataError, .failedTransfer) }
        assembly.reset()
        XCTAssertNil(try assembly.append(controls[0]))
        let second = try EnvironmentFragment.decode(controls[1].payload)
        let changed = try EnvironmentFragment(total: second.total + 1, offset: second.offset, bytes: second.bytes)
        XCTAssertThrowsError(try assembly.append(ControlMessage(kind: 10, payload: changed.encoded())))
        XCTAssertThrowsError(try assembly.append(controls[1]))
        assembly.reset()
        for control in controls { _ = try assembly.append(control) }
        XCTAssertThrowsError(try assembly.append(controls[0]))
        assembly.reset()
        let oversized = try EnvironmentFragment(total: CharacterSaveMetadata.maximumBytes + 1, offset: 0, bytes: Data([7]))
        XCTAssertThrowsError(try assembly.append(ControlMessage(kind: 10, payload: oversized.encoded())))
    }

    func testSaveIdentityRequiresExactDigestHeaderNameAndRollingChecksum() throws {
        let name = "NativeFixture"
        var bytes = [UInt8](repeating: 0, count: 403)
        func word(_ at: Int, _ value: UInt32) { for i in 0..<4 { bytes[at + i] = UInt8(truncatingIfNeeded: value >> (8 * i)) } }
        word(0, 0xaa55aa55); word(4, 105); word(8, 403)
        bytes[248] = 3; bytes.replaceSubrange(299..<(299 + name.utf8.count), with: name.utf8)
        var checksum: UInt32 = 0
        for byte in bytes { checksum = ((checksum << 1) | (checksum >> 31)) &+ UInt32(byte) }
        word(12, checksum)
        func bound(_ data: Data) throws -> CharacterSaveMetadata {
            try CharacterSaveMetadata(characterName: Data(name.utf8), saveChecksum: checksum, saveByteCount: 403,
                gameEdition: 3, saveSHA256: Data(SHA256.hash(data: data)), word50: 0, word58: 0, word60: 0,
                word68: 0, flag70: false, blob71: Data(), blob1071: Data())
        }
        let data = Data(bytes), value = try bound(data)
        XCTAssertNoThrow(try value.verifyVersion105Save(data, expectedCharacterName: name))
        XCTAssertThrowsError(try value.verifyVersion105Save(data, expectedCharacterName: "Different"))
        XCTAssertThrowsError(try value.verifyVersion105Save(data.dropLast(), expectedCharacterName: name))
        var damaged = data; damaged[400] ^= 1
        XCTAssertThrowsError(try value.verifyVersion105Save(damaged, expectedCharacterName: name))
        // Updating SHA alone cannot make a corrupt D2S checksum valid.
        XCTAssertThrowsError(try bound(damaged).verifyVersion105Save(damaged, expectedCharacterName: name))
        bytes[248] = 2
        let changedEdition = Data(bytes)
        XCTAssertThrowsError(try bound(changedEdition).verifyVersion105Save(changedEdition, expectedCharacterName: name))
    }
}
