import XCTest
@testable import ReimaginedClient

/// Outputs of the official core's encoder functions, run in an offline reference
/// CPU model with generic vector allocation/copy helpers. No Windows game session.
final class LoaderReferenceTests: XCTestCase {
    private struct Vector: Decodable {
        let type: String
        let kind: UInt8?
        let total: Int?
        let offset: Int?
        let payloadHex: String
        let accepted: Bool
        let outputHex: String
    }
    private struct Corpus: Decodable {
        let referenceSHA256: String
        let liveInteropVerified: Bool
        let vectors: [Vector]
    }
    private func data(_ hex: String) throws -> Data {
        let chars = Array(hex)
        guard chars.count.isMultiple(of: 2) else { throw ControlMessageError.invalidSize }
        return try Data(stride(from: 0, to: chars.count, by: 2).map {
            try XCTUnwrap(UInt8(String(chars[$0...$0 + 1]), radix: 16))
        })
    }
    func testNativeCodeMatchesOfficialEncoderFixtures() throws {
        for resource in ["loader-control-reference", "loader-control-senders"] {
            let url = try XCTUnwrap(Bundle.module.url(forResource: resource, withExtension: "json"))
            let corpus = try JSONDecoder().decode(Corpus.self, from: Data(contentsOf: url))
            XCTAssertEqual(corpus.referenceSHA256, "2a868d013d2e0830bd2d9e04b918b19e46a73cf726c833e70d089b948fdeb5a2")
            XCTAssertFalse(corpus.liveInteropVerified)
            XCTAssertFalse(corpus.vectors.isEmpty)
            for vector in corpus.vectors {
                let payload = try data(vector.payloadHex), expected = try data(vector.outputHex)
                switch vector.type {
                case "control", "carrier", "client_send", "server_send":
                    let kind = try XCTUnwrap(vector.kind)
                    if vector.accepted {
                        let message = try ControlMessage(kind: kind, payload: payload)
                        if vector.type == "control" {
                            XCTAssertEqual(message.encoded(), expected)
                            XCTAssertEqual(try ControlMessage.decode(expected).payload, payload)
                        } else {
                            XCTAssertEqual(message.gameCarrier(), expected)
                            XCTAssertEqual(try ControlMessage.decodeGameCarrier(expected).payload, payload)
                        }
                    } else {
                        XCTAssertThrowsError(try ControlMessage(kind: kind, payload: payload))
                    }
                case "fragment":
                    let total = try XCTUnwrap(vector.total), offset = try XCTUnwrap(vector.offset)
                    if vector.accepted {
                        let fragment = try EnvironmentFragment(total: total, offset: offset, bytes: payload)
                        XCTAssertEqual(fragment.encoded(), expected)
                        XCTAssertEqual(try EnvironmentFragment.decode(expected).bytes, payload)
                    } else {
                        XCTAssertThrowsError(try EnvironmentFragment(total: total, offset: offset, bytes: payload))
                    }
                default: XCTFail("Unknown reference fixture type")
                }
            }
        }
    }
}
