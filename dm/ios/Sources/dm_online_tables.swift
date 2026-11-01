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
        try load(edition: edition, requiredIDs: usage.allIDs)
    }

    /// Full environment capture, independent of a selected save's usage bits.
    static func loadEnvironment(edition: UInt8) throws -> Self {
        try load(edition: edition, requiredIDs: nil)
    }

    private static func load(edition: UInt8, requiredIDs: [UInt16]?) throws -> Self {
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
        for id in requiredIDs ?? (0..<info.row_count).map({ UInt16($0) }) {
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

    /// Copy first, then pin that exact published capture across the native
    /// filesystem prepare/finished pair. No copy/query while the pin is held.
    static func acquireLease(for metadata: CharacterSaveMetadata, expectedGeneration: UInt64) throws -> SaveTableLease {
        let capture = try load(for: metadata)
        guard expectedGeneration != 0, capture.generation == expectedGeneration else { throw NativeSaveCommitError.generation }
        let status = dm_net_itemstatcost_pin(UInt32(capture.snapshot.edition), capture.generation)
        if status == DM_NET_TABLE_STALE { throw NativeSaveCommitError.generation }
        guard status == DM_NET_TABLE_READY else { throw NativeItemStatCostError.nativeStatus(status) }
        return SaveTableLease(snapshot: capture.snapshot) { _ = dm_net_itemstatcost_unpin() }
    }

    /// Call again at transaction commit; a captured old edition cannot silently
    /// become the schema for a freshly loaded mod. Own copied bytes remain safe.
    func validateCurrent() throws {
        var info = dm_net_itemstatcost_info()
        let status = dm_net_itemstatcost_copy(UInt32(snapshot.edition), generation, nil, 0, &info)
        guard status == DM_NET_TABLE_READY else { throw NativeItemStatCostError.nativeStatus(status) }
    }
}

/// Truthful partial native environment from captured tables. Resource-bank and
/// aggregate fingerprints remain unavailable. Diagnostic capture keeps support0;
/// prepared peer capture declares the linked v2 codec, independently of admission.
/// The caller must keep the engine quiescent while acquiring/using this profile
/// and revalidate before admission; this object does not freeze engine execution.
struct NativeEnvironmentTableProfile {
    let description: EnvironmentDescription
    let generations: [UInt8: UInt64]
    private let sources: [(edition: UInt8, generation: UInt64, status: Int32, rows: UInt32, names: UInt32)]

    static func capture() throws -> Self {
        try capture(base: EnvironmentDescription.unavailableProfile())
    }

    /// The real peer startup must first isolate its downloaded namespace. This
    /// declares the linked v2 codec, not a successful handshake or ready world.
    static func capturePreparedPeerProfile() throws -> Self {
        guard nativeSaveIsolated() == 1 else { throw NativeSaveCommitError.invalidScope }
        return try capture(base: EnvironmentDescription.nativeSidecarCodecProfile())
    }

    private static func capture(base: EnvironmentDescription) throws -> Self {
        var fields: [EnvironmentItemStatSchema] = [], generations: [UInt8: UInt64] = [:]
        var sources: [(edition: UInt8, generation: UInt64, status: Int32, rows: UInt32, names: UInt32)] = []
        for edition in UInt8(1)...3 {
            var info = dm_net_itemstatcost_info()
            let status = dm_net_itemstatcost_copy(UInt32(edition), 0, nil, 0, &info)
            guard status == DM_NET_TABLE_READY || status == DM_NET_TABLE_UNAVAILABLE || status == DM_NET_TABLE_CAPTURE_FAILED else {
                throw NativeItemStatCostError.nativeStatus(status)
            }
            sources.append((edition, info.generation, status, info.row_count, info.resolved_names))
            if status == DM_NET_TABLE_READY && info.row_count > 0 && info.resolved_names == info.row_count {
                let capture = try NativeItemStatCostCapture.loadEnvironment(edition: edition)
                guard capture.generation == info.generation else { throw NativeItemStatCostError.nativeStatus(Int32(DM_NET_TABLE_STALE)) }
                fields.append(try capture.snapshot.environmentSchema()); generations[edition] = capture.generation
            } else {
                fields.append(try EnvironmentItemStatSchema(tag: edition, policyVersion: 2, coverage: .unavailable, value: nil))
            }
        }
        let description = try EnvironmentDescription(contract: base.contract, aggregate: base.aggregate,
            groups: base.groups, banks: base.banks, itemStatSchemas: fields, namedFingerprints: [], optionalFields: [])
        let result = Self(description: description, generations: generations, sources: sources)
        try result.validateCurrent()
        return result
    }

    func validateCurrent() throws {
        for source in sources {
            var info = dm_net_itemstatcost_info()
            let status = dm_net_itemstatcost_copy(UInt32(source.edition), 0, nil, 0, &info)
            guard status == source.status, info.generation == source.generation,
                  info.row_count == source.rows, info.resolved_names == source.names else {
                throw NativeItemStatCostError.nativeStatus(Int32(DM_NET_TABLE_STALE))
            }
        }
    }
}
