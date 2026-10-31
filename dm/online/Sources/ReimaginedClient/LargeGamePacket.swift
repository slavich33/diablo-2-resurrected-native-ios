import Foundation

public enum LargeGamePacketError: Error, Equatable {
    case invalidFragment, unsupportedPacket, unexpectedFragment, truncatedPacket
}

/// Kind 11 is observed in the core's CLIENT-to-HOST oversized command sender.
/// These are complete game-packet-layer messages, not raw TCP records. The
/// receiving game must implement the matching wide command handlers too.
public struct LargeGamePacketFragment: Equatable {
    public static let maximumChunk = 188
    public static let minimumTotal = 513, maximumTotal = 1_817
    public let sequence: UInt32
    public let total: Int
    public let offset: Int
    public let bytes: Data

    public init(sequence: UInt32, total: Int, offset: Int, bytes: Data) throws {
        guard sequence != 0, (Self.minimumTotal...Self.maximumTotal).contains(total),
              (0..<total).contains(offset), (1...Self.maximumChunk).contains(bytes.count),
              bytes.count <= total - offset else { throw LargeGamePacketError.invalidFragment }
        self.sequence = sequence; self.total = total; self.offset = offset; self.bytes = bytes
    }

    public func frame() -> LoaderFrame {
        var payload = Data()
        for value in [total, offset] {
            payload.append(UInt8(truncatingIfNeeded: value)); payload.append(UInt8(truncatingIfNeeded: value >> 8))
        }
        payload.append(bytes)
        // The initializer bounds the four metadata bytes plus the chunk to 192.
        return try! LoaderFrame(kind: 11, sequence: sequence, payload: payload)
    }

    public static func decode(_ frame: LoaderFrame) throws -> LargeGamePacketFragment {
        guard frame.kind == 11, frame.channel == 0, frame.message == 0,
              (5...192).contains(frame.payload.count) else { throw LargeGamePacketError.invalidFragment }
        let b = Array(frame.payload)
        return try Self(sequence: frame.sequence, total: Int(b[0]) | (Int(b[1]) << 8),
                        offset: Int(b[2]) | (Int(b[3]) << 8), bytes: Data(b[4...]))
    }

    /// Four specific variable-length command forms, checked by both sender and
    /// receiver in the pinned core. This is NOT a general D2R packet-size table.
    public static func supports(_ packet: Data) -> Bool {
        guard (minimumTotal...maximumTotal).contains(packet.count) else { return false }
        let b = Array(packet)
        let header: Int, stride: Int
        switch b[0] {
        case 0x20: (header, stride) = (8, 5)
        case 0x22: (header, stride) = (10, 7)
        case 0x4e: (header, stride) = (7, 5)
        case 0x60: (header, stride) = (25, 7)
        default: return false
        }
        return header + (Int(b[header - 1]) + 1) * stride == b.count
    }

    public static func split(_ packet: Data, sequence: UInt32) throws -> [LargeGamePacketFragment] {
        guard supports(packet) else { throw LargeGamePacketError.unsupportedPacket }
        return try Swift.stride(from: 0, to: packet.count, by: maximumChunk).map { offset in
            try Self(sequence: sequence, total: packet.count, offset: offset,
                     bytes: Data(packet.dropFirst(offset).prefix(maximumChunk)))
        }
    }
}

/// One ordered transfer per peer/connection; call only from one consumer.
/// As in the inspected receiver, offset zero starts/replaces a transfer.
/// Mismatches clear it. Reset on disconnect, rejection and timeout. EOF alone
/// at the frame decoder cannot detect a missing *whole* final fragment.
public struct LargeGamePacketAssembly {
    private var sequence: UInt32 = 0
    private var total = 0
    private var bytes = Data()
    public var hasPendingTransfer: Bool { total != 0 }

    public init() {}
    public mutating func reset() { sequence = 0; total = 0; bytes = Data() }

    public mutating func accept(_ fragment: LargeGamePacketFragment) throws -> Data? {
        if fragment.offset == 0 { reset(); sequence = fragment.sequence; total = fragment.total }
        guard fragment.sequence == sequence, fragment.total == total, fragment.offset == bytes.count else {
            reset(); throw LargeGamePacketError.unexpectedFragment
        }
        bytes.append(fragment.bytes)
        guard bytes.count == total else { return nil }
        let packet = bytes; reset()
        guard LargeGamePacketFragment.supports(packet) else { throw LargeGamePacketError.unsupportedPacket }
        return packet
    }

    public mutating func endOfInput() throws {
        let incomplete = hasPendingTransfer; reset()
        if incomplete { throw LargeGamePacketError.truncatedPacket }
    }
}
