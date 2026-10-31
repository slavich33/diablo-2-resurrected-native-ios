import Foundation

public enum EnvironmentDescriptionError: Error, Equatable {
    case missingField(UInt16), invalidField(UInt16), invalidContract, invalidRollup
    case inconsistentAggregate, noncanonicalTags, invalidBank, invalidSchema, invalidNamedFingerprint
}

public enum FingerprintCoverage: UInt8 { case complete = 1, partial = 2, unavailable = 3 }

/// Required field1. The two contract words retain their wire offsets: their
/// wider feature semantics are not inferred from nonzero-value validation.
public struct EnvironmentContract: Equatable {
    public let version: UInt16
    public let sidecarCapability: UInt32
    public let sidecarFormat: UInt16
    public let word8: UInt16
    public let word10: UInt32

    public init(version: UInt16, sidecarCapability: UInt32, sidecarFormat: UInt16,
                word8: UInt16, word10: UInt32) throws {
        guard version > 0, word8 > 0, word10 > 0, sidecarCapability <= 1,
              (sidecarCapability == 0) == (sidecarFormat == 0) else {
            throw EnvironmentDescriptionError.invalidContract
        }
        self.version = version; self.sidecarCapability = sidecarCapability
        self.sidecarFormat = sidecarFormat; self.word8 = word8; self.word10 = word10
    }
}

public struct FingerprintRollup: Equatable {
    public let policyVersion: UInt16
    public let coverage: FingerprintCoverage
    public let componentCount: UInt32
    public let digest: Data?

    public init(policyVersion: UInt16, coverage: FingerprintCoverage, componentCount: UInt32, digest: Data?) throws {
        guard policyVersion > 0, digest == nil || digest?.count == 32 else { throw EnvironmentDescriptionError.invalidRollup }
        switch coverage {
        case .unavailable:
            guard componentCount == 0, digest == nil else { throw EnvironmentDescriptionError.invalidRollup }
        case .partial:
            guard componentCount > 0, digest != nil else { throw EnvironmentDescriptionError.invalidRollup }
        case .complete:
            guard (componentCount > 0) == (digest != nil) else { throw EnvironmentDescriptionError.invalidRollup }
        }
        self.policyVersion = policyVersion; self.coverage = coverage; self.componentCount = componentCount; self.digest = digest
    }
}

public struct EnvironmentFingerprintGroup: Equatable {
    public let tag: UInt8
    public let rollup: FingerprintRollup
    public init(tag: UInt8, rollup: FingerprintRollup) { self.tag = tag; self.rollup = rollup }
}

public struct EnvironmentBank: Equatable {
    public let tag: UInt8
    public let policyVersion: UInt16
    public let coverage: FingerprintCoverage
    public let digest: Data?
    public init(tag: UInt8, policyVersion: UInt16, coverage: FingerprintCoverage, digest: Data?) throws {
        guard policyVersion > 0, digest == nil || digest?.count == 32,
              (coverage == .unavailable) == (digest == nil) else { throw EnvironmentDescriptionError.invalidBank }
        self.tag = tag; self.policyVersion = policyVersion; self.coverage = coverage; self.digest = digest
    }
}

public struct EnvironmentItemStatSchema: Equatable {
    public let tag: UInt8
    public let policyVersion: UInt16
    public let coverage: FingerprintCoverage
    public let value: UInt64?
    public init(tag: UInt8, policyVersion: UInt16, coverage: FingerprintCoverage, value: UInt64?) throws {
        guard policyVersion > 0, (coverage == .unavailable) == (value == nil) else { throw EnvironmentDescriptionError.invalidSchema }
        self.tag = tag; self.policyVersion = policyVersion; self.coverage = coverage; self.value = value
    }
}

/// Field6's bounded wire record. Tag/flags/name remain opaque until their
/// metadata semantics and canonical order are independently verified.
public struct EnvironmentNamedFingerprint: Equatable {
    public let tag: UInt8
    public let flags: UInt8
    public let name: Data
    public let digest: Data
    public init(tag: UInt8, flags: UInt8, name: Data, digest: Data) throws {
        guard name.count <= 1024, digest.count == 32 else { throw EnvironmentDescriptionError.invalidNamedFingerprint }
        self.tag = tag; self.flags = flags; self.name = name; self.digest = digest
    }
}

/// Typed required D2EM-v3 fields and known local consistency checks. Neither
/// decoding a host profile nor constructing one grants compatibility/admission.
/// Named-record/optional-field semantics and actual native fingerprints are
/// deliberately separate from these bounds and rollup checks.
public struct EnvironmentDescription {
    public let contract: EnvironmentContract
    public let aggregate: FingerprintRollup
    public let groups: [EnvironmentFingerprintGroup]
    public let banks: [EnvironmentBank]
    public let itemStatSchemas: [EnvironmentItemStatSchema]
    public let namedFingerprints: [EnvironmentNamedFingerprint]
    public let optionalFields: [EnvironmentField]

    public init(contract: EnvironmentContract, aggregate: FingerprintRollup,
                groups: [EnvironmentFingerprintGroup], banks: [EnvironmentBank],
                itemStatSchemas: [EnvironmentItemStatSchema], namedFingerprints: [EnvironmentNamedFingerprint],
                optionalFields: [EnvironmentField] = []) throws {
        guard groups.map(\.tag) == Array(UInt8(1)...7), banks.map(\.tag) == Array(UInt8(1)...3),
              itemStatSchemas.map(\.tag) == Array(UInt8(1)...3) else { throw EnvironmentDescriptionError.noncanonicalTags }
        let total = groups.reduce(UInt64(0)) { $0 + UInt64($1.rollup.componentCount) }
        let coverage: FingerprintCoverage = groups.allSatisfy { $0.rollup.coverage == .complete } ? .complete : (total == 0 ? .unavailable : .partial)
        guard total <= UInt32.max, aggregate.componentCount == UInt32(total), aggregate.coverage == coverage,
              aggregate.coverage != .complete || aggregate.componentCount > 0 else {
            throw EnvironmentDescriptionError.inconsistentAggregate
        }
        guard namedFingerprints.count <= 256 else { throw EnvironmentDescriptionError.invalidNamedFingerprint }
        guard optionalFields.allSatisfy({ !$0.required && !(1...6).contains($0.id) }) else {
            throw EnvironmentDescriptionError.invalidField(0)
        }
        self.contract = contract; self.aggregate = aggregate; self.groups = groups; self.banks = banks
        self.itemStatSchemas = itemStatSchemas; self.namedFingerprints = namedFingerprints; self.optionalFields = optionalFields
        _ = try envelope() // Also enforce duplicate IDs, total size and outer flag rules.
    }

    /// A truthful baseline: no known fingerprints, banks, schemas or plugins,
    /// and no sidecar support. Constants match the original decoder defaults;
    /// this profile must not be relabeled as a compatible gameplay environment.
    public static func unavailableProfile() throws -> EnvironmentDescription {
        let rollup = try FingerprintRollup(policyVersion: 4, coverage: .unavailable, componentCount: 0, digest: nil)
        return try EnvironmentDescription(
            contract: EnvironmentContract(version: 2, sidecarCapability: 0, sidecarFormat: 0, word8: 4, word10: 7),
            aggregate: rollup, groups: (UInt8(1)...7).map { EnvironmentFingerprintGroup(tag: $0, rollup: rollup) },
            banks: try (UInt8(1)...3).map { try EnvironmentBank(tag: $0, policyVersion: 4, coverage: .unavailable, digest: nil) },
            itemStatSchemas: try (UInt8(1)...3).map { try EnvironmentItemStatSchema(tag: $0, policyVersion: 2, coverage: .unavailable, value: nil) },
            namedFingerprints: [])
    }

    public func envelope() throws -> EnvironmentEnvelope {
        var header = Writer(); header.u16(contract.version); header.u32(contract.sidecarCapability)
        header.u16(contract.sidecarFormat); header.u16(contract.word8); header.u32(contract.word10)
        var total = Writer(); total.rollup(aggregate)
        var groupBytes = Writer(); groupBytes.u8(7)
        for group in groups { groupBytes.u8(group.tag); groupBytes.rollup(group.rollup) }
        var bankBytes = Writer(); bankBytes.u8(3)
        for bank in banks {
            bankBytes.u8(bank.tag); bankBytes.u16(bank.policyVersion); bankBytes.u8(bank.coverage.rawValue); bankBytes.digest(bank.digest)
        }
        var schemas = Writer(); schemas.u8(3)
        for schema in itemStatSchemas {
            schemas.u8(schema.tag); schemas.u16(schema.policyVersion); schemas.u8(schema.coverage.rawValue)
            schemas.u8(schema.value == nil ? 0 : 8); if let value = schema.value { schemas.u64(value) }
        }
        var names = Writer(); names.u16(UInt16(namedFingerprints.count))
        for entry in namedFingerprints {
            names.u8(entry.tag); names.u8(entry.flags); names.u16(UInt16(entry.name.count)); names.data.append(entry.name); names.data.append(entry.digest)
        }
        let required = [header.data, total.data, groupBytes.data, bankBytes.data, schemas.data, names.data].enumerated().map {
            EnvironmentField(id: UInt16($0.offset + 1), required: true, payload: $0.element)
        }
        return try EnvironmentEnvelope(fields: required + optionalFields)
    }

    public static func decode(_ envelope: EnvironmentEnvelope) throws -> EnvironmentDescription {
        func field(_ id: UInt16) throws -> Reader {
            guard let value = envelope.fields.first(where: { $0.id == id && $0.required }) else { throw EnvironmentDescriptionError.missingField(id) }
            return Reader(value.payload, field: id)
        }
        var h = try field(1)
        let contract = try EnvironmentContract(version: h.u16(), sidecarCapability: h.u32(), sidecarFormat: h.u16(), word8: h.u16(), word10: h.u32()); try h.end()
        var a = try field(2); let aggregate = try a.rollup(); try a.end()
        var g = try field(3); guard try g.u8() == 7 else { throw EnvironmentDescriptionError.invalidField(3) }
        var groups: [EnvironmentFingerprintGroup] = []
        for _ in 0..<7 { groups.append(try EnvironmentFingerprintGroup(tag: g.u8(), rollup: g.rollup())) }; try g.end()
        var b = try field(4); guard try b.u8() == 3 else { throw EnvironmentDescriptionError.invalidField(4) }
        var banks: [EnvironmentBank] = []
        for _ in 0..<3 { banks.append(try EnvironmentBank(tag: b.u8(), policyVersion: b.u16(), coverage: b.coverage(), digest: b.digest())) }; try b.end()
        var s = try field(5); guard try s.u8() == 3 else { throw EnvironmentDescriptionError.invalidField(5) }
        var schemas: [EnvironmentItemStatSchema] = []
        for _ in 0..<3 {
            let tag = try s.u8(), policy = try s.u16(), coverage = try s.coverage(), length = try s.u8()
            guard length == 0 || length == 8 else { throw EnvironmentDescriptionError.invalidField(5) }
            schemas.append(try EnvironmentItemStatSchema(tag: tag, policyVersion: policy, coverage: coverage, value: length == 0 ? nil : s.u64()))
        }; try s.end()
        var n = try field(6); let count = Int(try n.u16()); guard count <= 256 else { throw EnvironmentDescriptionError.invalidField(6) }
        var names: [EnvironmentNamedFingerprint] = []
        for _ in 0..<count {
            let tag = try n.u8(), flags = try n.u8(), length = Int(try n.u16())
            guard length <= 1024 else { throw EnvironmentDescriptionError.invalidField(6) }
            names.append(try EnvironmentNamedFingerprint(tag: tag, flags: flags, name: n.take(length), digest: n.take(32)))
        }; try n.end()
        return try EnvironmentDescription(contract: contract, aggregate: aggregate, groups: groups, banks: banks,
            itemStatSchemas: schemas, namedFingerprints: names, optionalFields: envelope.fields.filter { !(1...6).contains($0.id) })
    }
}

private struct Writer {
    var data = Data()
    mutating func u8(_ value: UInt8) { data.append(value) }
    mutating func u16(_ value: UInt16) { for shift in stride(from: 0, to: 16, by: 8) { data.append(UInt8(truncatingIfNeeded: value >> shift)) } }
    mutating func u32(_ value: UInt32) { for shift in stride(from: 0, to: 32, by: 8) { data.append(UInt8(truncatingIfNeeded: value >> shift)) } }
    mutating func u64(_ value: UInt64) { for shift in stride(from: 0, to: 64, by: 8) { data.append(UInt8(truncatingIfNeeded: value >> shift)) } }
    mutating func digest(_ value: Data?) { u8(value == nil ? 0 : 32); if let value { data.append(value) } }
    mutating func rollup(_ value: FingerprintRollup) { u16(value.policyVersion); u8(value.coverage.rawValue); u32(value.componentCount); digest(value.digest) }
}

private struct Reader {
    let bytes: [UInt8], field: UInt16
    var offset = 0
    init(_ data: Data, field: UInt16) { bytes = Array(data); self.field = field }
    mutating func take(_ count: Int) throws -> Data {
        guard count >= 0, count <= bytes.count - offset else { throw EnvironmentDescriptionError.invalidField(field) }
        defer { offset += count }; return Data(bytes[offset..<(offset + count)])
    }
    mutating func number(_ count: Int) throws -> UInt64 { try take(count).enumerated().reduce(0) { $0 | (UInt64($1.element) << (8 * $1.offset)) } }
    mutating func u8() throws -> UInt8 { UInt8(try number(1)) }
    mutating func u16() throws -> UInt16 { UInt16(try number(2)) }
    mutating func u32() throws -> UInt32 { UInt32(try number(4)) }
    mutating func u64() throws -> UInt64 { try number(8) }
    mutating func coverage() throws -> FingerprintCoverage {
        guard let value = FingerprintCoverage(rawValue: try u8()) else { throw EnvironmentDescriptionError.invalidField(field) }; return value
    }
    mutating func digest() throws -> Data? {
        let count = try u8(); guard count == 0 || count == 32 else { throw EnvironmentDescriptionError.invalidField(field) }
        return count == 0 ? nil : try take(32)
    }
    mutating func rollup() throws -> FingerprintRollup { try FingerprintRollup(policyVersion: u16(), coverage: coverage(), componentCount: u32(), digest: digest()) }
    func end() throws { guard offset == bytes.count else { throw EnvironmentDescriptionError.invalidField(field) } }
}
