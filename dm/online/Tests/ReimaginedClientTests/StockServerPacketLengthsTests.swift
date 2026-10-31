import XCTest
@testable import ReimaginedClient

final class StockServerPacketLengthsTests: XCTestCase {
    func testRealFixedSizesAcrossEverySplitIncludingEmbeddedLoaderMagic() throws {
        for (opcode, count): (UInt8, Int) in [(0x01, 8), (0x03, 12), (0x25, 511), (0x56, 512)] {
            var bytes = Data(repeating: 0xd0, count: count)
            bytes[0] = opcode
            bytes.replaceSubrange(1..<5, with: Data("D2RL".utf8))
            for split in 0...count {
                let stream = GamePacketStream(resolvePacketLength: StockServerPacketLengths.resolve)
                try stream.append(bytes.prefix(split))
                if split < count { XCTAssertNil(try stream.nextPacket()) }
                try stream.append(bytes.dropFirst(split))
                stream.endOfInput()
                guard case .gameplay(let packet) = try stream.nextPacket() else { return XCTFail("Missing packet") }
                XCTAssertEqual(packet, bytes)
                XCTAssertNil(try stream.nextPacket())
            }
        }
    }

    func testFixedPacketsAndLoaderControlRetainTheirOrder() throws {
        let stream = GamePacketStream(resolvePacketLength: StockServerPacketLengths.resolve)
        let stock = Data([0x01, 0, 0, 0, 0, 0, 0, 0])
        let control = try ControlMessage(kind: 8, payload: Data()).gameCarrier()
        try stream.append(stock + control + Data([0x00]))
        guard case .gameplay(let first) = try stream.nextPacket(),
              case .control(let second) = try stream.nextPacket(),
              case .gameplay(let third) = try stream.nextPacket() else { return XCTFail("Routing changed") }
        XCTAssertEqual(first, stock); XCTAssertEqual(second.kind, 8); XCTAssertEqual(third, Data([0x00]))
        XCTAssertNil(try stream.nextPacket())
    }

    func testVariableInvalidAndSystemPacketsNeverResynchronizeIntoControl() throws {
        // Includes variable packets that old Diablo II references mark invalid,
        // plus the separate system greeting: neither may be guessed from a read.
        for opcode: UInt8 in [0x12, 0x17, 0x2b, 0x2e, 0xa6, 0xae, 0xaf, 0xd1, 0xff] {
            let stream = GamePacketStream(resolvePacketLength: StockServerPacketLengths.resolve)
            let carrier = try ControlMessage(kind: 8, payload: Data()).gameCarrier()
            try stream.append(Data([opcode, 0, 0]) + carrier)
            XCTAssertThrowsError(try stream.nextPacket()) {
                XCTAssertEqual($0 as? GamePacketStreamError, .unsupportedPacket(opcode))
            }
            XCTAssertThrowsError(try stream.nextPacket())
        }
        XCTAssertEqual(StockServerPacketLengths.descriptor(for: 0x17), .variable)
        XCTAssertEqual(StockServerPacketLengths.descriptor(for: 0x12), .unsupported)
    }

    func testTruncatedRealPacketFailsAtEOF() throws {
        let stream = GamePacketStream(resolvePacketLength: StockServerPacketLengths.resolve)
        try stream.append(Data([0x03]) + Data(repeating: 0, count: 10))
        XCTAssertNil(try stream.nextPacket())
        stream.endOfInput()
        XCTAssertThrowsError(try stream.nextPacket()) {
            XCTAssertEqual($0 as? GamePacketStreamError, .truncatedPacket)
        }
    }

    func testResolverAcceptsNonzeroDataStartIndexAndEmptyPrefixes() {
        let slice = Data([99, 99, 0x56]).dropFirst(2)
        guard case .length(512) = StockServerPacketLengths.resolve(slice),
              case .needMore = StockServerPacketLengths.resolve(Data()) else { return XCTFail("Invalid prefix handling") }
    }
}
