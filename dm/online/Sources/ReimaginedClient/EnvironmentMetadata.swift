import Foundation

/// Optional D2EM fields16..18. Text remains bytes: the original environment
/// reader permits values which the stricter sidecar UTF8 writer must reject.
/// These records describe an environment; they do not authenticate its origin.
public struct EnvironmentMetadata: Equatable {
    public struct Mod: Equatable {
        public let texts: [Data]
        public let word: UInt32
        public let flag: Bool

        public init(texts: [Data], word: UInt32, flag: Bool) throws {
            guard texts.count == 4, texts.allSatisfy({ $0.count <= 1024 }), !texts[0].isEmpty else {
                throw EnvironmentDescriptionError.invalidField(17)
            }
            self.texts = texts; self.word = word; self.flag = flag
        }
    }

    public struct Plugin: Equatable {
        public let texts: [Data]
        public let role: UInt8, scope: UInt8
        public let word84: UInt32, word88: UInt32
        public let digest: Data?

        public init(texts: [Data], role: UInt8, scope: UInt8,
                    word84: UInt32, word88: UInt32, digest: Data?) throws {
            guard texts.count == 4, texts.allSatisfy({ $0.count <= 1024 }),
                  !texts[0].isEmpty, !texts[3].isEmpty, (1...2).contains(role), (1...3).contains(scope),
                  digest == nil || digest?.count == 32 else { throw EnvironmentDescriptionError.invalidField(18) }
            self.texts = texts; self.role = role; self.scope = scope
            self.word84 = word84; self.word88 = word88; self.digest = digest
        }
    }

    // nil preserves absence; an explicitly present empty record is distinct.
    public let rootTexts: [Data]?
    public let mod: Mod?
    public let plugins: [Plugin]?

    public init(rootTexts: [Data]? = nil, mod: Mod? = nil, plugins: [Plugin]? = nil) throws {
        if let rootTexts {
            guard rootTexts.count == 2, rootTexts.allSatisfy({ $0.count <= 1024 }) else {
                throw EnvironmentDescriptionError.invalidField(16)
            }
        }
        if let plugins {
            guard plugins.count <= 256 else { throw EnvironmentDescriptionError.invalidField(18) }
            struct Identity: Hashable { let role: UInt8; let name: Data }
            var seen = Set<Identity>()
            var previous: Plugin?
            for plugin in plugins {
                // The original normalizer rejects a duplicate role/name even
                // when scope differs. The full parser also requires its input
                // already sorted by role, then unsigned lexicographic name.
                guard seen.insert(Identity(role: plugin.role, name: plugin.texts[0])).inserted else {
                    throw EnvironmentDescriptionError.invalidField(18)
                }
                if let previous {
                    guard previous.role < plugin.role || (previous.role == plugin.role &&
                        previous.texts[0].lexicographicallyPrecedes(plugin.texts[0])) else {
                        throw EnvironmentDescriptionError.invalidField(18)
                    }
                }
                previous = plugin
            }
        }
        self.rootTexts = rootTexts; self.mod = mod; self.plugins = plugins
    }

    public func fields() -> [EnvironmentField] {
        var result: [EnvironmentField] = []
        if let rootTexts {
            var w = MetadataWriter(); rootTexts.forEach { w.text($0) }
            result.append(EnvironmentField(id: 16, required: false, payload: w.data))
        }
        if let mod {
            var w = MetadataWriter(); mod.texts.forEach { w.text($0) }; w.number(UInt64(mod.word), 4)
            w.number(mod.flag ? 1 : 0, 1)
            result.append(EnvironmentField(id: 17, required: false, payload: w.data))
        }
        if let plugins {
            var w = MetadataWriter(); w.number(UInt64(plugins.count), 2)
            for plugin in plugins {
                plugin.texts.forEach { w.text($0) }; w.number(UInt64(plugin.role), 1); w.number(UInt64(plugin.scope), 1)
                w.number(UInt64(plugin.word84), 4); w.number(UInt64(plugin.word88), 4)
                w.number(plugin.digest == nil ? 0 : 32, 1)
                if let digest = plugin.digest { w.data.append(digest) }
            }
            result.append(EnvironmentField(id: 18, required: false, payload: w.data))
        }
        return result
    }

    public static func decode(_ fields: [EnvironmentField]) throws -> EnvironmentMetadata {
        var roots: [Data]?, mod: Mod?, plugins: [Plugin]?
        var seen = Set<UInt16>()
        for field in fields where (16...18).contains(field.id) {
            guard !field.required, field.payload.count <= EnvironmentEnvelope.maximumBytes,
                  seen.insert(field.id).inserted else { throw EnvironmentDescriptionError.invalidField(field.id) }
            var r = MetadataReader(field)
            switch field.id {
            case 16: roots = try [r.text(), r.text()]
            case 17:
                let texts = try [r.text(), r.text(), r.text(), r.text()], word = try UInt32(r.number(4)), flag = try r.number(1)
                guard flag <= 1 else { throw EnvironmentDescriptionError.invalidField(17) }
                mod = try Mod(texts: texts, word: word, flag: flag == 1)
            default:
                let count = try r.number(2)
                guard count <= 256 else { throw EnvironmentDescriptionError.invalidField(18) }
                var entries: [Plugin] = []
                for _ in 0..<count {
                    let texts = try [r.text(), r.text(), r.text(), r.text()]
                    let role = try UInt8(r.number(1)), scope = try UInt8(r.number(1))
                    let first = try UInt32(r.number(4)), second = try UInt32(r.number(4)), length = try r.number(1)
                    guard length == 0 || length == 32 else { throw EnvironmentDescriptionError.invalidField(18) }
                    entries.append(try Plugin(texts: texts, role: role, scope: scope,
                        word84: first, word88: second, digest: length == 0 ? nil : r.take(32)))
                }
                plugins = entries
            }
            try r.end()
        }
        return try EnvironmentMetadata(rootTexts: roots, mod: mod, plugins: plugins)
    }
}

private struct MetadataWriter {
    var data = Data()
    mutating func number(_ value: UInt64, _ count: Int) {
        for shift in stride(from: 0, to: count * 8, by: 8) { data.append(UInt8(truncatingIfNeeded: value >> shift)) }
    }
    mutating func text(_ value: Data) { number(UInt64(value.count), 2); data.append(value) }
}

private struct MetadataReader {
    let bytes: [UInt8], field: UInt16
    var offset = 0
    init(_ value: EnvironmentField) { bytes = Array(value.payload); field = value.id }
    mutating func take(_ count: Int) throws -> Data {
        guard count >= 0, count <= bytes.count - offset else { throw EnvironmentDescriptionError.invalidField(field) }
        defer { offset += count }; return Data(bytes[offset..<(offset + count)])
    }
    mutating func number(_ count: Int) throws -> UInt64 {
        try take(count).enumerated().reduce(0) { $0 | UInt64($1.element) << (8 * $1.offset) }
    }
    mutating func text() throws -> Data {
        let count = try number(2)
        guard count <= 1024 else { throw EnvironmentDescriptionError.invalidField(field) }
        return try take(Int(count))
    }
    func end() throws { guard offset == bytes.count else { throw EnvironmentDescriptionError.invalidField(field) } }
}
