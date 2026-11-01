import Foundation
import CryptoKit

public enum CharacterSidecarError: Error, Equatable {
    case size, header, digest, truncated, trailingBytes, fixedFields, text, mod, plugin, stat, duplicate
}

/// Version-2 D2RL sidecar file. The fixed block and record words retain their
/// wire representation until their gameplay/history/seal meaning is verified.
/// Structural checks and SHA256 are not signature/provenance verification.
public struct CharacterSidecar: Equatable {
    public static let formatVersion: UInt16 = 2
    public static let maximumPayload = 2 * 1024 * 1024
    public let fixedFields: Data // Exactly296 bytes, including the mod-present flag.
    public let texts: [Data] // Two optional UTF8 strings.
    public let mod: Mod?
    public let plugins: [Plugin]
    public let stats: [Stat]

    public struct Mod: Equatable {
        public let scope: UInt32, word: UInt32
        public let texts: [Data]
        public init(scope: UInt32, word: UInt32, texts: [Data]) {
            self.scope = scope; self.word = word; self.texts = texts
        }
    }
    public struct Plugin: Equatable {
        public let words: [UInt32]
        public let hasDigest: Bool
        public let digest: Data
        public let texts: [Data]
        public init(words: [UInt32], hasDigest: Bool, digest: Data, texts: [Data]) {
            self.words = words; self.hasDigest = hasDigest; self.digest = digest; self.texts = texts
        }
    }
    public struct Stat: Equatable {
        public let id: UInt32
        public let flags: UInt8
        public let flag: Bool
        public let byte34: UInt8, byte35: UInt8
        public let word30: UInt32, word2c: UInt32
        public let byte38: UInt8, byte39: UInt8
        public let name: Data
        public init(id: UInt32, flags: UInt8, flag: Bool, byte34: UInt8, byte35: UInt8,
                    word30: UInt32, word2c: UInt32, byte38: UInt8, byte39: UInt8, name: Data) {
            self.id = id; self.flags = flags; self.flag = flag; self.byte34 = byte34; self.byte35 = byte35
            self.word30 = word30; self.word2c = word2c; self.byte38 = byte38; self.byte39 = byte39; self.name = name
        }
    }

    public init(fixedFields: Data, texts: [Data], mod: Mod?, plugins: [Plugin], stats: [Stat]) throws {
        guard fixedFields.count == 296 else { throw CharacterSidecarError.fixedFields }
        let f = Array(fixedFields)
        func n(_ offset: Int, _ count: Int) -> UInt64 { (0..<count).reduce(0) { $0 | UInt64(f[offset + $1]) << (8 * $1) } }
        func zero(_ range: Range<Int>) -> Bool { f[range].allSatisfy { $0 == 0 } }
        guard n(0, 4) <= 1, (n(0, 4) == 1) == (mod != nil),
              [4, 124, 140, 164].allSatisfy({ n($0, 4) == 0 }), n(12, 4) > 0,
              !zero(16..<48), !zero(48..<64), n(64, 8) > 0, n(72, 8) > 0, n(80, 8) > 0,
              n(120, 4) < 8, n(72, 8) >= n(64, 8) || n(120, 4) & 2 != 0,
              (n(80, 8) == 1) == zero(88..<120), n(128, 8) < 64 else { throw CharacterSidecarError.fixedFields }
        if n(136, 4) == 0 {
            guard n(128, 8) == 0, n(144, 8) == 0, n(152, 8) == 0 else { throw CharacterSidecarError.fixedFields }
        } else {
            guard n(128, 8) > 0, n(144, 8) > 0, n(152, 8) >= n(144, 8) else { throw CharacterSidecarError.fixedFields }
        }
        switch n(160, 4) {
        case 0:
            guard n(120, 4) >= 4, zero(168..<232), zero(232..<296) else { throw CharacterSidecarError.fixedFields }
        case 1:
            guard n(120, 4) <= 3, !zero(168..<232), !zero(232..<296) else { throw CharacterSidecarError.fixedFields }
        default: throw CharacterSidecarError.fixedFields
        }
        guard texts.count == 2 else { throw CharacterSidecarError.text }
        for text in texts { try Self.checkText(text, required: false) }
        if let mod {
            guard mod.scope <= 1, mod.texts.count == 5 else { throw CharacterSidecarError.mod }
            for (index, text) in mod.texts.enumerated() { try Self.checkText(text, required: index < 2) }
        }
        guard plugins.count <= 256, stats.count <= 32768 else { throw CharacterSidecarError.size }
        struct PluginKey: Hashable { let role: UInt32, scope: UInt32; let id: Data }
        var pluginKeys = Set<PluginKey>()
        for plugin in plugins {
            guard plugin.words.count == 4, (1...2).contains(plugin.words[0]), (1...3).contains(plugin.words[1]),
                  plugin.digest.count == 32, plugin.hasDigest || plugin.digest.allSatisfy({ $0 == 0 }),
                  plugin.texts.count == 4 else { throw CharacterSidecarError.plugin }
            for (index, text) in plugin.texts.enumerated() { try Self.checkText(text, required: index == 0) }
            guard pluginKeys.insert(PluginKey(role: plugin.words[0], scope: plugin.words[1], id: plugin.texts[0])).inserted else {
                throw CharacterSidecarError.duplicate
            }
        }
        var ids = Set<UInt32>()
        for stat in stats {
            guard stat.id <= 32767, (1...3).contains(stat.flags),
                  stat.flags & 2 != 0 || (stat.word2c == 0 && stat.word30 == 0 && stat.byte34 == 0 && stat.byte35 == 0),
                  stat.flags & 1 != 0 || (stat.byte38 == 0 && stat.byte39 == 0 && !stat.flag) else { throw CharacterSidecarError.stat }
            try Self.checkText(stat.name, required: true)
            guard ids.insert(stat.id).inserted else { throw CharacterSidecarError.duplicate }
        }
        var size = 296 + texts.reduce(0) { $0 + 4 + $1.count } + 8
        if let mod { size += 8 + mod.texts.reduce(0) { $0 + 4 + $1.count } }
        size += plugins.reduce(0) { $0 + 56 + $1.texts.reduce(0) { $0 + 4 + $1.count } }
        size += stats.reduce(0) { $0 + 20 + 4 + $1.name.count }
        guard size <= Self.maximumPayload else { throw CharacterSidecarError.size }
        self.fixedFields = Data(fixedFields); self.texts = texts; self.mod = mod; self.plugins = plugins; self.stats = stats
    }

    private static func checkText(_ data: Data, required: Bool) throws {
        guard data.count <= 1024, !required || !data.isEmpty, !data.contains(0), String(data: data, encoding: .utf8) != nil else {
            throw CharacterSidecarError.text
        }
    }

    public func encoded() -> Data {
        var w = SidecarWriter(); w.data = fixedFields
        for text in texts { w.text(text) }
        if let mod {
            w.number(UInt64(mod.scope), 4); w.number(UInt64(mod.word), 4)
            for text in mod.texts { w.text(text) }
        }
        w.number(UInt64(plugins.count), 4)
        for plugin in plugins {
            for word in plugin.words { w.number(UInt64(word), 4) }
            w.number(plugin.hasDigest ? 1 : 0, 4); w.number(0, 4); w.data.append(plugin.digest)
            for text in plugin.texts { w.text(text) }
        }
        w.number(UInt64(stats.count), 4)
        for stat in stats {
            w.number(UInt64(stat.id), 4)
            w.data.append(contentsOf: [stat.flags, stat.flag ? 1 : 0, stat.byte34, stat.byte35])
            w.number(UInt64(stat.word30), 4); w.number(UInt64(stat.word2c), 4)
            w.data.append(contentsOf: [stat.byte38, stat.byte39, 0, 0]); w.text(stat.name)
        }
        var header = SidecarWriter(); header.data = Self.fileHeader
        header.number(UInt64(w.data.count), 4); header.data.append(contentsOf: SHA256.hash(data: w.data)); header.data.append(w.data)
        return header.data
    }

    public static func decode(_ data: Data) throws -> CharacterSidecar {
        guard (44...(maximumPayload + 44)).contains(data.count) else { throw CharacterSidecarError.size }
        let bytes = Array(data)
        guard bytes[0..<8].elementsEqual(fileHeader) else { throw CharacterSidecarError.header }
        let count = (0..<4).reduce(0) { $0 | Int(bytes[8 + $1]) << (8 * $1) }
        guard count == bytes.count - 44 else { throw CharacterSidecarError.size }
        let payload = Data(bytes[44...])
        guard Data(SHA256.hash(data: payload)) == Data(bytes[12..<44]) else { throw CharacterSidecarError.digest }
        var r = SidecarReader(payload)
        let fixed = try r.take(296), hasMod = Array(fixed)[0]
        let texts = try [r.text(), r.text()]
        var mod: Mod?
        if hasMod == 1 { mod = try Mod(scope: r.u32(), word: r.u32(), texts: [r.text(), r.text(), r.text(), r.text(), r.text()]) }
        let pluginCount = Int(try r.u32())
        guard pluginCount <= 256 else { throw CharacterSidecarError.size }
        var plugins: [Plugin] = []
        for _ in 0..<pluginCount {
            let words = try [r.u32(), r.u32(), r.u32(), r.u32()], flag = try r.u32(), reserved = try r.u32()
            guard flag <= 1, reserved == 0 else { throw CharacterSidecarError.plugin }
            let digest = try r.take(32), texts = try [r.text(), r.text(), r.text(), r.text()]
            plugins.append(Plugin(words: words, hasDigest: flag == 1, digest: digest, texts: texts))
        }
        let statCount = Int(try r.u32())
        guard statCount <= 32768 else { throw CharacterSidecarError.size }
        var stats: [Stat] = []
        for _ in 0..<statCount {
            let id = try r.u32(), flags = try r.u8(), flag = try r.u8(), byte34 = try r.u8(), byte35 = try r.u8()
            let word30 = try r.u32(), word2c = try r.u32(), byte38 = try r.u8(), byte39 = try r.u8()
            guard flag <= 1, try r.u8() == 0, try r.u8() == 0 else { throw CharacterSidecarError.stat }
            stats.append(try Stat(id: id, flags: flags, flag: flag == 1, byte34: byte34, byte35: byte35,
                word30: word30, word2c: word2c, byte38: byte38, byte39: byte39, name: r.text()))
        }
        guard r.finished else { throw CharacterSidecarError.trailingBytes }
        return try CharacterSidecar(fixedFields: fixed, texts: texts, mod: mod, plugins: plugins, stats: stats)
    }

    private static var fileHeader: Data {
        Data([0x44, 0x32, 0x52, 0x4c, UInt8(truncatingIfNeeded: formatVersion), UInt8(formatVersion >> 8), 44, 0])
    }
}

private struct SidecarWriter {
    var data = Data()
    mutating func number(_ value: UInt64, _ count: Int) {
        for shift in stride(from: 0, to: count * 8, by: 8) { data.append(UInt8(truncatingIfNeeded: value >> shift)) }
    }
    mutating func text(_ data: Data) { number(UInt64(data.count), 4); self.data.append(data) }
}
private struct SidecarReader {
    let bytes: [UInt8]; var offset = 0
    init(_ data: Data) { bytes = Array(data) }
    var finished: Bool { offset == bytes.count }
    mutating func take(_ count: Int) throws -> Data {
        guard count >= 0, count <= bytes.count - offset else { throw CharacterSidecarError.truncated }
        defer { offset += count }; return Data(bytes[offset..<(offset + count)])
    }
    mutating func u8() throws -> UInt8 { try take(1).first! }
    mutating func u32() throws -> UInt32 { try take(4).enumerated().reduce(0) { $0 | UInt32($1.element) << (8 * $1.offset) } }
    mutating func text() throws -> Data {
        let count = Int(try u32()); guard count <= 1024 else { throw CharacterSidecarError.text }; return try take(count)
    }
}
