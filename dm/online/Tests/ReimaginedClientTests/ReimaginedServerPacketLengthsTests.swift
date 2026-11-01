import XCTest
@testable import ReimaginedClient

final class ReimaginedServerPacketLengthsTests: XCTestCase {
    func testExtendedStateAcrossEverySplitDoesNotInventTrailingPacket() throws {
        // Synthetic deltas deliberately resemble unsupported opcodes. They
        // belong to this packet, independently of the TCP chunk boundary.
        let bytes = Data([0x96, 92, 0, 0, 0, 1, 2, 3, 4, 0xd9, 0x34])
        for split in 0...bytes.count {
            let stream = GamePacketStream(resolvePacketLength: ReimaginedServerPacketLengths.resolve)
            try stream.append(bytes.prefix(split))
            if split < bytes.count { XCTAssertNil(try stream.nextPacket()) }
            try stream.append(bytes.dropFirst(split) + Data([0x00]))
            stream.endOfInput()
            guard case .gameplay(let state) = try stream.nextPacket(),
                  case .gameplay(let next) = try stream.nextPacket() else { return XCTFail("Missing packet") }
            XCTAssertEqual(state, bytes); XCTAssertEqual(next, Data([0x00]))
            XCTAssertNil(try stream.nextPacket())
        }
        XCTAssertEqual(StockServerPacketLengths.descriptor(for: 0x96), .fixed(9))
    }

    func testExtendedMediumAndBigStateBoundariesAcrossEverySplit() throws {
        for (opcode,count): (UInt8,Int) in [(0x18,25),(0x95,23)] {
            let bytes = Data([opcode]) + Data(repeating: 0xd9,count: count-1)
            for split in 0...count {
                let stream = GamePacketStream(resolvePacketLength: ReimaginedServerPacketLengths.resolve)
                try stream.append(bytes.prefix(split))
                if split < count { XCTAssertNil(try stream.nextPacket()) }
                try stream.append(bytes.dropFirst(split) + Data([0x00]))
                stream.endOfInput()
                guard case .gameplay(let first) = try stream.nextPacket(),
                      case .gameplay(let next) = try stream.nextPacket() else { return XCTFail("Missing state") }
                XCTAssertEqual(first,bytes);XCTAssertEqual(next,Data([0x00]));XCTAssertNil(try stream.nextPacket())
            }
        }
        XCTAssertEqual(StockServerPacketLengths.descriptor(for: 0x18), .fixed(19))
        XCTAssertEqual(StockServerPacketLengths.descriptor(for: 0x95), .fixed(17))
        for (opcode,short): (UInt8,Int) in [(0x18,19),(0x95,17),(0x96,9)] {
            let stream = GamePacketStream(resolvePacketLength: ReimaginedServerPacketLengths.resolve)
            try stream.append(Data([opcode]) + Data(repeating: 0,count:short-1))
            stream.endOfInput()
            XCTAssertThrowsError(try stream.nextPacket()) {
                XCTAssertEqual($0 as? GamePacketStreamError, .truncatedPacket)
            }
        }
    }
}
