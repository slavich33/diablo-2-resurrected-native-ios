import XCTest
import CryptoKit
@testable import ReimaginedClient

final class CharacterSidecarSealTests: XCTestCase {
    private func hex(_ text: String) throws -> Data {
        let chars = Array(text); XCTAssertTrue(chars.count.isMultiple(of: 2))
        return try Data(stride(from: 0, to: chars.count, by: 2).map { try XCTUnwrap(UInt8(String(chars[$0...$0+1]), radix: 16)) })
    }

    private func corpus() throws -> [(CharacterSidecar, Data)] {
        struct Corpus: Decodable {
            struct Entry: Decodable { let fileHex: String, digestHex: String }
            let referenceSHA256: String, domainHex: String
            let signaturePayloadRange: [Int], cases: [Entry], liveAdmissionVerified: Bool
        }
        let url = try XCTUnwrap(Bundle.module.url(forResource: "sidecar-signing-reference", withExtension: "json"))
        let c = try JSONDecoder().decode(Corpus.self, from: Data(contentsOf: url))
        XCTAssertEqual(c.referenceSHA256, "2a868d013d2e0830bd2d9e04b918b19e46a73cf726c833e70d089b948fdeb5a2")
        XCTAssertEqual(try hex(c.domainHex), Data("D2RL-SEAL-V2\0".utf8))
        XCTAssertEqual(c.signaturePayloadRange, [232, 296]); XCTAssertFalse(c.liveAdmissionVerified)
        XCTAssertEqual(c.cases.count, 103)
        return try c.cases.map { (try CharacterSidecar.decode(hex($0.fileHex)), try hex($0.digestHex)) }
    }

    func testFullOriginalSigningDigest() throws {
        for (sidecar, expected) in try corpus() { XCTAssertEqual(Data(sidecar.signingDigest()), expected) }
    }

    func testOwnKeySigningRoundTripAndPinnedKey() throws {
        let original = try XCTUnwrap(corpus().first?.0)
        XCTAssertThrowsError(try original.verifySeal())
        let key = P256.Signing.PrivateKey()
        let signed = try original.sealed(using: key)
        XCTAssertEqual(signed.sealPublicKey, key.publicKey.rawRepresentation)
        try signed.verifySeal(expectedPublicKey: key.publicKey.rawRepresentation)
        let decoded = try CharacterSidecar.decode(signed.encoded())
        try decoded.verifySeal(expectedPublicKey: key.publicKey.rawRepresentation)
        XCTAssertThrowsError(try decoded.verifySeal(expectedPublicKey: P256.Signing.PrivateKey().publicKey.rawRepresentation))
        XCTAssertThrowsError(try decoded.sealed(using: P256.Signing.PrivateKey()))
        try decoded.sealed(using: key).verifySeal(expectedPublicKey: key.publicKey.rawRepresentation)
        XCTAssertEqual(Array(original.fixedFields[48..<120]), Array(signed.fixedFields[48..<120]))
        XCTAssertEqual(signed.texts, original.texts); XCTAssertEqual(signed.stats, original.stats)
    }

    func testContentPublicKeyAndSignatureTamperingAreRejected() throws {
        let key = P256.Signing.PrivateKey()
        let baseline = try XCTUnwrap(corpus().first?.0).sealed(using: key)
        for offset in [8, 16, 48, 72, 168, 200, 232, 295] {
            var fields = baseline.fixedFields; fields[offset] ^= 1
            if let changed = try? CharacterSidecar(fixedFields: fields, texts: baseline.texts, mod: baseline.mod, plugins: baseline.plugins, stats: baseline.stats) {
                XCTAssertThrowsError(try changed.verifySeal(), "Offset \(offset)")
                XCTAssertThrowsError(try changed.sealed(using: key), "Tampered prior history was silently re-signed")
            }
        }
        let changedText = try CharacterSidecar(fixedFields: baseline.fixedFields, texts: [Data("tampered".utf8), Data()], mod: baseline.mod, plugins: baseline.plugins, stats: baseline.stats)
        XCTAssertThrowsError(try changedText.verifySeal())
        XCTAssertNotEqual(Data(changedText.signingDigest()), Data(baseline.signingDigest()))
    }

    func testInvalidKeychainScopesFailBeforeKeychainAccess() throws {
        let store = SidecarSigningKeychain(service: "unused-synthetic-scope")
        for text in ["http://example.invalid", "https://user@example.invalid", "https://example.invalid?token=x", "https://example.invalid#fragment"] {
            XCTAssertThrowsError(try store.loadOrCreate(origin: URL(string: text)!, accountID: "own-synthetic-account"))
        }
        XCTAssertThrowsError(try store.loadOrCreate(origin: URL(string: "https://example.invalid")!, accountID: ""))
        XCTAssertThrowsError(try store.loadOrCreate(origin: URL(string: "https://example.invalid/path")!, accountID: "own"))
        let a = try SidecarSigningKeychain.scopedAccount(origin: URL(string: "https://EXAMPLE.invalid:443/")!, accountID: "own")
        let b = try SidecarSigningKeychain.scopedAccount(origin: URL(string: "https://example.invalid")!, accountID: "own")
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(b, try SidecarSigningKeychain.scopedAccount(origin: URL(string: "https://example.invalid:444")!, accountID: "own"))
        XCTAssertNotEqual(b, try SidecarSigningKeychain.scopedAccount(origin: URL(string: "https://example.invalid")!, accountID: "another"))
    }
}
