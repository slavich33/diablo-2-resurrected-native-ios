import Foundation

public enum NativeSystemPacketError: Error, Equatable {
    case unsupportedOpcode(UInt8), invalidLength
}

/// Logical system-channel packets consumed by the exact ARM64 3.3.94012
/// engine. This is not TCP framing, compression negotiation or admission.
/// The marker/auxiliary bytes are preserved, not assigned wider semantics.
public enum NativeSystemPacket: Equatable {
    case ready(auxiliary: UInt8)
    case disconnected
    case characterChunk(marker: UInt8, payload: Data)
    case failure(reason: UInt32)

    public static func resolve(_ prefix: Data) -> GamePacketLength {
        guard let opcode = prefix.first else { return .needMore }
        switch opcode {
        case 0xaf: return .length(2)
        case 0xb0: return .length(1)
        case 0xb3:
            guard prefix.count >= 2 else { return .needMore }
            return .length(3 + Int(prefix[prefix.startIndex + 1]))
        case 0xb4: return .length(5)
        default: return .unsupported
        }
    }

    public static func decode(_ bytes: Data) throws -> NativeSystemPacket {
        guard let opcode = bytes.first else { throw NativeSystemPacketError.invalidLength }
        switch resolve(bytes) {
        case .length(let length):
            guard bytes.count == length else { throw NativeSystemPacketError.invalidLength }
        case .unsupported: throw NativeSystemPacketError.unsupportedOpcode(opcode)
        default: throw NativeSystemPacketError.invalidLength
        }
        let data = Array(bytes)
        switch opcode {
        case 0xaf: return .ready(auxiliary: data[1])
        case 0xb0: return .disconnected
        case 0xb3: return .characterChunk(marker: data[2], payload: Data(data.dropFirst(3)))
        case 0xb4:
            let reason = UInt32(data[1]) | (UInt32(data[2]) << 8) |
                (UInt32(data[3]) << 16) | (UInt32(data[4]) << 24)
            return .failure(reason: reason)
        default: throw NativeSystemPacketError.unsupportedOpcode(opcode)
        }
    }

    public func encoded() throws -> Data {
        switch self {
        case .ready(let auxiliary): return Data([0xaf, auxiliary])
        case .disconnected: return Data([0xb0])
        case .characterChunk(let marker, let payload):
            guard payload.count <= 255 else { throw NativeSystemPacketError.invalidLength }
            return Data([0xb3, UInt8(payload.count), marker]) + payload
        case .failure(let reason):
            return Data([0xb4, UInt8(truncatingIfNeeded: reason), UInt8(truncatingIfNeeded: reason >> 8),
                         UInt8(truncatingIfNeeded: reason >> 16), UInt8(truncatingIfNeeded: reason >> 24)])
        }
    }
}
