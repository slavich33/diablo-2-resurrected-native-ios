import XCTest
import CryptoKit
@testable import ReimaginedClient

final class CharacterSidecarHistoryTests: XCTestCase {
    private func hex(_ text: String) throws -> Data {
        let chars = Array(text)
        return try Data(stride(from: 0, to: chars.count, by: 2).map { try XCTUnwrap(UInt8(String(chars[$0...$0+1]), radix: 16)) })
    }
    private func candidate() throws -> CharacterSidecar {
        struct Corpus: Decodable { struct Entry: Decodable { let fileHex: String }; let cases: [Entry] }
        let url = try XCTUnwrap(Bundle.module.url(forResource: "sidecar-signing-reference", withExtension: "json"))
        let corpus = try JSONDecoder().decode(Corpus.self, from: Data(contentsOf: url))
        return try CharacterSidecar.decode(hex(XCTUnwrap(corpus.cases.first).fileHex))
    }

    func testOriginalHistoryFoldAndClockCorpus() throws {
        struct Corpus: Decodable {
            struct Entry: Decodable {
                let action: String, oldFileHex: String, currentFileHex: String, randomIDHex: String, unsignedFixedFieldsHex: String
                let clockTicks: Int64, timestamp: UInt64, initialRestartFlag: Bool, extraFlag: Bool
            }
            let referenceSHA256: String, cases: [Entry], liveAdmissionVerified: Bool
        }
        let url = try XCTUnwrap(Bundle.module.url(forResource: "sidecar-history-reference", withExtension: "json"))
        let c = try JSONDecoder().decode(Corpus.self, from: Data(contentsOf: url))
        XCTAssertEqual(c.referenceSHA256, "2a868d013d2e0830bd2d9e04b918b19e46a73cf726c833e70d089b948fdeb5a2")
        XCTAssertEqual(c.cases.count, 143); XCTAssertFalse(c.liveAdmissionVerified)
        for entry in c.cases {
            XCTAssertEqual(try CharacterSidecar.historyTimestamp(date: Date(timeIntervalSince1970: Double(entry.clockTicks) / 10_000_000)), entry.timestamp)
            let current = try CharacterSidecar.decode(hex(entry.currentFileHex))
            let fields: Data
            if entry.action == "initial" {
                fields = try SidecarHistoryFields.initial(current.fixedFields, timestamp: entry.timestamp,
                    identifier: hex(entry.randomIDHex), restart: entry.initialRestartFlag, discontinuity: entry.extraFlag)
            } else {
                let previousFile = try hex(entry.oldFileHex), previous = try CharacterSidecar.decode(previousFile)
                if entry.action == "resetRequiresExplicitDecision" {
                    XCTAssertThrowsError(try SidecarHistoryFields.advance(current.fixedFields, previous: previous.fixedFields,
                        previousFile: previousFile, timestamp: entry.timestamp, discontinuity: entry.extraFlag)) {
                        XCTAssertEqual($0 as? CharacterSidecarHistoryError, .counterExhausted)
                    }
                    continue
                }
                fields = try SidecarHistoryFields.advance(current.fixedFields, previous: previous.fixedFields,
                    previousFile: previousFile, timestamp: entry.timestamp, discontinuity: entry.extraFlag)
            }
            XCTAssertEqual(fields, try hex(entry.unsignedFixedFieldsHex))
        }
    }

    func testOwnSignedHistoryAdvancesWithoutChangingIdentity() throws {
        let current = try candidate(), key = P256.Signing.PrivateKey(), id = Data(1...16)
        let first = try current.startingSignedHistory(using: key, timestamp: 100, historyID: id)
        try first.verifySeal(expectedPublicKey: key.publicKey.rawRepresentation)
        XCTAssertEqual(first.historyIdentifier, id); XCTAssertEqual(first.historyCounter, 1)
        XCTAssertEqual(first.fixedFields[88..<120], Data(repeating: 0, count: 32))
        let oldBytes = first.encoded()
        let next = try current.advancingSignedHistory(from: oldBytes, using: key, timestamp: 105)
        try next.verifySeal(expectedPublicKey: key.publicKey.rawRepresentation)
        XCTAssertEqual(next.historyIdentifier, first.historyIdentifier); XCTAssertEqual(next.historyCounter, 2)
        XCTAssertEqual(next.fixedFields[88..<120], Data(SHA256.hash(data: oldBytes)))
        XCTAssertEqual(SidecarHistoryFields.number(next.fixedFields, 64, 8), 100)
        XCTAssertEqual(SidecarHistoryFields.number(next.fixedFields, 72, 8), 105)
        XCTAssertEqual(next.saveChecksum, current.saveChecksum); XCTAssertEqual(next.stats, current.stats)
        let rollback = try current.advancingSignedHistory(from: next.encoded(), using: key, timestamp: 50)
        XCTAssertEqual(rollback.fixedFields[120] & 2, 2)
        try rollback.verifySeal(expectedPublicKey: key.publicKey.rawRepresentation)
        XCTAssertEqual(rollback.historyCounter, 3)
    }

    func testCorruptUnsignedWrongKeyAndExhaustedHistoryDoNotReset() throws {
        let current = try candidate(), key = P256.Signing.PrivateKey()
        let previous = try current.startingSignedHistory(using: key, timestamp: 100)
        var broken = previous.encoded(); broken[broken.count - 1] ^= 1
        XCTAssertThrowsError(try current.advancingSignedHistory(from: broken, using: key, timestamp: 105))
        XCTAssertThrowsError(try current.advancingSignedHistory(from: previous.encoded(), using: P256.Signing.PrivateKey(), timestamp: 105))
        XCTAssertThrowsError(try current.advancingSignedHistory(from: current.encoded(), using: key, timestamp: 105))
        XCTAssertThrowsError(try current.advancingSignedHistory(from: current.encoded(), using: key, timestamp: 105,
            trustedUnsignedPredecessorSHA256: Data(repeating: 0, count: 32)))
        let adopted = try current.advancingSignedHistory(from: current.encoded(), using: key, timestamp: 105,
            trustedUnsignedPredecessorSHA256: Data(SHA256.hash(data: current.encoded())))
        XCTAssertEqual(adopted.historyIdentifier, current.historyIdentifier)
        XCTAssertEqual(adopted.historyCounter, current.historyCounter + 1)
        try adopted.verifySeal(expectedPublicKey: key.publicKey.rawRepresentation)
        XCTAssertThrowsError(try previous.advancingSignedHistory(from: previous.encoded(), using: key, timestamp: 105))
        var fields = previous.fixedFields
        fields.replaceSubrange(80..<88, with: Data(repeating: 255, count: 8))
        fields.replaceSubrange(88..<120, with: Data(repeating: 42, count: 32))
        fields[120] |= 4; fields.replaceSubrange(160..<296, with: Data(repeating: 0, count: 136))
        let exhausted = try CharacterSidecar(fixedFields: fields, texts: current.texts, mod: current.mod, plugins: current.plugins, stats: current.stats).sealed(using: key)
        XCTAssertThrowsError(try current.advancingSignedHistory(from: exhausted.encoded(), using: key, timestamp: 105)) {
            XCTAssertEqual($0 as? CharacterSidecarHistoryError, .counterExhausted)
        }
        XCTAssertThrowsError(try current.startingSignedHistory(using: key, timestamp: 0))
        XCTAssertThrowsError(try current.startingSignedHistory(using: key, timestamp: 100, historyID: Data(repeating: 0, count: 16)))
        XCTAssertThrowsError(try CharacterSidecar.historyTimestamp(date: Date(timeIntervalSince1970: .nan)))
        XCTAssertThrowsError(try CharacterSidecar.historyTimestamp(date: Date(timeIntervalSince1970: .infinity)))
    }
}
