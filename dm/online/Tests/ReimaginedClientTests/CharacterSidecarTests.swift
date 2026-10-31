import XCTest
import CryptoKit
@testable import ReimaginedClient

final class CharacterSidecarTests: XCTestCase {
    private func fixed() -> Data {
        var data = Data(repeating: 0, count: 296)
        func n(_ at: Int, _ value: UInt64, _ count: Int) {
            for i in 0..<count { data[at + i] = UInt8(truncatingIfNeeded: value >> (8 * i)) }
        }
        n(8, 0x12345678, 4); n(12, 105, 4)
        data.replaceSubrange(16..<48, with: Data(repeating: 42, count: 32))
        data.replaceSubrange(48..<61, with: Data("NativeFixture".utf8))
        n(64, 403, 8); n(72, 403, 8); n(80, 1, 8); n(120, 4, 4)
        return data
    }

    func testFullOriginalVersion2ReaderAndWriterReference() throws {
        struct Corpus: Decodable {
            struct Entry: Decodable { let label: String; let inputHex: String; let accepted: Bool; let canonicalHex: String? }
            let referenceSHA256: String; let cases: [Entry]; let liveAdmissionVerified: Bool
        }
        func hex(_ text: String) throws -> Data {
            let chars = Array(text); XCTAssertTrue(chars.count.isMultiple(of: 2))
            return try Data(stride(from: 0, to: chars.count, by: 2).map {
                try XCTUnwrap(UInt8(String(chars[$0...$0+1]), radix: 16))
            })
        }
        let url = try XCTUnwrap(Bundle.module.url(forResource: "character-sidecar-reference", withExtension: "json"))
        let corpus = try JSONDecoder().decode(Corpus.self, from: Data(contentsOf: url))
        XCTAssertEqual(corpus.referenceSHA256, "2a868d013d2e0830bd2d9e04b918b19e46a73cf726c833e70d089b948fdeb5a2")
        XCTAssertFalse(corpus.liveAdmissionVerified); XCTAssertEqual(corpus.cases.count, 1077)
        XCTAssertEqual(corpus.cases.filter(\.accepted).count, 93)
        for entry in corpus.cases {
            let decoded = try? CharacterSidecar.decode(hex(entry.inputHex))
            XCTAssertEqual(decoded != nil, entry.accepted, entry.label)
            if let decoded { XCTAssertEqual(decoded.encoded(), try hex(XCTUnwrap(entry.canonicalHex)), entry.label) }
        }
    }

    func testFileDigestAndLengthMustMatchBeforePayloadIsAccepted() throws {
        let sidecar = try CharacterSidecar(fixedFields: fixed(), texts: [Data(), Data()], mod: nil, plugins: [], stats: [])
        let bytes = sidecar.encoded()
        XCTAssertEqual(bytes.count, 356)
        XCTAssertEqual(try CharacterSidecar.decode(bytes), sidecar)
        for index in [0, 4, 6, 8, 12, 43, 44, bytes.count - 1] {
            var changed = bytes; changed[index] ^= 1
            XCTAssertThrowsError(try CharacterSidecar.decode(changed))
        }
        XCTAssertThrowsError(try CharacterSidecar.decode(bytes + Data([0])))
    }

    func testCompleteModPluginAndStatRecordsRoundTripWithoutLosingOpaqueBytes() throws {
        var fields = fixed(); fields[0] = 1
        let mod = CharacterSidecar.Mod(scope: 1, word: 0xffffffff,
            texts: [Data("mod".utf8), Data("Mod".utf8), Data(), Data("😀".utf8), Data()])
        let plugin = CharacterSidecar.Plugin(words: [2, 3, 0xffffffff, 0x12345678], hasDigest: true,
            digest: Data(repeating: 43, count: 32), texts: [Data("plugin".utf8), Data(), Data("1.2.3".utf8), Data()])
        let stat = CharacterSidecar.Stat(id: 32767, flags: 3, flag: true, byte34: 255, byte35: 254,
            word30: 0xffffffff, word2c: 0x12345678, byte38: 253, byte39: 252, name: Data("stat".utf8))
        let value = try CharacterSidecar(fixedFields: fields, texts: [Data("runtime".utf8), Data()], mod: mod, plugins: [plugin], stats: [stat])
        XCTAssertEqual(try CharacterSidecar.decode(value.encoded()), value)
        XCTAssertThrowsError(try CharacterSidecar(fixedFields: fields, texts: value.texts, mod: mod, plugins: [plugin, plugin], stats: []))
        XCTAssertThrowsError(try CharacterSidecar(fixedFields: fields, texts: value.texts, mod: mod, plugins: [], stats: [stat, stat]))
    }
}
