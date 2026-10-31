import Foundation

enum NativeItemStatCostError: Error {
    case nativeStatus(Int32), invalidSnapshot, invalidName(UInt16)
}

/// A generation-bound copy for a future D2S-completion transaction. This reads
/// the engine capture only; it does not enable sidecar capability or upload.
struct NativeItemStatCostCapture {
    let generation: UInt64
    let snapshot: ItemStatCostSnapshot

    static func load(edition: UInt8, usage: CharacterStatUsage) throws -> Self {
        func requireReady(_ status: Int32) throws {
            guard status == DM_NET_TABLE_READY else { throw NativeItemStatCostError.nativeStatus(status) }
        }
        var info = dm_net_itemstatcost_info()
        try requireReady(dm_net_itemstatcost_copy(UInt32(edition), 0, nil, 0, &info))
        guard info.generation != 0, info.edition == UInt32(edition),
              info.row_bytes == ItemStatCostSnapshot.rowBytes,
              info.row_count > 0, info.row_count <= ItemStatCostSnapshot.maximumRows else {
            throw NativeItemStatCostError.invalidSnapshot
        }
        let generation = info.generation
        var rows = Data(count: Int(info.row_count) * ItemStatCostSnapshot.rowBytes)
        try rows.withUnsafeMutableBytes { bytes in
            try requireReady(dm_net_itemstatcost_copy(UInt32(edition), generation, bytes.baseAddress, bytes.count, &info))
        }
        var names: [UInt16: String] = [:]
        for id in usage.allIDs {
            var required = 0
            try requireReady(dm_net_itemstatcost_name(UInt32(edition), generation, UInt32(id), nil, 0, &required))
            guard (2...1025).contains(required) else { throw NativeItemStatCostError.invalidName(id) }
            var buffer = [CChar](repeating: 0, count: required)
            try requireReady(dm_net_itemstatcost_name(UInt32(edition), generation, UInt32(id), &buffer, buffer.count, &required))
            let bytes = buffer.map { UInt8(bitPattern: $0) }
            guard bytes.last == 0, !bytes.dropLast().contains(0),
                  let name = String(data: Data(bytes.dropLast()), encoding: .utf8) else {
                throw NativeItemStatCostError.invalidName(id)
            }
            names[id] = name
        }
        let result = try Self(generation: generation,
                              snapshot: ItemStatCostSnapshot(edition: edition, rows: rows, resolvedNames: names))
        try result.validateCurrent()
        return result
    }

    static func load(for metadata: CharacterSaveMetadata) throws -> Self {
        try load(edition: metadata.gameEdition, usage: metadata.statUsage())
    }

    /// Call again at transaction commit; a captured old edition cannot silently
    /// become the schema for a freshly loaded mod. Own copied bytes remain safe.
    func validateCurrent() throws {
        var info = dm_net_itemstatcost_info()
        let status = dm_net_itemstatcost_copy(UInt32(snapshot.edition), generation, nil, 0, &info)
        guard status == DM_NET_TABLE_READY else { throw NativeItemStatCostError.nativeStatus(status) }
    }
}
