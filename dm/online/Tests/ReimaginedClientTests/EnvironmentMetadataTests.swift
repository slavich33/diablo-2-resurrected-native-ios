import XCTest
import CryptoKit
@testable import ReimaginedClient

final class EnvironmentMetadataTests: XCTestCase {
    private func hex(_ value: String) throws -> Data {
        let chars = Array(value); XCTAssertTrue(chars.count.isMultiple(of: 2))
        return try Data(stride(from: 0, to: chars.count, by: 2).map {
            try XCTUnwrap(UInt8(String(chars[$0...$0 + 1]), radix: 16))
        })
    }

    func testCompleteOriginalParserAndDecodedMetadata() throws {
        struct Model: Decodable {
            struct Mod: Decodable { let texts: [String], word: UInt32, flag: Bool }
            struct Plugin: Decodable {
                let texts: [String], role: UInt8, scope: UInt8, word84: UInt32, word88: UInt32, digest: String?
            }
            let rootTexts: [String]?, mod: Mod?, plugins: [Plugin]?
        }
        struct Corpus: Decodable {
            struct Entry: Decodable { let label: String, envelopeHex: String, accepted: Bool, metadata: Model? }
            let referenceSHA256: String, cases: [Entry], liveAdmissionVerified: Bool
        }
        let url = try XCTUnwrap(Bundle.module.url(forResource: "environment-metadata-reference", withExtension: "json"))
        let corpus = try JSONDecoder().decode(Corpus.self, from: Data(contentsOf: url))
        XCTAssertEqual(corpus.referenceSHA256, "2a868d013d2e0830bd2d9e04b918b19e46a73cf726c833e70d089b948fdeb5a2")
        XCTAssertFalse(corpus.liveAdmissionVerified)
        XCTAssertEqual(corpus.cases.count, 232); XCTAssertEqual(corpus.cases.filter(\.accepted).count, 84)
        for entry in corpus.cases {
            let bytes = try hex(entry.envelopeHex)
            let decoded = try? EnvironmentDescription.decode(EnvironmentEnvelope.decode(bytes))
            XCTAssertEqual(decoded != nil, entry.accepted, entry.label)
            if let decoded {
                let model = try XCTUnwrap(entry.metadata, entry.label)
                let mod = try model.mod.map { try EnvironmentMetadata.Mod(texts: $0.texts.map(hex), word: $0.word, flag: $0.flag) }
                let plugins = try model.plugins.map { try $0.map {
                    try EnvironmentMetadata.Plugin(texts: $0.texts.map(hex), role: $0.role, scope: $0.scope,
                        word84: $0.word84, word88: $0.word88, digest: $0.digest.map(hex))
                } }
                let expected = try EnvironmentMetadata(rootTexts: model.rootTexts.map { try $0.map(hex) }, mod: mod, plugins: plugins)
                XCTAssertEqual(decoded.metadata, expected, entry.label)
                XCTAssertEqual(decoded.metadata.fields(), decoded.optionalFields, entry.label)
                XCTAssertEqual(try decoded.envelope().encoded(), bytes, entry.label)
            }
        }
    }

    private func fixedFields() -> Data {
        var data = Data(count: 296)
        // Own minimal unsigned codec fixture; not a game/server character.
        for offset in [12, 16, 48, 64, 72, 80] { data[offset] = 1 }
        data[120] = 4
        return data
    }

    private func plugin(_ name: String, scope: UInt8) throws -> EnvironmentMetadata.Plugin {
        try EnvironmentMetadata.Plugin(texts: [Data(name.utf8), Data(), Data(), Data("file".utf8)],
            role: 1, scope: scope, word84: 0x1234, word88: 0xabcd, digest: nil)
    }

    func testSidecarProjectionReplacesHostClientScopeWithExplicitOwnInventory() throws {
        let roots = [Data("root".utf8), Data("build".utf8)]
        let mod = try EnvironmentMetadata.Mod(texts: [Data("mod".utf8), Data("version".utf8), Data("third".utf8), Data("fourth".utf8)],
            word: 0xfedcba98, flag: true)
        let host = try EnvironmentMetadata(rootTexts: roots, mod: mod,
            plugins: [plugin("host-client", scope: 1), plugin("server", scope: 3), plugin("shared", scope: 2)])
        let own = CharacterSidecar.Plugin(words: [2, 1, 17, 19], hasDigest: true, digest: Data(repeating: 42, count: 32),
            texts: [Data("own-client".utf8), Data(), Data(), Data("file".utf8)])
        let sidecar = try CharacterSidecar(fixedFields: fixedFields(), environmentMetadata: host, clientPlugins: [own], stats: [])
        XCTAssertEqual(sidecar.texts, roots)
        XCTAssertEqual(sidecar.mod?.scope, 1); XCTAssertEqual(sidecar.mod?.word, 0xfedcba98)
        XCTAssertEqual(sidecar.mod?.texts, [mod.texts[0], mod.texts[1], Data(), mod.texts[2], mod.texts[3]])
        XCTAssertEqual(sidecar.plugins.map { $0.texts[0] }, [Data("server".utf8), Data("shared".utf8), Data("own-client".utf8)])
        XCTAssertEqual(sidecar.plugins.map(\.words), [[1, 3, 0x1234, 0xabcd], [1, 2, 0x1234, 0xabcd], [2, 1, 17, 19]])
        XCTAssertEqual(sidecar.plugins[0].digest, Data(count: 32)); XCTAssertFalse(sidecar.plugins[0].hasDigest)
        XCTAssertEqual(try CharacterSidecar.decode(sidecar.encoded()), sidecar)
        let key = P256.Signing.PrivateKey()
        try sidecar.sealed(using: key).verifySeal(expectedPublicKey: key.publicKey.rawRepresentation)
        let misplaced = CharacterSidecar.Plugin(words: [1, 2, 0, 0], hasDigest: false, digest: Data(count: 32), texts: own.texts)
        XCTAssertThrowsError(try CharacterSidecar(fixedFields: fixedFields(), environmentMetadata: host, clientPlugins: [misplaced], stats: []))
    }

    func testEnvironmentByteStringsCannotBypassStricterSidecarTextRules() throws {
        for value in [Data([0xff]), Data([65, 0, 66])] {
            let metadata = try EnvironmentMetadata(rootTexts: [value, Data()])
            XCTAssertEqual(try EnvironmentMetadata.decode(metadata.fields()), metadata)
            XCTAssertThrowsError(try CharacterSidecar(fixedFields: fixedFields(), environmentMetadata: metadata, clientPlugins: [], stats: []))
        }
        // Environment allows an empty second mod text; sidecar requires it.
        let mod = try EnvironmentMetadata.Mod(texts: [Data("mod".utf8), Data(), Data(), Data()], word: 0, flag: false)
        XCTAssertThrowsError(try CharacterSidecar(fixedFields: fixedFields(), environmentMetadata: EnvironmentMetadata(mod: mod), clientPlugins: [], stats: []))
    }

    func testAbsentVersusEmptyAndUnknownFieldsRemainDistinct() throws {
        let absent = try EnvironmentMetadata()
        let empty = try EnvironmentMetadata(rootTexts: [Data(), Data()], plugins: [])
        XCTAssertTrue(absent.fields().isEmpty); XCTAssertEqual(empty.fields().map(\.id), [16, 18])
        XCTAssertNotEqual(absent, empty)
        let sidecar = try CharacterSidecar(fixedFields: fixedFields(), environmentMetadata: absent, clientPlugins: [], stats: [])
        XCTAssertEqual(sidecar.texts, [Data(), Data()]); XCTAssertNil(sidecar.mod); XCTAssertTrue(sidecar.plugins.isEmpty)
        let unknown = EnvironmentField(id: 123, required: false, payload: Data([1, 2, 3]))
        let base = try EnvironmentDescription.unavailableProfile()
        let profile = try EnvironmentDescription.decode(EnvironmentEnvelope(fields: base.envelope().fields + [unknown] + empty.fields()))
        XCTAssertEqual(profile.metadata, empty); XCTAssertEqual(profile.optionalFields, [unknown] + empty.fields())
    }

    func testDuplicateIdentityIgnoresScopeButRetainsRoleAndByteCase() throws {
        XCTAssertThrowsError(try EnvironmentMetadata(plugins: [plugin("same", scope: 1), plugin("same", scope: 2)]))
        _ = try EnvironmentMetadata(plugins: [plugin("SAME", scope: 2), plugin("same", scope: 1)])
        XCTAssertThrowsError(try EnvironmentMetadata(plugins: [plugin("same", scope: 1), plugin("SAME", scope: 2)]))
        let source = try plugin("same", scope: 2)
        let otherRole = try EnvironmentMetadata.Plugin(texts: source.texts, role: 2, scope: 2, word84: 0, word88: 0, digest: nil)
        _ = try EnvironmentMetadata(plugins: [source, otherRole])
        let maximum = try (0..<256).map { try plugin(String(format: "item%03d", $0), scope: 2) }
        let metadata = try EnvironmentMetadata(plugins: maximum)
        XCTAssertEqual(try EnvironmentMetadata.decode(metadata.fields()), metadata)
        XCTAssertThrowsError(try EnvironmentMetadata(plugins: maximum + [plugin("overflow", scope: 2)]))
    }
}
