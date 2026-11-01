import Foundation

public enum CharacterStatUsageError: Error, Equatable {
    case bitmapSize, statID, edition, rowSize, tableSize, statName, missingRow(UInt16), missingName(UInt16)
}

/// The two version7 metadata bitmaps: item stats first, player stats second.
/// Each little-endian bit identifies one stat ID0..32767. Repeated capture of
/// the same ID is a set operation; zero tails have the sender's canonical form.
public struct CharacterStatUsage: Equatable {
    public let itemBitmap: Data
    public let playerBitmap: Data

    public init(itemBitmap: Data, playerBitmap: Data) throws {
        guard itemBitmap.count <= 4096, playerBitmap.count <= 4096 else { throw CharacterStatUsageError.bitmapSize }
        func trimmed(_ data: Data) -> Data {
            let bytes = Array(data)
            return bytes.lastIndex(where: { $0 != 0 }).map { Data(bytes[...$0]) } ?? Data()
        }
        self.itemBitmap = trimmed(itemBitmap); self.playerBitmap = trimmed(playerBitmap)
    }

    public init(itemIDs: [UInt16], playerIDs: [UInt16]) throws {
        func bitmap(_ ids: [UInt16]) throws -> Data {
            guard ids.allSatisfy({ $0 <= 32767 }) else { throw CharacterStatUsageError.statID }
            var bytes = [UInt8](repeating: 0, count: ids.max().map { Int($0) / 8 + 1 } ?? 0)
            for id in ids { bytes[Int(id) / 8] |= 1 << (Int(id) & 7) }
            return Data(bytes)
        }
        try self.init(itemBitmap: bitmap(itemIDs), playerBitmap: bitmap(playerIDs))
    }

    public var itemIDs: [UInt16] { Self.ids(itemBitmap) }
    public var playerIDs: [UInt16] { Self.ids(playerBitmap) }
    public var allIDs: [UInt16] { Array(Set(itemIDs).union(playerIDs)).sorted() }

    /// These are the sidecar Stat.flags bits, not the source table flags.
    public func sidecarFlags(for id: UInt16) throws -> UInt8 {
        guard id <= 32767 else { throw CharacterStatUsageError.statID }
        func contains(_ data: Data) -> Bool {
            let index = Int(id) / 8
            return index < data.count && data[data.startIndex + index] & (1 << (Int(id) & 7)) != 0
        }
        return (contains(itemBitmap) ? 2 : 0) | (contains(playerBitmap) ? 1 : 0)
    }

    private static func ids(_ data: Data) -> [UInt16] {
        var result: [UInt16] = []
        for (index, byte) in data.enumerated() where byte != 0 {
            for bit in 0..<8 where byte & (1 << bit) != 0 { result.append(UInt16(index * 8 + bit)) }
        }
        return result
    }
}

extension CharacterSaveMetadata {
    public func statUsage() throws -> CharacterStatUsage {
        try CharacterStatUsage(itemBitmap: blob71, playerBitmap: blob1071)
    }
}

/// Immutable copied ItemStatCost rows from the selected edition's loaded game
/// table, plus already-resolved names for that edition. The324-byte row layout
/// and these columns were independently checked against the exact ARM64 engine
/// and the original Windows descriptor builder. This does not locate/copy a live
/// table, resolve name fallbacks or prove the active mod/table fingerprint.
public struct ItemStatCostSnapshot {
    public static let rowBytes = 324, maximumRows = 32768
    public let edition: UInt8
    public let rowCount: Int
    private let bytes: [UInt8]
    private let names: [UInt16: String]

    public init(edition: UInt8, rows: Data, resolvedNames: [UInt16: String]) throws {
        guard (1...3).contains(edition) else { throw CharacterStatUsageError.edition }
        guard rows.count.isMultiple(of: Self.rowBytes) else { throw CharacterStatUsageError.rowSize }
        let count = rows.count / Self.rowBytes
        guard count <= Self.maximumRows else { throw CharacterStatUsageError.tableSize }
        for (id, name) in resolvedNames {
            guard Int(id) < count else { throw CharacterStatUsageError.missingRow(id) }
            guard !name.isEmpty, name.utf8.count <= 1024, !name.utf8.contains(0) else { throw CharacterStatUsageError.statName }
        }
        self.edition = edition; rowCount = count; bytes = Array(rows); names = resolvedNames
    }

    public func descriptors(for metadata: CharacterSaveMetadata) throws -> [CharacterSidecar.Stat] {
        guard metadata.gameEdition == edition else { throw CharacterStatUsageError.edition }
        return try descriptors(for: metadata.statUsage())
    }

    public func descriptors(for usage: CharacterStatUsage) throws -> [CharacterSidecar.Stat] {
        try usage.allIDs.map { id in
            guard Int(id) < rowCount else { throw CharacterStatUsageError.missingRow(id) }
            guard let name = names[id] else { throw CharacterStatUsageError.missingName(id) }
            let base = Int(id) * Self.rowBytes, flags = try usage.sidecarFlags(for: id)
            func word(_ offset: Int) -> UInt32 {
                (0..<4).reduce(0) { $0 | UInt32(bytes[base + offset + $1]) << (8 * $1) }
            }
            let item = flags & 2 != 0, player = flags & 1 != 0
            return CharacterSidecar.Stat(id: UInt32(id), flags: flags,
                flag: player && word(4) & 0x1000 != 0,
                byte34: item ? bytes[base + 0x15] : 0, byte35: item ? bytes[base + 0x14] : 0,
                word30: item ? word(0x20) : 0, word2c: item ? word(0x18) : 0,
                byte38: player ? bytes[base + 0x0a] : 0, byte39: player ? bytes[base + 0x0b] : 0,
                name: Data(name.utf8))
        }
    }

    /// Policy2's full-table environment value. This covers every row in ID
    /// order, not just stats used by one save. Names must be the actual loaded
    /// edition's resolved names; a partial capture never claims a known schema.
    public func environmentSchema() throws -> EnvironmentItemStatSchema {
        var hash: UInt64 = 0xcbf29ce484222325
        func byte(_ value: UInt8) { hash = (hash ^ UInt64(value)) &* 0x100000001b3 }
        func word(_ value: UInt32) { for shift in stride(from: 0, to: 32, by: 8) { byte(UInt8(truncatingIfNeeded: value >> shift)) } }
        word(UInt32(rowCount))
        for index in 0..<rowCount {
            let id = UInt16(index)
            guard let name = names[id] else { throw CharacterStatUsageError.missingName(id) }
            word(UInt32(index)); word(UInt32(name.utf8.count))
            for value in name.utf8 { byte(value) }
            let base = index * Self.rowBytes
            for offset in 0x18..<0x1c { byte(bytes[base + offset]) }
            for offset in 0x20..<0x24 { byte(bytes[base + offset]) }
            byte(bytes[base + 0x15]); byte(bytes[base + 0x14])
            byte(bytes[base + 0x0a]); byte(bytes[base + 0x0b])
            byte((bytes[base + 5] >> 4) & 1) // csvsigned at row word4, bit12.
            byte(1) // This descriptor has an actual loaded row.
        }
        return try EnvironmentItemStatSchema(tag: edition, policyVersion: 2, coverage: .complete, value: hash)
    }
}
