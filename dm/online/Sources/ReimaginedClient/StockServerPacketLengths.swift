import Foundation

/// Server-to-client game-packet metadata for the supported 3.3.94012 engine.
/// These are packet lengths after transport decoding, not TCP record lengths.
/// Variable packets and the separate system channel still require verified rules.
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

    public static func descriptor(for opcode: UInt8) -> Descriptor {
        guard Int(opcode) < sizes.count else { return .unsupported }
        let length = sizes[Int(opcode)]
        if length > 0 { return .fixed(length) }
        return length == -1 ? .variable : .unsupported
    }

    /// Does not consume a prefix or infer variable packet lengths from TCP reads.
    /// D2RL carriers are handled separately by GamePacketStream before this call.
    public static func resolve(_ prefix: Data) -> GamePacketLength {
        guard let opcode = prefix.first else { return .needMore }
        if case .fixed(let length) = descriptor(for: opcode) { return .length(length) }
        return .unsupported
    }
}
