import XCTest
@testable import ReimaginedClient

final class ItemStatEnvironmentTests: XCTestCase {
    func testFullOriginalSchemaBuilderAndHash() throws {
        struct Corpus: Decodable {
            struct Entry: Decodable {
                let label: String; let edition: UInt8; let rowsHex: String
                let names: [String]; let fingerprintHex: String
            }
            let referenceSHA256: String; let cases: [Entry]; let liveAdmissionVerified: Bool
        }
        func hex(_ text: String) throws -> Data {
            let chars = Array(text)
            return try Data(stride(from: 0, to: chars.count, by: 2).map {
                try XCTUnwrap(UInt8(String(chars[$0...$0+1]), radix: 16))
            })
        }
        let url = try XCTUnwrap(Bundle.module.url(forResource: "itemstatcost-environment-reference", withExtension: "json"))
        let corpus = try JSONDecoder().decode(Corpus.self, from: Data(contentsOf: url))
        XCTAssertEqual(corpus.referenceSHA256, "2a868d013d2e0830bd2d9e04b918b19e46a73cf726c833e70d089b948fdeb5a2")
        XCTAssertEqual(corpus.cases.count, 67); XCTAssertFalse(corpus.liveAdmissionVerified)
        for entry in corpus.cases {
            let snapshot = try ItemStatCostSnapshot(edition: entry.edition, rows: hex(entry.rowsHex),
                resolvedNames: Dictionary(uniqueKeysWithValues: entry.names.enumerated().map { (UInt16($0.offset), $0.element) }))
            let field = try snapshot.environmentSchema()
            XCTAssertEqual(field.tag, entry.edition, entry.label)
            XCTAssertEqual(field.policyVersion, 2, entry.label)
            XCTAssertEqual(field.coverage, .complete, entry.label)
            XCTAssertEqual(field.value, UInt64(entry.fingerprintHex, radix: 16), entry.label)
        }
    }

    func testFullSchemaRejectsNamesMissingOutsideSelectedSaveUsage() throws {
        let snapshot = try ItemStatCostSnapshot(edition: 3, rows: Data(count: 2 * ItemStatCostSnapshot.rowBytes), resolvedNames: [0: "own_stat"])
        XCTAssertEqual(try snapshot.descriptors(for: CharacterStatUsage(itemIDs: [0], playerIDs: [])).count, 1)
        XCTAssertThrowsError(try snapshot.environmentSchema()) { XCTAssertEqual($0 as? CharacterStatUsageError, .missingName(1)) }
    }
}
