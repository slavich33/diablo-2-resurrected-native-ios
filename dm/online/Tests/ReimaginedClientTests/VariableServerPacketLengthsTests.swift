import XCTest
@testable import ReimaginedClient

final class VariableServerPacketLengthsTests: XCTestCase {
    private func samples() -> [Data] {
        let definitions: [(UInt8, Int, [Int: UInt8])] = [
            (0x3e, 2, [1: 2]), (0x3e, 34, [1: 34]),
            (0x5b, 97, [1: 97, 2: 0]), (0x5b, 300, [1: 44, 2: 1]),
            (0x67, 22, [20: 0]), (0x67, 26, [20: 1]), (0x67, 1042, [20: 255]),
            (0x70, 6, [1: 0]), (0x70, 510, [1: 63]),
            (0x71, 23, [21: 0]), (0x71, 83, [21: 15]),
            (0x72, 22, [20: 0]), (0x72, 82, [20: 15]),
            (0x73, 21, [20: 0]), (0x73, 88, [20: 1]),
            (0x78, 7, [6: 0]), (0x78, 262, [6: 255]),
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
            Data([0x3e, 0]), Data([0x3e, 1]), Data([0x3e, 35]),
            Data([0x70, 64]), Data([0x70, 255]),
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

    func testRecordBatchWaitsForCountAndCompleteBodyWithoutScanningPayload() throws {
        var bytes = Data(repeating: 0xd0, count: 21 + 67 * 255)
        bytes[0] = 0x73; bytes[20] = 255
        for count in 0..<21 {
            guard case .needMore = StockServerPacketLengths.resolve(bytes.prefix(count)) else {
                return XCTFail("Read count before its header byte arrived")
            }
        }
        guard case .length(17_106) = StockServerPacketLengths.resolve((Data([99]) + bytes).dropFirst()) else {
            return XCTFail("Incorrect maximum batch length")
        }
        let control = try ControlMessage(kind: 8, payload: Data()).gameCarrier()
        let stream = GamePacketStream(resolvePacketLength: StockServerPacketLengths.resolve)
        try stream.append(bytes.dropLast())
        XCTAssertNil(try stream.nextPacket())
        try stream.append(bytes.suffix(1) + control)
        guard case .gameplay(let actual) = try stream.nextPacket(),
              case .control(let following) = try stream.nextPacket() else { return XCTFail("Lost batch boundary") }
        XCTAssertEqual(actual, bytes)
        XCTAssertEqual(following.kind, 8)
        XCTAssertNil(try stream.nextPacket())
        let truncated = GamePacketStream(resolvePacketLength: StockServerPacketLengths.resolve)
        try truncated.append(bytes.dropLast()); truncated.endOfInput()
        XCTAssertThrowsError(try truncated.nextPacket()) {
            XCTAssertEqual($0 as? GamePacketStreamError, .truncatedPacket)
        }
    }

    func testPayloadByteCountExcludesHeaderAndRetainsEmbeddedControlBytes() throws {
        // This payload deliberately resembles a loader carrier. Only the outer
        // packet's byte count determines its boundary.
        let payload = try ControlMessage(kind: 8, payload: Data([0x78, 0xd0, 0])).gameCarrier()
        var packet = Data([0x78, 1, 2, 3, 4, 5, UInt8(payload.count)])
        packet.append(payload)
        for count in 0..<7 {
            guard case .needMore = StockServerPacketLengths.resolve(packet.prefix(count)) else {
                return XCTFail("Read payload count before the complete header")
            }
        }
        let slice = (Data([99]) + packet).dropFirst()
        guard case .length(let size) = StockServerPacketLengths.resolve(slice), size == packet.count else {
            return XCTFail("Payload count was treated as a total length")
        }
        let control = try ControlMessage(kind: 8, payload: Data()).gameCarrier()
        let stream = GamePacketStream(resolvePacketLength: ReimaginedServerPacketLengths.resolve)
        try stream.append(packet.dropLast())
        XCTAssertNil(try stream.nextPacket())
        try stream.append(packet.suffix(1) + control)
        guard case .gameplay(let actual) = try stream.nextPacket(),
              case .control(let following) = try stream.nextPacket() else {
            return XCTFail("Lost the boundary after a counted payload")
        }
        XCTAssertEqual(actual, packet); XCTAssertEqual(following.kind, 8)
        let truncated = GamePacketStream(resolvePacketLength: StockServerPacketLengths.resolve)
        try truncated.append(packet.dropLast()); truncated.endOfInput()
        XCTAssertThrowsError(try truncated.nextPacket()) {
            XCTAssertEqual($0 as? GamePacketStreamError, .truncatedPacket)
        }
    }

    func testPathBatchCountCannotOverflowNativeReceiverBuffer() throws {
        let control = try ControlMessage(kind: 8, payload: Data()).gameCarrier()
        let definitions: [(UInt8, Int)] = [(0x71, 23), (0x72, 22)]
        for (opcode, header) in definitions {
            for count in [UInt8(16), 17, 255] {
                var packet = Data(repeating: 0, count: header)
                packet[0] = opcode; packet[header - 2] = count
                let stream = GamePacketStream(resolvePacketLength: ReimaginedServerPacketLengths.resolve)
                try stream.append(packet + control)
                XCTAssertThrowsError(try stream.nextPacket()) {
                    XCTAssertEqual($0 as? GamePacketStreamError, .invalidLength)
                }
                XCTAssertThrowsError(try stream.nextPacket())
            }
            for count in 0..<(header - 1) {
                var partial = Data(repeating: 0, count: count)
                if !partial.isEmpty { partial[0] = opcode }
                guard case .needMore = StockServerPacketLengths.resolve(partial) else {
                    return XCTFail("Read path count before its header byte")
                }
            }
        }
    }

    func testFullRecordBatchCanBeFollowedByEmptyFinalBatch() throws {
        var full = Data(repeating: 0xd0, count: 510)
        full[0] = 0x70; full[1] = 63; full[2] = 1; full[3] = 0
        let final = Data([0x70, 0, 2, 0, 2, 0])
        let control = try ControlMessage(kind: 8, payload: Data()).gameCarrier()
        let stream = GamePacketStream(resolvePacketLength: ReimaginedServerPacketLengths.resolve)
        try stream.append(full + final + control)
        guard case .gameplay(let first) = try stream.nextPacket(),
              case .gameplay(let second) = try stream.nextPacket(),
              case .control(let third) = try stream.nextPacket() else {
            return XCTFail("Empty final batch was lost")
        }
        XCTAssertEqual(first, full); XCTAssertEqual(second, final); XCTAssertEqual(third.kind, 8)
        XCTAssertNil(try stream.nextPacket())
        let truncated = GamePacketStream(resolvePacketLength: StockServerPacketLengths.resolve)
        try truncated.append(final.dropLast()); truncated.endOfInput()
        XCTAssertThrowsError(try truncated.nextPacket()) {
            XCTAssertEqual($0 as? GamePacketStreamError, .truncatedPacket)
        }
    }
}
