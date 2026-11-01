// Coupled native Swift/C filesystem test on owned synthetic data. No account,
// original game file, engine launch, network or persistent signing key.
import Foundation
import CryptoKit

private enum CheckError: Error { case failed(String), arguments }
private func require(_ value: Bool, _ label: String) throws { if !value { throw CheckError.failed(label) } }
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
    word(12, checksum); return Data(bytes)
}

private func metadata(_ data: Data) throws -> CharacterSaveMetadata {
    let checksum = (0..<4).reduce(UInt32(0)) { $0 | UInt32(data[12 + $1]) << (8 * $1) }
    return try CharacterSaveMetadata(characterName: Data(fixtureName.utf8), saveChecksum: checksum,
        saveByteCount: UInt32(data.count), gameEdition: 3, saveSHA256: Data(SHA256.hash(data: data)),
        word50: 1, word58: 1, word60: 10, word68: 20, flag70: false, blob71: Data([1]), blob1071: Data([1]))
}

private func run() throws {
    guard CommandLine.arguments.count == 2 || (CommandLine.arguments.count == 3 && ["--readback-failure", "--late-namespace", "--detach", "--server-owned"].contains(CommandLine.arguments[2])) else { throw CheckError.arguments }
    let corruptReadback = CommandLine.arguments.last == "--readback-failure"
    let lateNamespace = CommandLine.arguments.last == "--late-namespace"
    let healthyDetach = CommandLine.arguments.last == "--detach"
    let serverOwned = CommandLine.arguments.last == "--server-owned"
    let manager = FileManager.default
    let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true).appendingPathComponent("save-test-" + UUID().uuidString)
    try manager.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    defer { try? manager.removeItem(at: root) }
    let offline = root.appendingPathComponent("offline-sentinel"), untouched = Data("independent offline sentinel".utf8)
    try untouched.write(to: offline)
    let initial = save(serverOwned ? 0 : nil), key = P256.Signing.PrivateKey()
    let entry = ServerSaveMetadata(fileName: fixtureName + ".d2s", characterName: fixtureName,
        sha256: SHA256.hash(data: initial).map { String(format: "%02x", $0) }.joined(),
        version: serverOwned ? 19 : 1, byteCount: Int64(initial.count), corrupt: false, lastSavedAtUtc: nil)
    let verified = try VerifiedServerSave(metadata: entry, bytes: initial)
    let scope = try LadderSaveScope(ladderID: UUID(), accountID: "own-synthetic-account")
    let manifest = ServerSaveManifest(ladderID: scope.ladderID, serverAuthoritative: true, files: [entry])
    let snapshot = try ServerSaveSnapshot.stage([verified], manifest: manifest, scope: scope, root: root, layout: .switchVersion105)
    let work = URL(fileURLWithPath: snapshot.path + ".work", isDirectory: true)
    func file(_ root: URL, _ ext: String) -> URL { root.appendingPathComponent(fixtureName).appendingPathComponent(fixtureName + ext) }
    func pair() throws -> (Data, Data?) {
        let sidecar = file(snapshot, ".d2rl")
        return try (Data(contentsOf: file(snapshot, ".d2s")), manager.fileExists(atPath: sidecar.path) ? Data(contentsOf: sidecar) : nil)
    }
    func write(_ data: Data, keepOpen: Bool = false) throws {
        let result = data.withUnsafeBytes { raw in
            ("save:/" + fixtureName + "/" + fixtureName + ".d2s").withCString {
                fixture_write($0, raw.baseAddress, raw.count, keepOpen ? 1 : 0)
            }
        }
        try require(result == 0, "original-hle-write")
    }
    try require(nativeSaveCompletionEnabled() == 0, "default-unbound")
    do { _ = try NativeEnvironmentTableProfile.capturePreparedPeerProfile(); throw CheckError.failed("peer-profile-without-isolated-namespace") }
    catch NativeSaveCommitError.invalidScope {}
    let namespace = try NativeServerSaveNamespace(scope: scope, root: root, snapshotDirectory: snapshot,
        characterName: fixtureName, selectedSave: verified)
    fixture_install_legacy_probes()
    if lateNamespace {
        try require(snapshot.path.withCString { fixture_mount($0) } == 0 && fixture_commit() == 0, "ordinary-offline-mount")
        try require(fixture_legacy_calls() > 0, "offline-hooks-still-work")
        do { try NativeServerSaveNamespace.prepareBeforeEngineStart(namespace); throw CheckError.failed("late-namespace-was-accepted") }
        catch NativeSaveCommitError.busy {}
        try require(nativeSaveIsolated() == 0 && Data(contentsOf: offline) == untouched, "late-bind-preserves-offline-mode")
        print("Native namespace: late isolation rejected after host/save startup; ordinary offline hooks and original bytes preserved.")
        return
    }
    try NativeServerSaveNamespace.prepareBeforeEngineStart(namespace)
    let outside = root.appendingPathComponent("must-not-be-created")
    try require(outside.path.withCString { fixture_mount($0) } != 0 && !manager.fileExists(atPath: outside.path), "wrong-root-rejected-before-seeding")
    fixture_fail_next(1)
    try require(snapshot.path.withCString { fixture_mount($0) } != 0 && fixture_commit() != 0, "online-mount-clone-failure-never-falls-back-readonly")
    try require(snapshot.path.withCString { fixture_mount($0) } == 0, "real-isolated-save-mount")
    let cloud = root.appendingPathComponent("unused-local-cloud")
    cloud.path.withCString { fixture_cloud_boot($0) }
    try require(fixture_cloud_probe_calls() == 0 && !manager.fileExists(atPath: cloud.path), "actual-cloud-boot-guard")
    let unadmitted = save(99)
    try write(unadmitted)
    try require(fixture_commit() != 0, "unadmitted-character-change-refused")
    try require(try pair().0 == initial && pair().1 == nil && Data(contentsOf: file(work, ".d2s")) == unadmitted,
                "unadmitted-refusal-preserves-committed-and-pending-bytes")
    try write(initial)
    try require(fixture_commit() == 0 && fixture_legacy_calls() == 0, "unadmitted-unchanged-commit-without-offline-hooks")
    let absentTableProfile = try NativeEnvironmentTableProfile.capturePreparedPeerProfile()
    try require(absentTableProfile.generations.isEmpty && absentTableProfile.description.itemStatSchemas.allSatisfy({ $0.coverage == .unavailable }),
                "unloaded-tables-never-claim-schema")
    fixture_capture_tables_without_names()
    let namelessProfile = try NativeEnvironmentTableProfile.capture()
    try require(namelessProfile.generations.isEmpty && namelessProfile.description.itemStatSchemas.allSatisfy({ $0.coverage == .unavailable }),
                "binary-tables-without-names-never-claim-full-schema")
    fixture_capture_tables()
    do { try absentTableProfile.validateCurrent(); throw CheckError.failed("unloaded-profile-survived-new-table-load") }
    catch NativeItemStatCostError.nativeStatus(let status) { try require(status == DM_NET_TABLE_STALE, "new-table-load-invalidates-prior-profile") }
    let tableProfile = try NativeEnvironmentTableProfile.capturePreparedPeerProfile()
    try require(tableProfile.description.itemStatSchemas.map(\.coverage) == [.unavailable, .unavailable, .complete], "actual-capture-edition-availability")
    let profileRoundtrip = try EnvironmentDescription.decode(EnvironmentEnvelope.decode(tableProfile.description.envelope().encoded()))
    try require(profileRoundtrip.itemStatSchemas == tableProfile.description.itemStatSchemas && profileRoundtrip.contract.sidecarCapability == 1 &&
                profileRoundtrip.contract.sidecarFormat == CharacterSidecar.formatVersion, "prepared-native-codec-and-actual-schema-wire-roundtrip")
    var boundInfo = dm_net_itemstatcost_info()
    try require(dm_net_itemstatcost_copy(3, 0, nil, 0, &boundInfo) == DM_NET_TABLE_READY, "bind-actual-table-generation")
    let boundTableGeneration = boundInfo.generation
    try require(tableProfile.generations[3] == boundTableGeneration, "profile-binds-actual-native-generation")
    var acquired = 0, released = 0, releaseFailure = false
    let environment = try EnvironmentMetadata(rootTexts: [Data("own-fixture".utf8), Data()])
    let session: CharacterSaveCommitSession
    if serverOwned {
        session = try CharacterSaveCommitSession.serverOwnedSnapshot(generation: 7, characterName: fixtureName,
            initialSave: verified, manifest: manifest, ladderID: scope.ladderID,
            environment: environment, clientPlugins: [], signingKey: key)
    } else {
        session = try CharacterSaveCommitSession(generation: 7, characterName: fixtureName, initialSave: verified,
            environment: environment, clientPlugins: [], signingKey: key)
    }
    let coordinator = try NativeSaveCommitCoordinator(namespace: namespace, session: session) { metadata in
        let native = try NativeItemStatCostCapture.acquireLease(for: metadata, expectedGeneration: boundTableGeneration); acquired += 1
        return SaveTableLease(snapshot: native.snapshot) {
            do { try native.release() } catch { releaseFailure = true }
            released += 1
        }
    }
    do {
        try coordinator.receive(metadata(save(1)).controlMessages()[0], generation: 7)
        throw CheckError.failed("metadata-before-admission-was-accepted")
    } catch NativeSaveCommitError.failed {}
    // Explicit synthetic admitted fixture; no real admission is asserted.
    try NativeSaveCommitCoordinator.installAdmitted(coordinator)
    defer { try? NativeSaveCommitCoordinator.detach(generation: 7) }
    func receive(_ data: Data) throws {
        for message in try metadata(data).controlMessages() { try coordinator.receive(message, generation: 7) }
    }
    let first = save(1)
    try write(first, keepOpen: true)
    try require(fixture_commit() != 0 && acquired == 0, "open-writer-must-defer")
    fixture_close_writer()
    try require(fixture_commit() != 0 && acquired == 0, "missing-metadata-must-defer")
    try require(try pair().0 == initial && pair().1 == nil, "defer-preserves-committed-pair")
    try require(try Data(contentsOf: file(work, ".d2s")) == first, "defer-preserves-pending-work")
    try receive(first)
    fixture_fail_next(1)
    try require(fixture_commit() != 0, "clone-failure")
    try require(acquired == 1 && released == 1 && session.pendingMetadataCount == 1, "clone-failure-retains-metadata-releases-pin")
    let prepared = try Data(contentsOf: file(work, ".d2rl"))
    let decoded = try CharacterSidecar.decode(prepared)
    try decoded.verifySignedVersion105Save(first, expectedCharacterName: fixtureName, expectedPublicKey: key.publicKey.rawRepresentation)
    fixture_fail_next(2)
    try require(fixture_commit() != 0 && acquired == 2 && released == 2, "swap-failure-releases-pin")
    try require(try Data(contentsOf: file(work, ".d2rl")) == prepared && pair().0 == initial, "retry-reuses-exact-signature-old-save-stays")
    try require(fixture_commit() == 0 && acquired == 3 && released == 3, "coupled-atomic-commit")
    let committed = try pair()
    try require(committed.0 == first && committed.1 == prepared, "independent-committed-readback")
    try require(session.pendingMetadataCount == 0 && coordinator.localCommitCount == 1, "consume-only-after-real-readback")
    try receive(first)
    try require(session.pendingMetadataCount == 0 && fixture_commit() == 0 && acquired == 3, "replay-and-unchanged-commit")
    let second = save(2); try write(second); try receive(second)
    try require(fixture_commit() == 0 && coordinator.localCommitCount == 2, "second-progress-commit")
    let secondPair = try pair(), secondSidecar = try CharacterSidecar.decode(secondPair.1!)
    try secondSidecar.verifySignedVersion105Save(second, expectedCharacterName: fixtureName, expectedPublicKey: key.publicKey.rawRepresentation)
    try require(secondSidecar.historyCounter == 2 && secondSidecar.historyIdentifier == decoded.historyIdentifier,
                "continuous-real-signed-history")
    try require(secondSidecar.fixedFields.subdata(in: 88..<120) == Data(SHA256.hash(data: prepared)), "exact-predecessor-file-hash")
    if corruptReadback {
        let changed = save(3); try write(changed); try receive(changed); fixture_fail_next(3)
        try require(fixture_commit() == 0, "filesystem-swap-alone-reported-success")
        try require(coordinator.failureCode != 0 && coordinator.localCommitCount == 2, "independent-readback-rejects-corrupted-commit")
        try require(try pair().0 != changed && Data(contentsOf: offline) == untouched, "owned-corruption-fixture-only")
        try require(acquired == released && !releaseFailure, "readback-failure-releases-table-pin")
        try require(fixture_legacy_calls() == 0 && fixture_cloud_probe_calls() == 0, "readback-mode-isolation")
        print("Native coupled save readback: post-swap corruption rejected despite C commit success; no local acceptance, table pin released, offline sentinel unchanged. Synthetic data only.")
        return
    }

    // A selected-file symlink must not escape the bound work directory.
    let third = save(3); try write(third); try receive(third)
    let workingSidecar = file(work, ".d2rl")
    try manager.removeItem(at: workingSidecar)
    try manager.createSymbolicLink(atPath: workingSidecar.path, withDestinationPath: offline.path)
    try require(fixture_commit() != 0, "sidecar-symlink-rejected")
    try require(try pair().0 == second && pair().1 == secondPair.1, "symlink-failure-preserves-prior-pair")
    try require(try Data(contentsOf: offline) == untouched, "offline-sentinel-unchanged")
    try manager.removeItem(at: workingSidecar); try secondPair.1!.write(to: workingSidecar)

    // Replacing the scope's parent cannot redirect a retained descriptor or
    // allow the C clone/swap to publish into a different account tree.
    let parent = snapshot.deletingLastPathComponent(), moved = parent.deletingLastPathComponent().appendingPathComponent(parent.lastPathComponent + ".moved")
    try manager.moveItem(at: parent, to: moved)
    try manager.createSymbolicLink(atPath: parent.path, withDestinationPath: root.path)
    try require(fixture_commit() != 0, "scope-parent-symlink-rejected")
    try manager.removeItem(at: parent); try manager.moveItem(at: moved, to: parent)
    try require(fixture_commit() == 0 && coordinator.localCommitCount == 3, "retry-after-safe-scope-restoration")
    try require(acquired == released && !releaseFailure && coordinator.failureCode == 0, "all-native-table-leases-balanced")
    let fourth = save(4), beforeReload = try pair()
    if healthyDetach {
        try NativeSaveCommitCoordinator.detach(generation: 7)
        try require(nativeSaveIsolated() == 1 && fixture_commit() == 0, "healthy-detach-retains-unchanged-pair")
        try write(fourth)
        try require(fixture_commit() != 0, "healthy-detach-refuses-new-unsigned-character")
        try require(try pair().0 == beforeReload.0 && pair().1 == beforeReload.1 && Data(contentsOf: offline) == untouched,
                    "healthy-detach-keeps-last-signed-and-offline-pairs")
        try require(fixture_legacy_calls() == 0 && fixture_cloud_probe_calls() == 0, "healthy-detach-never-enables-offline-hooks")
        print("Native namespace: healthy peer detach retains signed predecessor and offline/cloud isolation; new unsigned changes are deferred. Synthetic data only.")
        return
    }
    try write(fourth); try receive(fourth)
    fixture_capture_tables() // Same fixture bytes, a different published generation.
    do { try tableProfile.validateCurrent(); throw CheckError.failed("table-profile-survived-reload") }
    catch NativeItemStatCostError.nativeStatus(let status) { try require(status == DM_NET_TABLE_STALE, "reload-invalidates-environment-profile") }
    try require(fixture_commit() != 0 && coordinator.failureCode != 0, "changed-generation-must-not-rebind-silently")
    try require(try pair().0 == beforeReload.0 && pair().1 == beforeReload.1, "generation-change-preserves-last-verified-pair")
    try require(acquired == released && !releaseFailure, "stale-generation-leaks-no-pin")
    var info = dm_net_itemstatcost_info()
    try require(dm_net_itemstatcost_copy(3, 0, nil, 0, &info) == DM_NET_TABLE_READY, "capture-not-left-pinned")
    try require(try Data(contentsOf: offline) == untouched, "final-offline-preservation")
    try NativeSaveCommitCoordinator.detach(generation: 7)
    try require(nativeSaveIsolated() == 1 && fixture_commit() != 0, "detach-cannot-enable-unsigned-or-offline-fallback")
    try require(fixture_legacy_calls() == 0 && fixture_cloud_probe_calls() == 0, "all-offline-extension-and-cloud-hooks-skipped")
    print("Native coupled save commit: real HLE IO + Swift metadata/seals/history + bound native table pins + atomic readback, 3 commits; defer/clone/swap/symlink/retry/stale-generation checks passed. No server admission or upload.")
}

do { try run() }
catch {
    if case CheckError.failed(let label) = error { fputs("Native save commit check failed: \(label)\n", stderr) }
    else { fputs("Native save commit check failed: \(type(of: error))\n", stderr) }
    exit(1)
}
