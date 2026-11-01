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
        // These peer readers are also extended; their native adapters are not
        // implemented yet. Never split them using the shorter stock sizes.
        case 0x18, 0x95: return .unsupported
        default: return StockServerPacketLengths.resolve(prefix)
        }
    }
}
