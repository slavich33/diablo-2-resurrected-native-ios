import XCTest
@testable import ReimaginedClient

final class GamePacketStreamTests: XCTestCase {
    // Synthetic stock-packet lengths deliberately stand in for an engine
    // callback. They are not a purported D2R gameplay packet-size table.
    private func stream() -> GamePacketStream {
        GamePacketStream { header in
            switch header[0] {
            case 0x10: return .length(4)
            case 0x11: return header.count < 2 ? .needMore : .length(Int(header[1]) + 2)
            default: return .unsupported
            }
        }
    }

    func testAllControlKindsAndEverySplitBoundary() throws {
        for kind in UInt8(7)...10 {
            let payload = Data((0..<224).map(UInt8.init))
            let carrier = try ControlMessage(kind: kind, payload: payload).gameCarrier()
            for split in 0...carrier.count {
                let decoder = stream()
                try decoder.append(carrier.prefix(split))
                if split < carrier.count { XCTAssertNil(try decoder.nextPacket()) }
                try decoder.append(carrier.dropFirst(split))
                guard case .control(let actual) = try decoder.nextPacket() else { return XCTFail("Missing control") }
                XCTAssertEqual(actual.kind, kind)
                XCTAssertEqual(actual.payload, payload)
                XCTAssertNil(try decoder.nextPacket())
            }
        }
    }

    func testInterleavedStockAndControlPacketsOneByteAtATime() throws {
        let stock = Data([0x10, 1, 2, 3])
        let variable = Data([0x11, 3, 7, 8, 9])
        let control = try ControlMessage(kind: 8, payload: Data([42])).gameCarrier()
        let decoder = stream()
        var packets: [DecodedGamePacket] = []
        for byte in stock + control + variable + control {
            try decoder.append(Data([byte]))
            while let packet = try decoder.nextPacket() { packets.append(packet) }
        }
        XCTAssertEqual(packets.count, 4)
        guard case .gameplay(let first) = packets[0], case .control(let second) = packets[1],
              case .gameplay(let third) = packets[2], case .control(let fourth) = packets[3] else {
            return XCTFail("Packet order changed")
        }
        XCTAssertEqual(first, stock); XCTAssertEqual(third, variable)
        XCTAssertEqual(second.kind, 8); XCTAssertEqual(fourth.payload, Data([42]))
    }

    func testCoalescedInputAndDataWithNonzeroStartIndex() throws {
        let carrier = try ControlMessage(kind: 9, payload: Data([1])).gameCarrier()
        let source = Data([99, 99]) + carrier + Data([0x10, 1, 2, 3])
        let decoder = stream()
        try decoder.append(source.dropFirst(2))
        guard case .control(let control) = try decoder.nextPacket() else { return XCTFail("No control") }
        XCTAssertEqual(control.kind, 9)
        guard case .gameplay(let stock) = try decoder.nextPacket() else { return XCTFail("No stock") }
        XCTAssertEqual(stock, Data([0x10, 1, 2, 3]))
        XCTAssertEqual(decoder.bufferedBytes, 0)
    }

    func testTruncatedEOFIsTerminalButCompletePacketsCanBeDrainedFirst() throws {
        let decoder = stream()
        try decoder.append(Data([0x10, 1, 2, 3, 0xd0, 18]))
        decoder.endOfInput()
        guard case .gameplay = try decoder.nextPacket() else { return XCTFail("Dropped complete packet") }
        XCTAssertThrowsError(try decoder.nextPacket()) { XCTAssertEqual($0 as? GamePacketStreamError, .truncatedPacket) }
        XCTAssertThrowsError(try decoder.nextPacket())
        XCTAssertThrowsError(try decoder.append(Data([0])))
        XCTAssertEqual(decoder.bufferedBytes, 0)
        let clean = stream(); clean.endOfInput()
        XCTAssertNil(try clean.nextPacket())
        XCTAssertThrowsError(try clean.append(Data()))
    }

    func testUnknownOrMalformedPacketsCannotResynchronizeIntoFollowingControl() throws {
        let carrier = try ControlMessage(kind: 7, payload: Data()).gameCarrier()
        let decoder = stream()
        try decoder.append(Data([0xff]) + carrier)
        XCTAssertThrowsError(try decoder.nextPacket()) { XCTAssertEqual($0 as? GamePacketStreamError, .unsupportedPacket(0xff)) }
        XCTAssertThrowsError(try decoder.nextPacket())
        for prefix in [Data([0xd0, 0, 0]), Data([0xd0, 243, 0]), Data([0xd0, 255, 255])] {
            let malformed = stream(); try malformed.append(prefix + carrier)
            XCTAssertThrowsError(try malformed.nextPacket())
        }
        var badControl = carrier; badControl[3] = 0
        let malformed = stream(); try malformed.append(badControl + carrier)
        XCTAssertThrowsError(try malformed.nextPacket())
        XCTAssertThrowsError(try malformed.nextPacket())
    }

    func testBufferBackpressureRejectsAtomicallyAndPermitsRetryAfterDraining() throws {
        let packet = Data([0x10, 1, 2, 3])
        let bytes = Data(repeating: 0x10, count: GamePacketStream.maximumBufferedBytes)
        let decoder = stream(); try decoder.append(bytes)
        XCTAssertThrowsError(try decoder.append(packet)) { XCTAssertEqual($0 as? GamePacketStreamError, .bufferFull) }
        XCTAssertEqual(decoder.bufferedBytes, bytes.count)
        XCTAssertNotNil(try decoder.nextPacket())
        try decoder.append(packet)
        XCTAssertEqual(decoder.bufferedBytes, bytes.count)
    }

    func testInvalidResolverLengthsAndUnboundedHeaderRequestsTerminate() throws {
        for value in [-1, 0, GamePacketStream.maximumPacketBytes + 1] {
            let decoder = GamePacketStream { _ in .length(value) }
            try decoder.append(Data([1]))
            XCTAssertThrowsError(try decoder.nextPacket())
        }
        let decoder = GamePacketStream { _ in .needMore }
        try decoder.append(Data(repeating: 1, count: GamePacketStream.maximumHeaderBytes))
        XCTAssertThrowsError(try decoder.nextPacket())
    }

    func testLargestStockPacketIsNotConfusedWithControlInsidePayload() throws {
        let size = GamePacketStream.maximumPacketBytes
        let decoder = GamePacketStream { _ in .length(size) }
        let data = Data([0x10]) + Data(repeating: 0xd0, count: size - 1)
        try decoder.append(data.prefix(500))
        XCTAssertNil(try decoder.nextPacket())
        try decoder.append(data.dropFirst(500))
        guard case .gameplay(let packet) = try decoder.nextPacket() else { return XCTFail("Missing large packet") }
        XCTAssertEqual(packet, data)
    }
}
