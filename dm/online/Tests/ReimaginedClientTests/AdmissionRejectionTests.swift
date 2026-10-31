import XCTest
@testable import ReimaginedClient

final class AdmissionRejectionTests: XCTestCase {
    func testObservedLiveRefusalThroughEverySplitBoundary() throws {
        struct Observation: Decodable { let responseHex: String; let rejectionCode: UInt8 }
        for fixture in ["live-incomplete-environment-rejection", "live-unavailable-environment-rejection"] {
            let file = try XCTUnwrap(Bundle.module.url(forResource: fixture, withExtension: "json"))
            let observation = try JSONDecoder().decode(Observation.self, from: Data(contentsOf: file))
            let hex = Array(observation.responseHex)
            let bytes = Data(stride(from: 0, to: hex.count, by: 2).map { UInt8(String(hex[$0...$0+1]), radix: 16)! })
            for split in 0...bytes.count {
                let stream = GamePacketStream(nativeSystemPackets: true, resolvePacketLength: StockServerPacketLengths.resolve)
                var packets: [DecodedGamePacket] = []
                func drain() throws { while let packet = try stream.nextPacket() { packets.append(packet) } }
                try stream.append(bytes.prefix(split)); try drain()
                try stream.append(bytes.dropFirst(split)); stream.endOfInput(); try drain()
                guard packets.count == 2, case .system(.ready(auxiliary: 0)) = packets[0],
                      case .control(let refusal) = packets[1] else { return XCTFail("Lost live control order") }
                let decoded = try AdmissionRejection.decode(refusal)
                XCTAssertEqual(decoded.code, observation.rejectionCode)
                let expected = observation.rejectionCode == 1 ? [Data(), Data(), Data()] : [Data(), Data([49]), Data([48])]
                XCTAssertEqual(decoded.details, expected)
                XCTAssertEqual(try decoded.controlMessage().gameCarrier(), Data(bytes.dropFirst(2)))
                XCTAssertNil(try stream.nextPacket())
            }
        }
    }

    func testBoundedOpaqueFieldsAndCodeRange() throws {
        for code in UInt8(1)...30 {
            let expected = try AdmissionRejection(code: code, details: [Data([0, 255]), Data(repeating: 0xd0, count: 63), Data()])
            XCTAssertEqual(try AdmissionRejection.decode(expected.controlMessage()), expected)
        }
        for code: UInt8 in [0, 31, 255] { XCTAssertThrowsError(try AdmissionRejection(code: code, details: [Data(), Data(), Data()])) }
        XCTAssertThrowsError(try AdmissionRejection(code: 1, details: []))
        XCTAssertThrowsError(try AdmissionRejection(code: 1, details: [Data(count: 64), Data(), Data()]))
    }

    func testMalformedRejectionCannotBecomeAcceptance() throws {
        for payload in [Data(), Data([1, 0, 0]), Data([1, 1, 0, 0]), Data([1, 0, 0, 0, 42]), Data([0, 0, 0, 0])] {
            XCTAssertThrowsError(try AdmissionRejection.decode(ControlMessage(kind: 9, payload: payload)))
        }
        XCTAssertThrowsError(try AdmissionRejection.decode(ControlMessage(kind: 8, payload: Data([1, 0, 0, 0]))))
    }
}
