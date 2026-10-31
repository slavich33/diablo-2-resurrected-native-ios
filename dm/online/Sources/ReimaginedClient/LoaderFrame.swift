import Foundation

public enum LoaderFrameError: Error, Equatable {
    case invalidSize, invalidMagic, unsupportedVersion, unsupportedKind
    case invalidReservedFields, lengthMismatch, carrierTooLarge
}

/// The shared D2RL v1 envelope, after transport processing. Header fields are
/// preserved, not interpreted as an accepted channel, session or admission.
public struct LoaderFrame: Equatable {
    public static let headerSize = 18
    public static let maximumCarrierBytes = 65_538
    public let kind: UInt8
    public let channel: UInt16
    public let message: UInt16
    public let sequence: UInt32
    public let payload: Data

    public init(kind: UInt8, channel: UInt16 = 0, message: UInt16 = 0,
                sequence: UInt32 = 0, payload: Data) throws {
        guard (1...11).contains(kind) else { throw LoaderFrameError.unsupportedKind }
        // The inspected leaf decoder allows >224 bytes only for kinds 1..3.
        guard payload.count <= (kind < 4 ? 65_535 : 224) else { throw LoaderFrameError.invalidSize }
        self.kind = kind; self.channel = channel; self.message = message
        self.sequence = sequence; self.payload = payload
    }

    public func encoded() -> Data {
        var bytes = Data([0x44, 0x32, 0x52, 0x4c, 1, kind, 0, 0])
        for (value, count) in [(UInt64(channel), 2), (UInt64(message), 2),
                               (UInt64(sequence), 4), (UInt64(payload.count), 2)] {
            for shift in 0..<count { bytes.append(UInt8(truncatingIfNeeded: value >> (8 * shift))) }
        }
        bytes.append(payload)
        return bytes
    }

    public func gameCarrier() throws -> Data {
        let body = encoded()
        // The carrier counts the WHOLE envelope in u16, not just its payload.
        guard body.count <= 65_535 else { throw LoaderFrameError.carrierTooLarge }
        return Data([0xd0, UInt8(truncatingIfNeeded: body.count),
                     UInt8(truncatingIfNeeded: body.count >> 8)]) + body
    }

    public static func decode(_ data: Data) throws -> LoaderFrame {
        guard (headerSize...(headerSize + 65_535)).contains(data.count) else { throw LoaderFrameError.invalidSize }
        let b = Array(data)
        guard Array(b[0..<4]) == [0x44, 0x32, 0x52, 0x4c] else { throw LoaderFrameError.invalidMagic }
        guard b[4] == 1 else { throw LoaderFrameError.unsupportedVersion }
        guard b[6] == 0 && b[7] == 0 else { throw LoaderFrameError.invalidReservedFields }
        func word(_ i: Int) -> UInt16 { UInt16(b[i]) | (UInt16(b[i + 1]) << 8) }
        guard Int(word(16)) == b.count - headerSize else { throw LoaderFrameError.lengthMismatch }
        let sequence = UInt32(word(12)) | (UInt32(word(14)) << 16)
        return try LoaderFrame(kind: b[5], channel: word(8), message: word(10),
                               sequence: sequence, payload: Data(b[headerSize...]))
    }

    public static func decodeGameCarrier(_ data: Data) throws -> LoaderFrame {
        guard data.count >= 3 else { throw LoaderFrameError.invalidSize }
        let bytes = Data(data) // normalize sliced Data indices
        guard try carrierLength(prefix: bytes) == bytes.count else { throw LoaderFrameError.lengthMismatch }
        return try decode(Data(bytes.dropFirst(3)))
    }

    /// Validate available fixed header fields before buffering a claimed large
    /// message. The supplied prefix need not contain the complete envelope.
    static func carrierLength(prefix: Data) throws -> Int {
        let b = Array(prefix)
        guard b.count >= 3 else { throw LoaderFrameError.invalidSize }
        guard b[0] == 0xd0 else { throw LoaderFrameError.invalidMagic }
        let body = Int(b[1]) | (Int(b[2]) << 8)
        guard body >= headerSize else { throw LoaderFrameError.invalidSize }
        if b.count >= 8 {
            guard Array(b[3..<7]) == [0x44, 0x32, 0x52, 0x4c] else { throw LoaderFrameError.invalidMagic }
            guard b[7] == 1 else { throw LoaderFrameError.unsupportedVersion }
        }
        if b.count >= 9 {
            guard (1...11).contains(b[8]) else { throw LoaderFrameError.unsupportedKind }
            guard b[8] < 4 || body <= headerSize + 224 else { throw LoaderFrameError.invalidSize }
        }
        if b.count >= 11 {
            guard b[9] == 0 && b[10] == 0 else { throw LoaderFrameError.invalidReservedFields }
        }
        if b.count >= 21 {
            guard Int(b[19]) | (Int(b[20]) << 8) == body - headerSize else { throw LoaderFrameError.lengthMismatch }
        }
        return body + 3
    }
}
