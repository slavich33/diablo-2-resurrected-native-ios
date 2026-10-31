import XCTest
@testable import ReimaginedClient

final class VariableServerPacketLengthsTests: XCTestCase {
    private func samples() -> [Data] {
        let definitions: [(UInt8, Int, [Int: UInt8])] = [
            (0x5b, 97, [1: 97, 2: 0]), (0x5b, 300, [1: 44, 2: 1]),
            (0x67, 22, [20: 0]), (0x67, 26, [20: 1]), (0x67, 1042, [20: 255]),
            (0x94, 6, [1: 0]), (0x94, 30, [1: 8]), (0x94, 771, [1: 255]),
            (0x9c, 20, [2: 20]), (0x9c, 252, [2: 252]),
            (0x9d, 33, [2: 33]), (0xa8, 12, [2: 12]),
            (0xaa, 14, [6: 14]), (0xac, 15, [12: 15]),
        ]
        return definitions.map { opcode, length, fields in
            var bytes = Data(repeating: 0, count: length)
            bytes[0] = opcode
            for (index, value) in fields { bytes[index] = value }
            return bytes
        }
    }

    func testVerifiedVariablesAtEverySplitAndTheirCountBoundaries() throws {
        for bytes in samples() {
            for split in 0...bytes.count {
                let stream = GamePacketStream(resolvePacketLength: StockServerPacketLengths.resolve)
                try stream.append(bytes.prefix(split))
                if split < bytes.count { XCTAssertNil(try stream.nextPacket()) }
                try stream.append(bytes.dropFirst(split))
                stream.endOfInput()
                guard case .gameplay(let actual) = try stream.nextPacket() else { return XCTFail("Missing variable") }
                XCTAssertEqual(actual, bytes)
                XCTAssertNil(try stream.nextPacket())
            }
        }
    }

    func testMixedVariablesAndLoaderControlDoNotLoseBoundaries() throws {
        let stream = GamePacketStream(resolvePacketLength: StockServerPacketLengths.resolve)
        let control = try ControlMessage(kind: 8, payload: Data()).gameCarrier()
        let expected = samples()
        try stream.append(expected.reduce(Data(), +) + control)
        for bytes in expected {
            guard case .gameplay(let actual) = try stream.nextPacket() else { return XCTFail("Routing changed") }
            XCTAssertEqual(actual, bytes)
        }
        guard case .control(let actual) = try stream.nextPacket() else { return XCTFail("Lost control") }
        XCTAssertEqual(actual.kind, 8)
        XCTAssertNil(try stream.nextPacket())
    }

    func testMalformedDeclaredLengthsAreTerminalBeforeFollowingControl() throws {
        let malformed: [Data] = [
            Data([0x5b, 95, 0]), Data([0x9c, 0, 7]), Data([0x9c, 0, 253]),
            Data([0x9d, 0, 12]), Data([0xa8, 0, 8]),
            Data([0xaa, 0, 0, 0, 0, 0, 8]),
            Data([0xac]) + Data(repeating: 0, count: 11) + Data([12]),
        ]
        let control = try ControlMessage(kind: 8, payload: Data()).gameCarrier()
        for bytes in malformed {
            let stream = GamePacketStream(resolvePacketLength: StockServerPacketLengths.resolve)
            try stream.append(bytes + control)
            XCTAssertThrowsError(try stream.nextPacket()) {
                XCTAssertEqual($0 as? GamePacketStreamError, .invalidLength)
            }
            XCTAssertThrowsError(try stream.nextPacket())
        }
    }

    func testNativeStateAddUsesByteTwoAndHandlesDataSlices() throws {
        var bytes = Data(repeating: 0, count: 12)
        bytes[0] = 0xa8; bytes[2] = 12 // byte6 deliberately remains zero
        let slice = (Data([99, 99]) + bytes).dropFirst(2)
        guard case .length(12) = StockServerPacketLengths.resolve(slice) else { return XCTFail("Legacy length offset used") }
        let stream = GamePacketStream(resolvePacketLength: StockServerPacketLengths.resolve)
        try stream.append(slice.prefix(3))
        stream.endOfInput()
        XCTAssertThrowsError(try stream.nextPacket()) {
            XCTAssertEqual($0 as? GamePacketStreamError, .truncatedPacket)
        }
    }
}
