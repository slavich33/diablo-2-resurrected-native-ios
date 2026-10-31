import XCTest
@testable import ReimaginedClient

final class EnvironmentDescriptionTests: XCTestCase {
    func testOriginalRequiredFieldParserReference() throws {
        struct Corpus: Decodable {
            struct Entry: Decodable { let label: String; let envelopeHex: String; let accepted: Bool }
            let referenceSHA256: String
            let cases: [Entry]
            let liveAdmissionVerified: Bool
        }
        let url = try XCTUnwrap(Bundle.module.url(forResource: "required-environment-reference", withExtension: "json"))
        let corpus = try JSONDecoder().decode(Corpus.self, from: Data(contentsOf: url))
        XCTAssertEqual(corpus.referenceSHA256, "2a868d013d2e0830bd2d9e04b918b19e46a73cf726c833e70d089b948fdeb5a2")
        XCTAssertFalse(corpus.liveAdmissionVerified)
        XCTAssertEqual(corpus.cases.count, 276)
        XCTAssertEqual(corpus.cases.filter(\.accepted).count, 24)
        for entry in corpus.cases {
            let text = Array(entry.envelopeHex)
            XCTAssertTrue(text.count.isMultiple(of: 2), entry.label)
            var bytes = Data()
            for offset in stride(from: 0, to: text.count, by: 2) {
                bytes.append(try XCTUnwrap(UInt8(String(text[offset...offset + 1]), radix: 16)))
            }
            let decoded: EnvironmentDescription?
            do { decoded = try EnvironmentDescription.decode(EnvironmentEnvelope.decode(bytes)) }
            catch { decoded = nil }
            XCTAssertEqual(decoded != nil, entry.accepted, entry.label)
            if let decoded { XCTAssertEqual(try decoded.envelope().encoded(), bytes, entry.label) }
        }
    }

    func testUnavailableProfileHasAllRequiredFieldsAndNoClaimedData() throws {
        let profile = try EnvironmentDescription.unavailableProfile()
        let envelope = try profile.envelope()
        XCTAssertEqual(envelope.fields.map(\.id), [1, 2, 3, 4, 5, 6])
        XCTAssertTrue(envelope.fields.allSatisfy(\.required))
        XCTAssertEqual(envelope.fields.map { $0.payload.count }, [14, 8, 64, 16, 16, 2])
        XCTAssertEqual(envelope.fields[0].payload, Data([2,0,0,0,0,0,0,0,4,0,7,0,0,0]))
        let decoded = try EnvironmentDescription.decode(EnvironmentEnvelope.decode(envelope.encoded()))
        XCTAssertEqual(decoded.contract, profile.contract); XCTAssertEqual(decoded.aggregate, profile.aggregate)
        XCTAssertEqual(decoded.groups, profile.groups); XCTAssertEqual(decoded.banks, profile.banks)
        XCTAssertEqual(decoded.itemStatSchemas, profile.itemStatSchemas)
        XCTAssertTrue(decoded.namedFingerprints.isEmpty)
        XCTAssertEqual(try decoded.envelope().encoded(), envelope.encoded())
    }

    func testEveryRequiredFieldMustBePresentAndFullyConsumed() throws {
        let fields = try EnvironmentDescription.unavailableProfile().envelope().fields
        for index in fields.indices {
            var missing = fields; missing.remove(at: index)
            XCTAssertThrowsError(try EnvironmentDescription.decode(EnvironmentEnvelope(fields: missing)))
            let original = fields[index]
            for payload in [Data(original.payload.dropLast()), original.payload + Data([0])] {
                var changed = fields; changed[index] = EnvironmentField(id: original.id, required: true, payload: payload)
                XCTAssertThrowsError(try EnvironmentDescription.decode(EnvironmentEnvelope(fields: changed)))
            }
        }
    }

    func testRollupAndBankAvailabilityCannotClaimMissingData() throws {
        XCTAssertThrowsError(try FingerprintRollup(policyVersion: 4, coverage: .unavailable, componentCount: 1, digest: nil))
        XCTAssertThrowsError(try FingerprintRollup(policyVersion: 4, coverage: .partial, componentCount: 0, digest: nil))
        XCTAssertThrowsError(try FingerprintRollup(policyVersion: 4, coverage: .complete, componentCount: 1, digest: nil))
        XCTAssertThrowsError(try EnvironmentBank(tag: 1, policyVersion: 4, coverage: .complete, digest: nil))
        XCTAssertThrowsError(try EnvironmentBank(tag: 1, policyVersion: 4, coverage: .unavailable, digest: Data(count: 32)))
        XCTAssertThrowsError(try EnvironmentItemStatSchema(tag: 1, policyVersion: 2, coverage: .unavailable, value: 0))
        XCTAssertThrowsError(try EnvironmentContract(version: 2, sidecarCapability: 0, sidecarFormat: 1, word8: 4, word10: 7))
        XCTAssertThrowsError(try EnvironmentContract(version: 2, sidecarCapability: 2, sidecarFormat: 1, word8: 4, word10: 7))
    }

    func testAggregateMustMatchCountsCoverageAndCanonicalGroups() throws {
        let base = try EnvironmentDescription.unavailableProfile()
        let known = try FingerprintRollup(policyVersion: 4, coverage: .complete, componentCount: 1, digest: Data(repeating: 42, count: 32))
        var groups = base.groups; groups[0] = EnvironmentFingerprintGroup(tag: 1, rollup: known)
        XCTAssertThrowsError(try EnvironmentDescription(contract: base.contract, aggregate: base.aggregate, groups: groups,
            banks: base.banks, itemStatSchemas: base.itemStatSchemas, namedFingerprints: []))
        let aggregate = try FingerprintRollup(policyVersion: 4, coverage: .partial, componentCount: 1, digest: Data(repeating: 43, count: 32))
        let valid = try EnvironmentDescription(contract: base.contract, aggregate: aggregate, groups: groups,
            banks: base.banks, itemStatSchemas: base.itemStatSchemas, namedFingerprints: [])
        XCTAssertEqual(try EnvironmentDescription.decode(valid.envelope()).groups, groups)
        groups.swapAt(0, 1)
        XCTAssertThrowsError(try EnvironmentDescription(contract: base.contract, aggregate: aggregate, groups: groups,
            banks: base.banks, itemStatSchemas: base.itemStatSchemas, namedFingerprints: []))
    }
}
