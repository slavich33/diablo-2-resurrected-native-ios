import XCTest
import CryptoKit
@testable import ReimaginedClient

final class CharacterSaveCommitSessionTests: XCTestCase {
    private let fixtureName = "NativeFixture"
    private func save(_ marker: UInt8? = nil) -> Data {
        var bytes = [UInt8](repeating: 0, count: marker == nil ? 403 : 512)
        func word(_ at: Int, _ value: UInt32) { for i in 0..<4 { bytes[at + i] = UInt8(truncatingIfNeeded: value >> (8 * i)) } }
        word(0, 0xaa55aa55); word(4, 105); word(8, UInt32(bytes.count)); word(20, marker == nil ? 1 : 0)
        bytes[24] = 4; bytes[25] = 16; bytes[26] = 30; bytes[27] = 1; bytes[248] = 3
        bytes.replaceSubrange(299..<(299 + fixtureName.utf8.count), with: fixtureName.utf8)
        if let marker { bytes[450] = marker }
        var checksum: UInt32 = 0
        for byte in bytes { checksum = ((checksum << 1) | (checksum >> 31)) &+ UInt32(byte) }
        word(12, checksum)
        return Data(bytes)
    }
    private func verified(_ bytes: Data, version: Int64 = 1) throws -> VerifiedServerSave {
        try VerifiedServerSave(metadata: ServerSaveMetadata(fileName: fixtureName + ".d2s", characterName: fixtureName,
            sha256: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined(), version: version,
            byteCount: Int64(bytes.count), corrupt: false, lastSavedAtUtc: nil), bytes: bytes)
    }
    private func metadata(_ bytes: Data, contract: UInt64 = 1, count: UInt32 = 1,
                          digest: Data? = nil, flag: Bool = false, lowerName: Bool = false) throws -> CharacterSaveMetadata {
        let checksum = (0..<4).reduce(UInt32(0)) { $0 | UInt32(bytes[12 + $1]) << (8 * $1) }
        return try CharacterSaveMetadata(characterName: Data((lowerName ? fixtureName.lowercased() : fixtureName).utf8),
            saveChecksum: checksum, saveByteCount: UInt32(bytes.count), gameEdition: 3,
            saveSHA256: digest ?? Data(SHA256.hash(data: bytes)), word50: contract, word58: count,
            word60: 10, word68: 20, flag70: flag, blob71: Data([1]), blob1071: Data([1]))
    }
    private func table(names: [UInt16: String] = [0: "own_stat"], edition: UInt8 = 3) throws -> ItemStatCostSnapshot {
        try ItemStatCostSnapshot(edition: edition, rows: Data(count: 324), resolvedNames: names)
    }
    private func session(key: P256.Signing.PrivateKey = P256.Signing.PrivateKey()) throws -> CharacterSaveCommitSession {
        try CharacterSaveCommitSession(generation: 7, characterName: fixtureName, initialSave: verified(save()),
            environment: EnvironmentMetadata(rootTexts: [Data("own-root".utf8), Data()]), clientPlugins: [], signingKey: key)
    }
    private func receive(_ metadata: CharacterSaveMetadata, _ session: CharacterSaveCommitSession) throws {
        for message in try metadata.controlMessages() { try session.receive(message, generation: 7) }
    }

    func testFullMetadataToSignedSaveRetryCommitAndNextHistory() throws {
        let key = P256.Signing.PrivateKey(), session = try session(key: key), data = save(1)
        XCTAssertNil(try session.prepare(save(), generation: 7, table: table(), timestamp: 100))
        XCTAssertThrowsError(try session.prepare(data, generation: 7, table: table(), timestamp: 100)) {
            XCTAssertEqual($0 as? SaveCommitSessionError, .waitingForMetadata)
        }
        let info = try metadata(data, flag: true, lowerName: true)
        try receive(info, session); try receive(info, session)
        XCTAssertEqual(session.pendingMetadataCount, 1)
        let first = try XCTUnwrap(session.prepare(data, generation: 7, table: table(), timestamp: 100))
        XCTAssertEqual(first.saveBytes, data)
        let sidecar = try CharacterSidecar.decode(first.sidecarBytes)
        try sidecar.verifySignedVersion105Save(data, expectedCharacterName: fixtureName, expectedPublicKey: key.publicKey.rawRepresentation)
        XCTAssertEqual(sidecar.stats.map(\.id), [0]); XCTAssertEqual(sidecar.stats.map(\.flags), [3])
        XCTAssertEqual(sidecar.historyCounter, 1); XCTAssertEqual(sidecar.fixedFields[120] & 2, 2)
        try session.complete(first, generation: 7, committed: false)
        XCTAssertEqual(session.pendingMetadataCount, 1)
        let retried = try XCTUnwrap(session.prepare(data, generation: 7, table: table(), timestamp: 900))
        XCTAssertEqual(retried.sidecarBytes, first.sidecarBytes)
        try session.complete(retried, generation: 7, committed: true)
        XCTAssertEqual(session.pendingMetadataCount, 0)
        try receive(info, session); XCTAssertEqual(session.pendingMetadataCount, 0)
        XCTAssertNil(try session.prepare(data, generation: 7, table: table(), timestamp: 901))
        XCTAssertThrowsError(try session.complete(first, generation: 7, committed: true))
        let secondData = save(2); try receive(metadata(secondData, contract: 2, count: 2), session)
        let second = try XCTUnwrap(session.prepare(secondData, generation: 7, table: table(), timestamp: 200))
        let next = try CharacterSidecar.decode(second.sidecarBytes)
        XCTAssertEqual(next.historyCounter, 2); XCTAssertEqual(next.historyIdentifier, sidecar.historyIdentifier)
        XCTAssertEqual(next.fixedFields.subdata(in: 88..<120), Data(SHA256.hash(data: first.sidecarBytes)))
        XCTAssertEqual(next.fixedFields[128], 3); XCTAssertEqual(next.fixedFields[136], 3)
        try session.complete(second, generation: 7, committed: true)
        XCTAssertEqual(session.pendingMetadataCount, 0)
    }

    func testOldGenerationAndOtherSessionPreparationCannotBeConsumed() throws {
        let first = try session(), second = try session(), data = save(1)
        let message = try XCTUnwrap(metadata(data).controlMessages().first)
        XCTAssertThrowsError(try first.receive(message, generation: 6))
        try receive(metadata(data), first); try receive(metadata(data), second)
        let prepared = try XCTUnwrap(first.prepare(data, generation: 7, table: table(), timestamp: 100))
        _ = try second.prepare(data, generation: 7, table: table(), timestamp: 100)
        XCTAssertThrowsError(try second.complete(prepared, generation: 7, committed: true))
        XCTAssertThrowsError(try first.complete(prepared, generation: 8, committed: true))
        XCTAssertEqual(first.pendingMetadataCount, 1); XCTAssertEqual(second.pendingMetadataCount, 1)
        first.invalidate()
        XCTAssertThrowsError(try first.complete(prepared, generation: 7, committed: true))
        XCTAssertThrowsError(try first.prepare(data, generation: 7, table: table(), timestamp: 100))
    }

    func testHeaderMatchWithoutFullDigestNeverConsumesMetadata() throws {
        let session = try session(), data = save(1)
        try receive(metadata(data, digest: Data(repeating: 42, count: 32)), session)
        XCTAssertThrowsError(try session.prepare(data, generation: 7, table: table(), timestamp: 100)) {
            XCTAssertEqual($0 as? SaveCommitSessionError, .digestMismatch)
        }
        XCTAssertEqual(session.pendingMetadataCount, 1)
        try receive(metadata(data), session)
        XCTAssertNotNil(try session.prepare(data, generation: 7, table: table(), timestamp: 100))
        XCTAssertEqual(session.pendingMetadataCount, 2)
    }

    func testConflictingMetadataAndBrokenFragmentsRequireNewBinding() throws {
        let data = save(1), session = try session()
        try receive(metadata(data), session)
        XCTAssertThrowsError(try receive(metadata(data, contract: 2), session)) {
            XCTAssertEqual($0 as? SaveCommitSessionError, .conflictingMetadata)
        }
        XCTAssertEqual(session.pendingMetadataCount, 0)
        XCTAssertThrowsError(try receive(metadata(data), session))
        let another = try self.session()
        try receive(metadata(data), another)
        XCTAssertThrowsError(try another.receive(ControlMessage(kind: 8, payload: Data()), generation: 7))
        XCTAssertEqual(another.pendingMetadataCount, 0)
        XCTAssertThrowsError(try receive(metadata(data), another))
    }

    func testMissingTableNamesAndWrongEditionPreservePendingMatch() throws {
        let session = try session(), data = save(1)
        try receive(metadata(data), session)
        XCTAssertThrowsError(try session.prepare(data, generation: 7, table: table(names: [:]), timestamp: 100))
        XCTAssertThrowsError(try session.prepare(data, generation: 7, table: table(edition: 2), timestamp: 100))
        XCTAssertEqual(session.pendingMetadataCount, 1)
        XCTAssertNotNil(try session.prepare(data, generation: 7, table: table(), timestamp: 100))
    }

    func testProgressedSnapshotNeedsMatchingTrustedPredecessorAndKey() throws {
        let key = P256.Signing.PrivateKey(), session = try session(key: key), data = save(1)
        try receive(metadata(data), session)
        let first = try XCTUnwrap(session.prepare(data, generation: 7, table: table(), timestamp: 100))
        XCTAssertThrowsError(try CharacterSaveCommitSession(generation: 8, characterName: fixtureName, initialSave: verified(data),
            environment: EnvironmentMetadata(), clientPlugins: [], signingKey: key))
        XCTAssertThrowsError(try CharacterSaveCommitSession(generation: 8, characterName: fixtureName, initialSave: verified(save(), version: 2),
            environment: EnvironmentMetadata(), clientPlugins: [], signingKey: key))
        _ = try CharacterSaveCommitSession(generation: 8, characterName: fixtureName, initialSave: verified(data),
            previousSidecar: first.sidecarBytes, environment: EnvironmentMetadata(), clientPlugins: [], signingKey: key)
        XCTAssertThrowsError(try CharacterSaveCommitSession(generation: 8, characterName: fixtureName, initialSave: verified(data),
            previousSidecar: first.sidecarBytes, environment: EnvironmentMetadata(), clientPlugins: [], signingKey: P256.Signing.PrivateKey()))
        XCTAssertThrowsError(try CharacterSaveCommitSession(generation: 8, characterName: fixtureName, initialSave: verified(save(2)),
            previousSidecar: first.sidecarBytes, environment: EnvironmentMetadata(), clientPlugins: [], signingKey: key))
        let signed = try CharacterSidecar.decode(first.sidecarBytes)
        var fields = signed.fixedFields; fields[120] |= 4
        fields.replaceSubrange(160..<296, with: Data(count: 136))
        let unsigned = try CharacterSidecar(fixedFields: fields, texts: signed.texts, mod: signed.mod,
            plugins: signed.plugins, stats: signed.stats).encoded()
        XCTAssertThrowsError(try CharacterSaveCommitSession(generation: 8, characterName: fixtureName, initialSave: verified(data),
            previousSidecar: unsigned, environment: EnvironmentMetadata(), clientPlugins: [], signingKey: key))
        let restored = try CharacterSaveCommitSession(generation: 7, characterName: fixtureName, initialSave: verified(data),
            previousSidecar: unsigned, trustedUnsignedSidecarSHA256: Data(SHA256.hash(data: unsigned)),
            environment: EnvironmentMetadata(), clientPlugins: [], signingKey: key)
        let next = save(2); try receive(metadata(next), restored)
        let advanced = try XCTUnwrap(restored.prepare(next, generation: 7, table: table(), timestamp: 200))
        let sidecar = try CharacterSidecar.decode(advanced.sidecarBytes)
        XCTAssertEqual(sidecar.historyCounter, 2)
        XCTAssertEqual(sidecar.fixedFields.subdata(in: 88..<120), Data(SHA256.hash(data: unsigned)))
        try sidecar.verifySignedVersion105Save(next, expectedCharacterName: fixtureName, expectedPublicKey: key.publicKey.rawRepresentation)
    }

    func testMetadataQueueHasBoundAndRejectsFurtherUseAfterOverflow() throws {
        let session = try session()
        for i in 0..<CharacterSaveCommitSession.maximumPendingMetadata { try receive(metadata(save(UInt8(i))), session) }
        XCTAssertEqual(session.pendingMetadataCount, CharacterSaveCommitSession.maximumPendingMetadata)
        XCTAssertThrowsError(try receive(metadata(save(200)), session)) {
            XCTAssertEqual($0 as? SaveCommitSessionError, .metadataLimit)
        }
        XCTAssertEqual(session.pendingMetadataCount, 0)
        XCTAssertThrowsError(try receive(metadata(save(1)), session))
    }
}
