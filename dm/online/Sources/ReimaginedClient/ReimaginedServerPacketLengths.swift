import Foundation

/// Explicit extended peer profile, separate from the exact stock engine table.
/// Matching packet lengths does not establish environment admission. A matching
/// native receiver is required before delivering these packets to the engine.
public enum ReimaginedServerPacketLengths {
    public static func resolve(_ prefix: Data) -> GamePacketLength {
        guard let opcode = prefix.first else { return .needMore }
        switch opcode {
        // Original peer reader: 32 + 16 + 16 + 8 + 8 payload bits.
        case 0x96: return .length(11)
        // 3 resources32, coordinates16 each, deltas8 each, frame32.
        case 0x95: return .length(23)
        // Big adds two7-bit stats before coordinates (198 bits including ID).
        case 0x18: return .length(25)
        default: return StockServerPacketLengths.resolve(prefix)
        }
    }
}
