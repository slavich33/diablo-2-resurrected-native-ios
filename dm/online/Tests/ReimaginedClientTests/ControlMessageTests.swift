import XCTest
@testable import ReimaginedClient

final class ControlMessageTests: XCTestCase {
    private func hex(_ text: String) -> Data {
        let chars = Array(text)
        return Data(stride(from: 0, to: chars.count, by: 2).map { UInt8(String(chars[$0...$0 + 1]), radix: 16)! })
    }

    func testControlHeaderMatchesIndependentLittleEndianVector() throws {
        let expected = hex("4432524c010700000000000000000000040001020304")
        let message = try ControlMessage(kind: 7, payload: Data([1, 2, 3, 4]))
        XCTAssertEqual(message.encoded(), expected)
        let decoded = try ControlMessage.decode(expected)
        XCTAssertEqual(decoded.kind, 7); XCTAssertEqual(decoded.payload, message.payload)
        for kind in UInt8(7)...UInt8(10) {
            XCTAssertEqual(try ControlMessage.decode(ControlMessage(kind: kind, payload: Data()).encoded()).kind, kind)
        }
    }

    func testInvalidControlHeadersAndLengthsAreRejected() throws {
        let valid = try ControlMessage(kind: 7, payload: Data([1])).encoded()
        for index in [0, 4, 6, 8, 10, 12, 16] {
            var changed = valid; changed[index] ^= 1
            XCTAssertThrowsError(try ControlMessage.decode(changed))
        }
        XCTAssertThrowsError(try ControlMessage(kind: 6, payload: Data()))
        XCTAssertThrowsError(try ControlMessage(kind: 7, payload: Data(repeating: 0, count: 225)))
        XCTAssertThrowsError(try ControlMessage.decode(valid + Data([0])))
    }

    func testClientCarrierMatchesIndependentVectorAndRejectsTrailingData() throws {
        let expected = hex("d016004432524c010700000000000000000000040001020304")
        let message = try ControlMessage(kind: 7, payload: Data([1, 2, 3, 4]))
        XCTAssertEqual(message.clientCarrier(), expected)
        XCTAssertEqual(try ControlMessage.decodeClientCarrier(expected).payload, message.payload)
        var malformed = expected; malformed[1] -= 1
        XCTAssertThrowsError(try ControlMessage.decodeClientCarrier(malformed))
        XCTAssertThrowsError(try ControlMessage.decodeClientCarrier(expected + Data([0])))
    }

    func testFragmentVectorAndLargestEnvironmentRoundTrip() throws {
        let fragment = try EnvironmentFragment(total: 0x1234, offset: 0x100, bytes: Data([0xaa, 0xbb]))
        XCTAssertEqual(fragment.encoded(), hex("3412000000010000aabb"))
        let source = Data((0..<65_536).map { UInt8(truncatingIfNeeded: $0) })
        let fragments = try EnvironmentFragment.split(source)
        XCTAssertEqual(fragments.count, 304)
        var assembler = EnvironmentAssembly(), output: Data?
        for fragment in fragments {
            let control = try ControlMessage(kind: 7, payload: fragment.encoded())
            XCTAssertLessThanOrEqual(control.payload.count, 224)
            output = try assembler.append(EnvironmentFragment.decode(ControlMessage.decode(control.encoded()).payload))
        }
        XCTAssertEqual(output, source)
        XCTAssertThrowsError(try assembler.append(fragments[0]))
        assembler.reset()
        XCTAssertNil(try assembler.append(fragments[0]))
    }

    func testMalformedAndConflictingFragmentsCannotAdvanceAssembly() throws {
        XCTAssertThrowsError(try EnvironmentFragment(total: 65_537, offset: 0, bytes: Data([1])))
        XCTAssertThrowsError(try EnvironmentFragment(total: 2, offset: 1, bytes: Data([1, 2])))
        XCTAssertThrowsError(try EnvironmentFragment(total: 300, offset: 0, bytes: Data(repeating: 0, count: 217)))
        var assembler = EnvironmentAssembly()
        let first = try EnvironmentFragment(total: 4, offset: 0, bytes: Data([1, 2]))
        XCTAssertThrowsError(try assembler.append(EnvironmentFragment(total: 4, offset: 2, bytes: Data([3]))))
        XCTAssertNil(try assembler.append(first))
        XCTAssertThrowsError(try assembler.append(first))
        XCTAssertThrowsError(try assembler.append(EnvironmentFragment(total: 5, offset: 2, bytes: Data([3]))))
        XCTAssertEqual(try assembler.append(EnvironmentFragment(total: 4, offset: 2, bytes: Data([3, 4]))), Data([1, 2, 3, 4]))
    }
}
