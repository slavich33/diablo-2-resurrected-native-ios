import XCTest
@testable import ReimaginedClient

final class LoaderFrameTests: XCTestCase {
    private struct FrameCase: Decodable {
        let kind: UInt8, channel: UInt16, message: UInt16, sequence: UInt32
        let payloadHex: String, frameHex: String
        let accepted: Bool
    }
    private struct LargeCase: Decodable {
        let packetHex: String, sequence: UInt32, accepted: Bool, carrierHex: [String]
    }
    private struct Corpus: Decodable {
        let referenceSHA256: String, liveGameInteroperabilityVerified: Bool
        let frames: [FrameCase], largePackets: [LargeCase]
    }
    private func data(_ hex: String) throws -> Data {
        let b = Array(hex)
        return try Data(stride(from: 0, to: b.count, by: 2).map {
            try XCTUnwrap(UInt8(String(b[$0...$0 + 1]), radix: 16))
        })
    }
    private func corpus() throws -> Corpus {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "loader-frames-reference", withExtension: "json"))
        let c = try JSONDecoder().decode(Corpus.self, from: Data(contentsOf: url))
        XCTAssertEqual(c.referenceSHA256, "2a868d013d2e0830bd2d9e04b918b19e46a73cf726c833e70d089b948fdeb5a2")
        XCTAssertFalse(c.liveGameInteroperabilityVerified)
        return c
    }
    private func packet() throws -> Data {
        try data(XCTUnwrap(corpus().largePackets.first(where: { $0.accepted })).packetHex)
    }

    func testFramesMatchOfficialEncoderAndLeafDecoder() throws {
        for v in try corpus().frames {
            let bytes = try data(v.frameHex)
            if v.accepted {
                let expected = try LoaderFrame(kind: v.kind, channel: v.channel, message: v.message,
                                                sequence: v.sequence, payload: data(v.payloadHex))
                XCTAssertEqual(expected.encoded(), bytes)
                XCTAssertEqual(try LoaderFrame.decode(bytes), expected)
                XCTAssertEqual(try LoaderFrame.decodeGameCarrier(expected.gameCarrier()), expected)
            } else { XCTAssertThrowsError(try LoaderFrame.decode(bytes)) }
        }
    }

    func testOversizedClientCommandFragmentsMatchActualSenderQueue() throws {
        for v in try corpus().largePackets {
            let packet = try data(v.packetHex)
            if v.accepted {
                let pieces = try LargeGamePacketFragment.split(packet, sequence: v.sequence)
                XCTAssertEqual(try pieces.map { try $0.frame().gameCarrier() }, try v.carrierHex.map(data))
                var assembly = LargeGamePacketAssembly(), result: Data?
                for (index, carrier) in try v.carrierHex.map(data).enumerated() {
                    let piece = try LargeGamePacketFragment.decode(LoaderFrame.decodeGameCarrier(carrier))
                    XCTAssertEqual(piece, pieces[index])
                    result = try assembly.accept(piece)
                    if index < pieces.count - 1 { XCTAssertNil(result) }
                }
                XCTAssertEqual(result, packet)
                XCTAssertFalse(assembly.hasPendingTransfer)
                XCTAssertNoThrow(try assembly.endOfInput())
            } else { XCTAssertThrowsError(try LargeGamePacketFragment.split(packet, sequence: v.sequence)) }
        }
    }

    func testOpaqueLoaderFramesStaySeparateFromGameplayAndControl() throws {
        let frame = try LoaderFrame(kind: 1, channel: 0x1234, message: 9, sequence: 0xdeadbeef,
                                    payload: Data(repeating: 0xd0, count: 225))
        let carrier = try frame.gameCarrier(), control = try ControlMessage(kind: 8, payload: Data([42])).gameCarrier()
        for split in 0...carrier.count {
            let decoder = GamePacketStream { _ in .length(4) }
            try decoder.append(carrier.prefix(split))
            if split < carrier.count { XCTAssertNil(try decoder.nextPacket()) }
            try decoder.append(carrier.dropFirst(split) + control + Data([0x10, 1, 2, 3]))
            guard case .loader(let actual) = try decoder.nextPacket() else { return XCTFail("Lost loader frame") }
            XCTAssertEqual(actual, frame)
            guard case .control = try decoder.nextPacket(), case .gameplay = try decoder.nextPacket() else {
                return XCTFail("Mixed loader/gameplay ordering")
            }
        }
        // A generic header can hold these fields, but existing control families
        // still require zero metadata; this must not become an admission bypass.
        let invalid = try LoaderFrame(kind: 8, sequence: 1, payload: Data()).gameCarrier()
        let decoder = GamePacketStream { _ in .unsupported }; try decoder.append(invalid)
        XCTAssertThrowsError(try decoder.nextPacket())
        XCTAssertThrowsError(try decoder.nextPacket())
    }

    func testCarrierLengthIncludesEnvelopeAndCannotWrapUInt16() throws {
        let frame = try LoaderFrame(kind: 3, payload: Data(repeating: 9, count: 65_517))
        let carrier = try frame.gameCarrier()
        XCTAssertEqual(carrier.count, LoaderFrame.maximumCarrierBytes)
        let decoder = GamePacketStream { _ in XCTFail("Loader invoked stock resolver"); return .unsupported }
        try decoder.append(carrier.prefix(65_536)); XCTAssertNil(try decoder.nextPacket())
        try decoder.append(carrier.dropFirst(65_536))
        guard case .loader(let received) = try decoder.nextPacket() else { return XCTFail("Missing maximum carrier") }
        XCTAssertEqual(received, frame)
        XCTAssertEqual(try LoaderFrame.decodeGameCarrier((Data([99]) + carrier).dropFirst()), frame)
        for count in [65_518, 65_535] {
            let tooLarge = try LoaderFrame(kind: 1, payload: Data(repeating: 0, count: count))
            XCTAssertEqual(try LoaderFrame.decode(tooLarge.encoded()), tooLarge)
            XCTAssertThrowsError(try tooLarge.gameCarrier()) { XCTAssertEqual($0 as? LoaderFrameError, .carrierTooLarge) }
        }
        XCTAssertThrowsError(try LoaderFrame(kind: 4, payload: Data(repeating: 0, count: 225)))
        var invalid = carrier; invalid[19] = 0
        let broken = GamePacketStream { _ in .unsupported }; try broken.append(invalid.prefix(21))
        XCTAssertThrowsError(try broken.nextPacket()) // reject contradictory header before buffering65KB
    }

    func testAssemblyResetsMismatchesAndRequiresCompleteTransferAtEOF() throws {
        let bytes = try packet(), pieces = try LargeGamePacketFragment.split(bytes, sequence: 7)
        var a = LargeGamePacketAssembly()
        XCTAssertThrowsError(try a.accept(pieces[1])); XCTAssertFalse(a.hasPendingTransfer)
        XCTAssertNil(try a.accept(pieces[0])); XCTAssertTrue(a.hasPendingTransfer)
        XCTAssertThrowsError(try a.endOfInput()) { XCTAssertEqual($0 as? LargeGamePacketError, .truncatedPacket) }
        XCTAssertFalse(a.hasPendingTransfer)
        XCTAssertNil(try a.accept(pieces[0]))
        let wrong = try LargeGamePacketFragment(sequence: 8, total: pieces[1].total,
                                                offset: pieces[1].offset, bytes: pieces[1].bytes)
        XCTAssertThrowsError(try a.accept(wrong)); XCTAssertFalse(a.hasPendingTransfer)
        // Offset zero starts a replacement, as observed in the original receiver.
        XCTAssertNil(try a.accept(pieces[0])); XCTAssertNil(try a.accept(pieces[0]))
        var result: Data?
        for piece in pieces.dropFirst() { result = try a.accept(piece) }
        XCTAssertEqual(result, bytes)
        XCTAssertThrowsError(try LargeGamePacketFragment.split(bytes, sequence: 0))
        var bad = bytes; bad[0] = 0xff
        let invalidPieces = try stride(from: 0, to: bad.count, by: 188).map { offset in
            try LargeGamePacketFragment(sequence: 9, total: bad.count, offset: offset,
                                        bytes: Data(bad.dropFirst(offset).prefix(188)))
        }
        for piece in invalidPieces.dropLast() { XCTAssertNil(try a.accept(piece)) }
        XCTAssertThrowsError(try a.accept(XCTUnwrap(invalidPieces.last)))
        XCTAssertFalse(a.hasPendingTransfer)
    }
}
