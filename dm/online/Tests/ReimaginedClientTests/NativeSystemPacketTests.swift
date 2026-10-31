import XCTest
@testable import ReimaginedClient

final class NativeSystemPacketTests: XCTestCase {
    private func stream() -> GamePacketStream {
        GamePacketStream(nativeSystemPackets: true, resolvePacketLength: StockServerPacketLengths.resolve)
    }

    func testNativeHeadersAtEverySplitAndDataSlice() throws {
        let cases: [NativeSystemPacket] = [.ready(auxiliary: 0), .ready(auxiliary: 255), .disconnected,
            .failure(reason: 0x1234abcd), .characterChunk(marker: 0, payload: Data()),
            .characterChunk(marker: 1, payload: Data([0xaf, 0xb4, 0xd0, 0])),
            .characterChunk(marker: 255, payload: Data((0..<255).map(UInt8.init)))]
        for expected in cases {
            let bytes = try expected.encoded()
            XCTAssertEqual(try NativeSystemPacket.decode((Data([9, 9]) + bytes).dropFirst(2)), expected)
            for split in 0...bytes.count {
                let decoder = stream()
                try decoder.append(bytes.prefix(split))
                if split < bytes.count { XCTAssertNil(try decoder.nextPacket()) }
                try decoder.append(bytes.dropFirst(split))
                guard case .system(let packet) = try decoder.nextPacket() else { return XCTFail("Lost system channel") }
                XCTAssertEqual(packet, expected)
                decoder.endOfInput(); XCTAssertNil(try decoder.nextPacket())
            }
        }
    }

    func testSystemGameAndLoaderOrderOneByteAtATime() throws {
        let system = NativeSystemPacket.characterChunk(marker: 1, payload: Data(repeating: 0xd0, count: 255))
        let control = try ControlMessage(kind: 8, payload: Data()).gameCarrier()
        let bytes = Data([0xaf, 0, 0x00]) + (try system.encoded()) + control + Data([0xb0])
        let decoder = stream()
        var packets: [DecodedGamePacket] = []
        for byte in bytes {
            try decoder.append(Data([byte]))
            while let packet = try decoder.nextPacket() { packets.append(packet) }
        }
        XCTAssertEqual(packets.count, 5)
        guard case .system(.ready(auxiliary: 0)) = packets[0], case .gameplay(let game) = packets[1],
              case .system(let chunk) = packets[2], case .control(let loaded) = packets[3],
              case .system(.disconnected) = packets[4] else { return XCTFail("Channel order changed") }
        XCTAssertEqual(game, Data([0])); XCTAssertEqual(chunk, system); XCTAssertEqual(loaded.kind, 8)
    }

    func testTruncatedSystemEOFIsTerminal() throws {
        for bytes in [Data([0xaf]), Data([0xb3]), Data([0xb3, 2]), Data([0xb3, 2, 1, 42]), Data([0xb4, 1, 0, 0])] {
            let decoder = stream(); try decoder.append(bytes); decoder.endOfInput()
            XCTAssertThrowsError(try decoder.nextPacket()) { XCTAssertEqual($0 as? GamePacketStreamError, .truncatedPacket) }
            XCTAssertThrowsError(try decoder.nextPacket())
            XCTAssertThrowsError(try decoder.append(Data([0])))
        }
    }

    func testUnknownSystemIsNotSkippedAndOldStockEntryPointStaysStrict() throws {
        for opcode: UInt8 in [0xb1, 0xb2] {
            let decoder = stream(); try decoder.append(Data([opcode, 0xaf, 0]))
            XCTAssertThrowsError(try decoder.nextPacket()) { XCTAssertEqual($0 as? GamePacketStreamError, .unsupportedPacket(opcode)) }
            XCTAssertThrowsError(try decoder.nextPacket())
        }
        let stock = GamePacketStream(resolvePacketLength: StockServerPacketLengths.resolve)
        try stock.append(Data([0xaf, 0]))
        XCTAssertThrowsError(try stock.nextPacket()) { XCTAssertEqual($0 as? GamePacketStreamError, .unsupportedPacket(0xaf)) }
    }

    func testLogicalPacketMustMatchWholeNativeShape() throws {
        for bytes in [Data(), Data([0xaf]), Data([0xb0, 0]), Data([0xb3, 1, 0]), Data([0xb3, 0, 0, 1]), Data([0xb4, 0])] {
            XCTAssertThrowsError(try NativeSystemPacket.decode(bytes))
        }
        XCTAssertThrowsError(try NativeSystemPacket.characterChunk(marker: 0, payload: Data(count: 256)).encoded())
        // A zero-length marker is still a three-byte logical packet.
        XCTAssertEqual(try NativeSystemPacket.decode(Data([0xb3, 0, 0])), .characterChunk(marker: 0, payload: Data()))
    }
}
