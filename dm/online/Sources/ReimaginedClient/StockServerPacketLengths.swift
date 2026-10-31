import Foundation

/// Server-to-client game-packet metadata for the supported 3.3.94012 engine.
/// These are packet lengths after transport decoding, not TCP record lengths.
/// Eight variable formats are checked against native header readers and bounded
/// original-engine captures. Other variables and the system channel are separate.
public enum StockServerPacketLengths {
    public enum Descriptor: Equatable {
        case fixed(Int), variable, unsupported
    }

    // Protocol lengths only; no function pointers, executable code or assets.
    // tools/verify_stock_lengths.py compares every entry with the exact original
    // ARM64 module and, optionally, an independently pinned Windows reference.
    private static let sizes: [Int] = [
        1, 8, 1, 12, 1, 1, 1, 6, 6, 11, 6, 6, 9, 13, 12, 16, // 00
        16, 8, 0, 0, 0, 11, -1, -1, 19, 2, 2, 3, 5, 6, 7, 9, // 10
        13, 12, 12, 13, 13, 511, -1, 40, 103, 97, 15, -1, 8, 5, -1, 0, // 20
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, -1, 3, // 30
        13, 0, 6, 0, 0, 0, 0, 11, 11, 0, 2, 0, 20, 21, 7, 1, // 40
        15, 14, 42, 10, 3, 18, 512, 31, 7, 71, 34, -1, 5, 6, 38, 5, // 50
        12, 2, 7, 17, 4, 7, 7, -1, -1, 12, 12, 16, 16, 10, 1, 1, // 60
        -1, -1, -1, -1, 10, 13, 6, 2, -1, 5, 13, 8, 6, 18, 5, 10, // 70
        19, 24, 80, 24, 129, 10, 5, -1, 0, 2, 6, 6, 11, 7, 10, 33, // 80
        13, 26, 6, 8, -1, 17, 9, 1, 7, 20, 21, 7, -1, -1, 8, 9, // 90
        11, 8, 9, 24, 3, 12, -1, 8, -1, 8, -1, 7, -1, 12, -1, // A0
    ]

    public static let supportedVariableOpcodes: [UInt8] = [0x5b, 0x67, 0x94, 0x9c, 0x9d, 0xa8, 0xaa, 0xac]

    public static func descriptor(for opcode: UInt8) -> Descriptor {
        guard Int(opcode) < sizes.count else { return .unsupported }
        let length = sizes[Int(opcode)]
        if length > 0 { return .fixed(length) }
        return length == -1 ? .variable : .unsupported
    }

    /// Does not consume a prefix or infer packet lengths from TCP read boundaries.
    /// D2RL carriers are handled separately by GamePacketStream before this call.
    public static func resolve(_ prefix: Data) -> GamePacketLength {
        guard let opcode = prefix.first else { return .needMore }
        if case .fixed(let length) = descriptor(for: opcode) { return .length(length) }
        func byte(_ index: Int) -> Int { Int(prefix[prefix.startIndex + index]) }
        func byteLength(_ offset: Int, minimum: Int, maximum: Int = 255) -> GamePacketLength {
            guard prefix.count > offset else { return .needMore }
            let length = byte(offset)
            return (minimum...maximum).contains(length) ? .length(length) : .invalid
        }
        switch opcode {
        case 0x5b:
            guard prefix.count >= 3 else { return .needMore }
            let length = byte(1) | (byte(2) << 8)
            // Native reader reaches fixed byte94, then a terminated string at95.
            return length >= 96 ? .length(length) : .invalid
        case 0x67:
            guard prefix.count >= 21 else { return .needMore }
            return .length(22 + 4 * byte(20))
        case 0x94:
            guard prefix.count >= 2 else { return .needMore }
            return .length(6 + 3 * byte(1))
        case 0x9c: return byteLength(2, minimum: 8, maximum: 252)
        case 0x9d: return byteLength(2, minimum: 13)
        case 0xa8:
            // D2R's native state-add layout differs from the legacy byte6 rule.
            return byteLength(2, minimum: 9)
        case 0xaa: return byteLength(6, minimum: 9)
        case 0xac: return byteLength(12, minimum: 13)
        default: return .unsupported
        }
    }
}
