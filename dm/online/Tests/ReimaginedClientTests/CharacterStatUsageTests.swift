import XCTest
@testable import ReimaginedClient

final class CharacterStatUsageTests: XCTestCase {
    func testOriginalDescriptorsAndIndependentlyVerifiedNativeColumns() throws {
        struct Corpus: Decodable {
            struct Record: Decodable {
                let id: UInt32; let flags: UInt8; let flag: Bool
                let byte34: UInt8; let byte35: UInt8; let word30: UInt32; let word2c: UInt32
                let byte38: UInt8; let byte39: UInt8; let nameHex: String
            }
            struct Entry: Decodable {
                let label: String; let edition: UInt8; let id: UInt16; let rowCount: Int
                let rowHex: String; let usageFlags: UInt8; let name: String?; let descriptor: Record?
            }
            struct Schema: Decodable { let moduleID: String; let rowBytes: Int; let sameDescriptorLayoutAcrossEditions: Bool }
            let referenceSHA256: String; let nativeSchema: Schema; let cases: [Entry]; let liveAdmissionVerified: Bool
        }
        func hex(_ text: String) throws -> Data {
            let chars = Array(text); XCTAssertTrue(chars.count.isMultiple(of: 2))
            return try Data(stride(from: 0, to: chars.count, by: 2).map { try XCTUnwrap(UInt8(String(chars[$0...$0+1]), radix: 16)) })
        }
        let url = try XCTUnwrap(Bundle.module.url(forResource: "character-stat-descriptors-reference", withExtension: "json"))
        let corpus = try JSONDecoder().decode(Corpus.self, from: Data(contentsOf: url))
        XCTAssertEqual(corpus.referenceSHA256, "2a868d013d2e0830bd2d9e04b918b19e46a73cf726c833e70d089b948fdeb5a2")
        XCTAssertEqual(corpus.nativeSchema.moduleID, "db0507f36b84200ac05f75d76ed5026f903e6c90000000000000000000000000")
        XCTAssertEqual(corpus.nativeSchema.rowBytes, ItemStatCostSnapshot.rowBytes)
        XCTAssertTrue(corpus.nativeSchema.sameDescriptorLayoutAcrossEditions)
        XCTAssertFalse(corpus.liveAdmissionVerified); XCTAssertEqual(corpus.cases.count, 204)
        for entry in corpus.cases {
            var rows = Data(repeating: 0, count: entry.rowCount * ItemStatCostSnapshot.rowBytes)
            if Int(entry.id) < entry.rowCount {
                let offset = Int(entry.id) * ItemStatCostSnapshot.rowBytes
                rows.replaceSubrange(offset..<(offset + ItemStatCostSnapshot.rowBytes), with: try hex(entry.rowHex))
            }
            let usage = try CharacterStatUsage(itemIDs: entry.usageFlags & 2 == 0 ? [] : [entry.id],
                                               playerIDs: entry.usageFlags & 1 == 0 ? [] : [entry.id])
            let actual: [CharacterSidecar.Stat]?
            do {
                let names: [UInt16: String] = entry.name.map { [entry.id: $0] } ?? [:]
                let snapshot = try ItemStatCostSnapshot(edition: entry.edition, rows: rows, resolvedNames: names)
                actual = try snapshot.descriptors(for: usage)
            } catch { actual = nil }
            if let expected = entry.descriptor {
                XCTAssertEqual(actual, [CharacterSidecar.Stat(id: expected.id, flags: expected.flags, flag: expected.flag,
                    byte34: expected.byte34, byte35: expected.byte35, word30: expected.word30, word2c: expected.word2c,
                    byte38: expected.byte38, byte39: expected.byte39, name: try hex(expected.nameHex))], entry.label)
            } else { XCTAssertNil(actual, entry.label) }
        }
    }

    func testBitmapBoundariesAndRepeatedIDsHaveSetSemantics() throws {
        let all = Array(UInt16(0)...32767)
        let usage = try CharacterStatUsage(itemIDs: all, playerIDs: [0, 7, 63, 64, 32767, 32767])
        XCTAssertEqual(usage.itemBitmap, Data(repeating: 255, count: 4096))
        XCTAssertEqual(usage.itemIDs, all); XCTAssertEqual(usage.allIDs, all)
        XCTAssertEqual(usage.playerIDs, [0, 7, 63, 64, 32767])
        XCTAssertEqual(try usage.sidecarFlags(for: 32767), 3)
        XCTAssertEqual(try usage.sidecarFlags(for: 1), 2)
        XCTAssertEqual(try CharacterStatUsage(itemBitmap: Data([1, 0, 0]), playerBitmap: Data()).itemBitmap, Data([1]))
        XCTAssertThrowsError(try CharacterStatUsage(itemBitmap: Data(count: 4097), playerBitmap: Data()))
        XCTAssertThrowsError(try CharacterStatUsage(itemIDs: [32768], playerIDs: []))
    }

    func testMissingSchemaIsRejectedWithoutReturningAPartialDescriptorList() throws {
        let rows = Data(repeating: 0, count: 2 * ItemStatCostSnapshot.rowBytes)
        let snapshot = try ItemStatCostSnapshot(edition: 3, rows: rows, resolvedNames: [0: "first"])
        XCTAssertThrowsError(try snapshot.descriptors(for: CharacterStatUsage(itemIDs: [0, 1], playerIDs: []))) {
            XCTAssertEqual($0 as? CharacterStatUsageError, .missingName(1))
        }
        XCTAssertThrowsError(try snapshot.descriptors(for: CharacterStatUsage(itemIDs: [2], playerIDs: [])))
        XCTAssertEqual(try snapshot.descriptors(for: CharacterStatUsage(itemIDs: [], playerIDs: [])), [])
        XCTAssertThrowsError(try ItemStatCostSnapshot(edition: 0, rows: rows, resolvedNames: [:]))
        XCTAssertThrowsError(try ItemStatCostSnapshot(edition: 3, rows: Data([0]), resolvedNames: [:]))
    }

    func testMetadataBitmapsSelectItemAndPlayerRolesAndRequireMatchingEdition() throws {
        let metadata = try CharacterSaveMetadata(characterName: Data("NativeFixture".utf8), saveChecksum: 0,
            saveByteCount: 403, gameEdition: 3, saveSHA256: Data(repeating: 42, count: 32),
            word50: 0, word58: 0, word60: 0, word68: 0, flag70: false, blob71: Data([2]), blob1071: Data([1]))
        XCTAssertEqual(try metadata.statUsage().itemIDs, [1]); XCTAssertEqual(try metadata.statUsage().playerIDs, [0])
        let snapshot = try ItemStatCostSnapshot(edition: 2, rows: Data(), resolvedNames: [:])
        XCTAssertThrowsError(try snapshot.descriptors(for: metadata)) { XCTAssertEqual($0 as? CharacterStatUsageError, .edition) }
    }
}
