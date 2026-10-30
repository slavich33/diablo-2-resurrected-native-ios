// D2RLoader 1.3.1-beta 的 D2EM v3 外层封装；只处理边界和字段，不验证字段内容或准入资格。
// D2RLoader 1.3.1-beta D2EM v3 outer envelope; framing/fields only, without payload semantics or admission validation.
import Foundation

public enum EnvelopeError: Error, Equatable {
    case invalidSize, invalidMagic, unsupportedVersion, bodyLengthMismatch
    case truncatedField, tooManyFields, invalidFieldID, duplicateField
    case unsupportedRequiredField, invalidRequirementFlag
}

public struct EnvironmentField: Equatable {
    public let id: UInt16
    public let required: Bool
    public let payload: Data

    public init(id: UInt16, required: Bool, payload: Data) {
        self.id = id
        self.required = required
        self.payload = payload
    }
}

public struct EnvironmentEnvelope {
    public static let maximumBytes = 65_536
    public static let maximumFields = 64
    public let fields: [EnvironmentField]

    public init(fields: [EnvironmentField]) throws {
        guard fields.count <= Self.maximumFields else { throw EnvelopeError.tooManyFields }
        var seen = Set<UInt16>(), size = 10
        for field in fields {
            try Self.check(field.id, required: field.required, seen: &seen)
            guard field.payload.count <= Self.maximumBytes - size - 6 else { throw EnvelopeError.invalidSize }
            size += 6 + field.payload.count
        }
        self.fields = fields
    }

    public static func decode(_ data: Data) throws -> EnvironmentEnvelope {
        guard (10...maximumBytes).contains(data.count) else { throw EnvelopeError.invalidSize }
        let bytes = Array(data)
        guard Array(bytes[0..<4]) == [0x44, 0x32, 0x45, 0x4d] else { throw EnvelopeError.invalidMagic }
        guard u16(bytes, 4) == 3 else { throw EnvelopeError.unsupportedVersion }
        guard Int(u32(bytes, 6)) == bytes.count - 10 else { throw EnvelopeError.bodyLengthMismatch }
        var fields: [EnvironmentField] = [], seen = Set<UInt16>(), offset = 10
        while offset < bytes.count {
            guard fields.count < maximumFields else { throw EnvelopeError.tooManyFields }
            guard bytes.count - offset >= 6 else { throw EnvelopeError.truncatedField }
            let flags = u16(bytes, offset), count = Int(u32(bytes, offset + 2))
            let id = flags & 0x7fff, required = flags & 0x8000 != 0
            offset += 6
            guard count <= bytes.count - offset else { throw EnvelopeError.truncatedField }
            try check(id, required: required, seen: &seen)
            fields.append(EnvironmentField(id: id, required: required, payload: Data(bytes[offset..<(offset + count)])))
            offset += count
        }
        return try EnvironmentEnvelope(fields: fields)
    }

    public func encoded() -> Data {
        let size = fields.reduce(0) { $0 + 6 + $1.payload.count }
        var bytes: [UInt8] = [0x44, 0x32, 0x45, 0x4d, 3, 0]
        bytes += Self.le32(UInt32(size))
        for field in fields {
            let flags = field.id | (field.required ? 0x8000 : 0)
            bytes += [UInt8(truncatingIfNeeded: flags), UInt8(truncatingIfNeeded: flags >> 8)]
            bytes += Self.le32(UInt32(field.payload.count))
            bytes += field.payload
        }
        return Data(bytes)
    }

    private static func check(_ id: UInt16, required: Bool, seen: inout Set<UInt16>) throws {
        guard (1...0x7fff).contains(id) else { throw EnvelopeError.invalidFieldID }
        guard seen.insert(id).inserted else { throw EnvelopeError.duplicateField }
        if (1...6).contains(id) {
            guard required else { throw EnvelopeError.invalidRequirementFlag }
        } else if (16...18).contains(id) {
            guard !required else { throw EnvelopeError.invalidRequirementFlag }
        } else if required { throw EnvelopeError.unsupportedRequiredField }
    }

    private static func u16(_ bytes: [UInt8], _ offset: Int) -> UInt16 {
        UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
    }

    private static func u32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        (0..<4).reduce(UInt32(0)) { $0 | UInt32(bytes[offset + $1]) << ($1 * 8) }
    }

    private static func le32(_ value: UInt32) -> [UInt8] {
        (0..<4).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) }
    }
}
