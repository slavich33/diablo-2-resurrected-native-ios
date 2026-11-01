import Foundation
import Darwin

public enum NativeSaveCommitError: Error, Equatable {
    case invalidScope, busy, generation, noCompletion, readback, failed, thread
}

/// A provider must pin the actual copied native table generation before
/// returning this lease. Release occurs on the same filesystem thread.
public final class SaveTableLease {
    public let snapshot: ItemStatCostSnapshot
    private let owner = pthread_self()
    private var releaseBody: (() -> Void)?
    public init(snapshot: ItemStatCostSnapshot, release: @escaping () -> Void) {
        self.snapshot = snapshot; releaseBody = release
    }
    func release() throws {
        guard pthread_equal(owner, pthread_self()) != 0 else { throw NativeSaveCommitError.thread }
        if let releaseBody { self.releaseBody = nil; releaseBody() }
    }
}

/// Prepare the independently downloaded server namespace before host/cloud
/// startup, without an engine generation, signing environment or admission.
/// The guard lasts for this process; detaching a peer never enables offline
/// extensions or permits new unverified character writes in that namespace.
public final class NativeServerSaveNamespace {
    fileprivate let parent: SaveDirectory, parentURL: URL
    fileprivate let snapshotName: String, characterName: String
    fileprivate let workPath: String, commitPath: String
    private var baselineSave: Data, baselineSidecar: Data?
    private var failed = false

    public convenience init(scope: LadderSaveScope, root: URL, snapshotDirectory: URL,
                            characterName: String, selectedSave: VerifiedServerSave,
                            previousSidecar: Data? = nil) throws {
        let name = Array(characterName.utf8)
        guard (2...15).contains(name.count), name.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) }),
              selectedSave.metadata.fileName == characterName + ".d2s",
              selectedSave.bytes.count >= 403, selectedSave.bytes.count <= 8 * 1024 * 1024 else {
            throw NativeSaveCommitError.invalidScope
        }
        let parentURL = try scope.prepareDirectory(root: root), directory = snapshotDirectory.standardizedFileURL
        let label = directory.lastPathComponent
        guard directory.isFileURL, directory.deletingLastPathComponent().path == parentURL.path,
              label.hasPrefix("snapshot-"), UUID(uuidString: String(label.dropFirst(9))) != nil else { throw NativeSaveCommitError.invalidScope }
        let parent = try SaveDirectory(absolute: parentURL.path)
        let folder = try parent.directory(label).directory(characterName)
        let save = try folder.read(characterName + ".d2s", maximum: 8 * 1024 * 1024)!
        let sidecar = try folder.read(characterName + ".d2rl", maximum: CharacterSidecar.maximumPayload + 44, optional: true)
        guard save == selectedSave.bytes, sidecar == previousSidecar else { throw NativeSaveCommitError.readback }
        self.init(parent: parent, parentURL: parentURL, snapshotName: label, characterName: characterName,
                  commitPath: directory.path, save: save, sidecar: sidecar)
    }

    fileprivate init(parent: SaveDirectory, parentURL: URL, snapshotName: String, characterName: String,
                     commitPath: String, save: Data, sidecar: Data?) {
        self.parent = parent; self.parentURL = parentURL; self.snapshotName = snapshotName; self.characterName = characterName
        self.commitPath = commitPath; workPath = commitPath + ".work"; baselineSave = save; baselineSidecar = sidecar
    }

    public static func prepareBeforeEngineStart(_ namespace: NativeServerSaveNamespace) throws {
        SaveRegistry.lock.lock(); defer { SaveRegistry.lock.unlock() }
        if SaveRegistry.namespace === namespace { return }
        guard !SaveRegistry.hostStarted, SaveRegistry.mountedRoot == nil, SaveRegistry.namespace == nil,
              SaveRegistry.current == nil, SaveRegistry.attempts.isEmpty else { throw NativeSaveCommitError.busy }
        SaveRegistry.namespace = namespace
    }

    private func roots() throws -> (SaveDirectory, SaveDirectory) {
        let fresh = try SaveDirectory(absolute: parentURL.path)
        guard try parent.sameIdentity(as: fresh) else { throw NativeSaveCommitError.invalidScope }
        return try (parent.directory(snapshotName + ".work"), parent.directory(snapshotName))
    }
    private func pair(_ root: SaveDirectory) throws -> (Data, Data?) {
        let folder = try root.directory(characterName)
        return try (folder.read(characterName + ".d2s", maximum: 8 * 1024 * 1024)!,
            folder.read(characterName + ".d2rl", maximum: CharacterSidecar.maximumPayload + 44, optional: true))
    }
    fileprivate func validateMount(_ path: String) throws {
        guard !failed, path == commitPath else { throw NativeSaveCommitError.invalidScope }
        let fresh = try SaveDirectory(absolute: parentURL.path)
        guard try parent.sameIdentity(as: fresh) else { throw NativeSaveCommitError.invalidScope }
        let committed = try pair(parent.directory(snapshotName))
        guard committed.0 == baselineSave, committed.1 == baselineSidecar else { throw NativeSaveCommitError.readback }
    }
    fileprivate func prepareUnadmitted(work: String, committed: String) throws {
        try validateMount(committed)
        guard work == workPath else { throw NativeSaveCommitError.invalidScope }
        let current = try pair(roots().0)
        guard current.0 == baselineSave, current.1 == baselineSidecar else { throw NativeSaveCommitError.noCompletion }
    }
    fileprivate func finishUnadmitted(committed: Bool) {
        if committed { do { try validateMount(commitPath) } catch { failed = true } }
    }
    fileprivate func accepted(_ candidate: PreparedCharacterSave) {
        baselineSave = candidate.saveBytes; baselineSidecar = candidate.sidecarBytes
    }
    fileprivate func fail() { failed = true }
}

/// Explicit receiver for one already admitted connection and isolated server
/// snapshot. Installing this does NOT perform admission, select DM_SAVE, start
/// the engine or upload progress. Default registry is empty and remains no-op.
public final class NativeSaveCommitCoordinator {
    public let generation: UInt64
    private let session: CharacterSaveCommitSession
    private let namespace: NativeServerSaveNamespace
    private let parent: SaveDirectory
    private let parentURL: URL
    private let snapshotName: String
    private let workPath: String, commitPath: String
    private let provider: (CharacterSaveMetadata) throws -> SaveTableLease
    private var completionObserved = false
    private var localCommits: UInt64 = 0
    private var failure: Int32 = 0

    public init(scope: LadderSaveScope, root: URL, snapshotDirectory: URL,
                session: CharacterSaveCommitSession,
                acquireTable: @escaping (CharacterSaveMetadata) throws -> SaveTableLease) throws {
        let parentURL = try scope.prepareDirectory(root: root)
        let directory = snapshotDirectory.standardizedFileURL
        let name = directory.lastPathComponent
        guard directory.isFileURL, directory.deletingLastPathComponent().path == parentURL.path,
              name.hasPrefix("snapshot-"), UUID(uuidString: String(name.dropFirst(9))) != nil else {
            throw NativeSaveCommitError.invalidScope
        }
        let parent = try SaveDirectory(absolute: parentURL.path)
        let committed = try parent.directory(name)
        let character = try committed.directory(session.characterName)
        let save = try character.read(session.characterName + ".d2s", maximum: 8 * 1024 * 1024)!
        let sidecar = try character.read(session.characterName + ".d2rl", maximum: CharacterSidecar.maximumPayload + 44, optional: true)
        try session.verifyCommittedSnapshot(save: save, sidecar: sidecar)
        namespace = NativeServerSaveNamespace(parent: parent, parentURL: parentURL, snapshotName: name,
            characterName: session.characterName, commitPath: directory.path, save: save, sidecar: sidecar)
        self.session = session; generation = session.generation; self.parent = parent
        self.parentURL = parentURL; snapshotName = name; commitPath = directory.path
        workPath = directory.path + ".work"; provider = acquireTable
    }

    public init(namespace: NativeServerSaveNamespace, session: CharacterSaveCommitSession,
                acquireTable: @escaping (CharacterSaveMetadata) throws -> SaveTableLease) throws {
        guard namespace.characterName == session.characterName else { throw NativeSaveCommitError.invalidScope }
        try namespace.validateMount(namespace.commitPath)
        let root = try namespace.parent.directory(namespace.snapshotName).directory(session.characterName)
        try session.verifyCommittedSnapshot(save: root.read(session.characterName + ".d2s", maximum: 8 * 1024 * 1024)!,
            sidecar: root.read(session.characterName + ".d2rl", maximum: CharacterSidecar.maximumPayload + 44, optional: true))
        self.namespace = namespace; self.session = session; generation = session.generation
        parent = namespace.parent; parentURL = namespace.parentURL; snapshotName = namespace.snapshotName
        workPath = namespace.workPath; commitPath = namespace.commitPath; provider = acquireTable
    }

    public func prepareNamespaceBeforeEngineStart() throws {
        try NativeServerSaveNamespace.prepareBeforeEngineStart(namespace)
    }

    public static func installAdmitted(_ coordinator: NativeSaveCommitCoordinator) throws {
        SaveRegistry.lock.lock(); defer { SaveRegistry.lock.unlock() }
        guard SaveRegistry.attempts.isEmpty, SaveRegistry.current == nil || SaveRegistry.current === coordinator else {
            throw NativeSaveCommitError.busy
        }
        guard SaveRegistry.namespace === coordinator.namespace,
              SaveRegistry.mountedRoot == nil || SaveRegistry.mountedRoot == coordinator.commitPath else {
            throw NativeSaveCommitError.invalidScope
        }
        SaveRegistry.current = coordinator
    }

    /// Caller must first stop/quiesce the remote engine and resolve its pending
    /// server progress. A running file commit holds this registry lease.
    public static func detach(generation: UInt64) throws {
        SaveRegistry.lock.lock(); defer { SaveRegistry.lock.unlock() }
        guard SaveRegistry.attempts.isEmpty else { throw NativeSaveCommitError.busy }
        guard let current = SaveRegistry.current, current.generation == generation else { throw NativeSaveCommitError.generation }
        current.session.invalidate(); SaveRegistry.current = nil
    }

    public func receive(_ message: ControlMessage, generation: UInt64) throws {
        SaveRegistry.lock.lock(); defer { SaveRegistry.lock.unlock() }
        guard SaveRegistry.attempts.isEmpty else { throw NativeSaveCommitError.busy }
        guard failure == 0, SaveRegistry.current === self else { throw NativeSaveCommitError.failed }
        try session.receive(message, generation: generation)
    }

    public var localCommitCount: UInt64 {
        SaveRegistry.lock.lock(); defer { SaveRegistry.lock.unlock() }; return localCommits
    }
    public var failureCode: Int32 {
        SaveRegistry.lock.lock(); defer { SaveRegistry.lock.unlock() }; return failure
    }

    private func roots() throws -> (work: SaveDirectory, committed: SaveDirectory) {
        // Detect replacement of the account/ladder parent; do not follow an
        // ancestor symlink into another namespace even on later transactions.
        let freshParent = try SaveDirectory(absolute: parentURL.path)
        guard try parent.sameIdentity(as: freshParent) else { throw NativeSaveCommitError.invalidScope }
        return try (parent.directory(snapshotName + ".work"), parent.directory(snapshotName))
    }
    private func readPair(_ root: SaveDirectory) throws -> (Data, Data?) {
        let character = try root.directory(session.characterName)
        return try (character.read(session.characterName + ".d2s", maximum: 8 * 1024 * 1024)!,
            character.read(session.characterName + ".d2rl", maximum: CharacterSidecar.maximumPayload + 44, optional: true))
    }

    fileprivate func begin(_ attempt: SaveCommitAttempt, work: String, committed: String) throws {
        guard failure == 0 else { throw NativeSaveCommitError.failed }
        guard work == workPath, committed == commitPath else { throw NativeSaveCommitError.invalidScope }
        session.beginFilesystemTransaction(); attempt.sessionLocked = true
        let roots = try roots()
        let prior = try readPair(roots.committed)
        try session.verifyCommittedSnapshot(save: prior.0, sidecar: prior.1)
        let current = try readPair(roots.work)
        guard let metadata = try session.matchingMetadata(for: current.0, generation: generation) else {
            try session.verifyCommittedSnapshot(save: current.0, sidecar: current.1)
            return
        }
        guard completionObserved else { throw NativeSaveCommitError.noCompletion }
        let lease = try provider(metadata); attempt.tables = lease
        let prepared = try session.prepare(current.0, generation: generation, table: lease.snapshot,
            timestamp: CharacterSidecar.historyTimestamp())
        guard let prepared else { throw NativeSaveCommitError.failed }
        attempt.candidate = prepared
        let character = try roots.work.directory(session.characterName)
        try character.writeAtomic(prepared.sidecarBytes, name: session.characterName + ".d2rl")
        let reread = try readPair(roots.work)
        guard reread.0 == prepared.saveBytes, reread.1 == prepared.sidecarBytes else { throw NativeSaveCommitError.readback }
    }

    fileprivate func finish(_ attempt: SaveCommitAttempt, committed: Bool) {
        defer {
            do { try attempt.tables?.release() } catch { failure = EIO }
            if attempt.sessionLocked { session.endFilesystemTransaction() }
        }
        guard attempt.sessionLocked else { return }
        do {
            if committed {
                let pair = try readPair(roots().committed)
                if let candidate = attempt.candidate {
                    guard pair.0 == candidate.saveBytes, pair.1 == candidate.sidecarBytes else { throw NativeSaveCommitError.readback }
                    try session.complete(candidate, generation: generation, committed: true)
                    namespace.accepted(candidate)
                    completionObserved = false; localCommits += 1
                } else { try session.verifyCommittedSnapshot(save: pair.0, sidecar: pair.1) }
            } else if let candidate = attempt.candidate {
                try session.complete(candidate, generation: generation, committed: false)
            }
        } catch { failure = EIO; namespace.fail(); session.invalidate() }
    }

    fileprivate func note(path: String, sequence: UInt64, reason: Int32) {
        guard failure == 0, sequence > 0, reason == 1 || reason == 2,
              path == workPath + "/" + session.characterName + "/" + session.characterName + ".d2s" else { return }
        completionObserved = true // Actual final bytes, not this order marker, select metadata.
    }
    fileprivate func staleGeneration() { failure = ESTALE; namespace.fail(); session.invalidate() }
}

private final class SaveCommitAttempt {
    let coordinator: NativeSaveCommitCoordinator?
    let namespace: NativeServerSaveNamespace?
    var sessionLocked = false
    var tables: SaveTableLease?
    var candidate: PreparedCharacterSave?
    init(_ coordinator: NativeSaveCommitCoordinator?, namespace: NativeServerSaveNamespace?) {
        self.coordinator = coordinator; self.namespace = namespace
    }
}
private enum SaveRegistry {
    static let lock = NSRecursiveLock()
    static var current: NativeSaveCommitCoordinator?
    static var namespace: NativeServerSaveNamespace?
    static var mountedRoot: String?
    static var hostStarted = false
    static var attempts: [SaveCommitAttempt] = []
}

@_cdecl("dm_online_d2s_completion_enabled")
public func nativeSaveCompletionEnabled() -> Int32 {
    SaveRegistry.lock.lock(); defer { SaveRegistry.lock.unlock() }
    return SaveRegistry.namespace == nil ? 0 : 1
}

@_cdecl("dm_online_save_isolated")
public func nativeSaveIsolated() -> Int32 { nativeSaveCompletionEnabled() }

@_cdecl("dm_online_save_mount_validate")
public func nativeSaveMountValidate(_ path: UnsafePointer<CChar>?) -> Int32 {
    SaveRegistry.lock.lock(); defer { SaveRegistry.lock.unlock() }
    guard let namespace = SaveRegistry.namespace else { return 0 }
    guard let path, let text = String(validatingCString: path) else { return EINVAL }
    do { try namespace.validateMount(text); return 0 } catch { return EACCES }
}

@_cdecl("dm_online_save_mounted")
public func nativeSaveMounted(_ path: UnsafePointer<CChar>?) {
    SaveRegistry.lock.lock(); defer { SaveRegistry.lock.unlock() }
    if let path, let text = String(validatingCString: path) { SaveRegistry.mountedRoot = text }
}

@_cdecl("dm_online_save_host_started")
public func nativeSaveHostStarted() {
    SaveRegistry.lock.lock(); defer { SaveRegistry.lock.unlock() }; SaveRegistry.hostStarted = true
}

@_cdecl("dm_online_d2s_completed")
public func nativeSaveCompleted(_ path: UnsafePointer<CChar>?, _ sequence: UInt64, _ reason: Int32) {
    guard let path, let text = String(validatingCString: path) else { return }
    SaveRegistry.lock.lock(); defer { SaveRegistry.lock.unlock() }
    SaveRegistry.current?.note(path: text, sequence: sequence, reason: reason)
}

@_cdecl("dm_online_save_prepare")
public func nativeSavePrepare(_ work: UnsafePointer<CChar>?, _ committed: UnsafePointer<CChar>?) -> Int32 {
    SaveRegistry.lock.lock() // Balanced by the C filesystem's same-thread finished callback.
    let attempt = SaveCommitAttempt(SaveRegistry.current, namespace: SaveRegistry.namespace); SaveRegistry.attempts.append(attempt)
    guard attempt.coordinator != nil || attempt.namespace != nil else { return 0 }
    guard let work, let committed, let w = String(validatingCString: work), let c = String(validatingCString: committed) else { return EINVAL }
    do {
        if let coordinator = attempt.coordinator { try coordinator.begin(attempt, work: w, committed: c) }
        else { try attempt.namespace?.prepareUnadmitted(work: w, committed: c) }
        return 0
    }
    catch SaveCommitSessionError.waitingForMetadata { return EAGAIN }
    catch NativeSaveCommitError.noCompletion { return EAGAIN }
    catch NativeSaveCommitError.generation { attempt.coordinator?.staleGeneration(); return ESTALE }
    catch let error as SaveIOError { return error.code }
    catch { return EIO }
}

@_cdecl("dm_online_save_finished")
public func nativeSaveFinished(_ work: UnsafePointer<CChar>?, _ committed: UnsafePointer<CChar>?, _ success: Int32) {
    // The native ABI requires exactly one finish on the prepare thread. It
    // must not be invoked manually from a network/main-thread callback.
    _ = work; _ = committed
    guard let attempt = SaveRegistry.attempts.popLast() else { return }
    if let coordinator = attempt.coordinator { coordinator.finish(attempt, committed: success != 0) }
    else { attempt.namespace?.finishUnadmitted(committed: success != 0) }
    SaveRegistry.lock.unlock()
}

private struct SaveIOError: Error { let code: Int32 }
private final class SaveDirectory {
    let fd: Int32
    private init(fd: Int32) { self.fd = fd }
    deinit { _ = Darwin.close(fd) }
    private static func component(_ text: String) throws {
        guard !text.isEmpty, text != ".", text != "..", !text.contains("/"), !text.utf8.contains(0) else { throw SaveIOError(code: EINVAL) }
    }
    convenience init(absolute path: String) throws {
        guard path.hasPrefix("/"), !path.utf8.contains(0) else { throw SaveIOError(code: EINVAL) }
        var current = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard current >= 0 else { throw SaveIOError(code: errno) }
        do {
            for part in path.split(separator: "/") {
                let name = String(part); try Self.component(name)
                let next = Darwin.openat(current, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard next >= 0 else { throw SaveIOError(code: errno) }
                _ = Darwin.close(current); current = next
            }
            self.init(fd: current)
        } catch { _ = Darwin.close(current); throw error }
    }
    func directory(_ name: String) throws -> SaveDirectory {
        try Self.component(name)
        let child = Darwin.openat(fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard child >= 0 else { throw SaveIOError(code: errno) }
        return SaveDirectory(fd: child)
    }
    func sameIdentity(as other: SaveDirectory) throws -> Bool {
        var a = stat(), b = stat()
        guard fstat(fd, &a) == 0, fstat(other.fd, &b) == 0 else { throw SaveIOError(code: errno) }
        return a.st_dev == b.st_dev && a.st_ino == b.st_ino
    }
    func read(_ name: String, maximum: Int, optional: Bool = false) throws -> Data? {
        try Self.component(name)
        let file = Darwin.openat(fd, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        if file < 0 { if optional && errno == ENOENT { return nil }; throw SaveIOError(code: errno) }
        defer { _ = Darwin.close(file) }
        var before = stat(), after = stat()
        guard fstat(file, &before) == 0 else { throw SaveIOError(code: errno) }
        guard before.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), before.st_nlink == 1,
              before.st_size >= 0, before.st_size <= maximum else { throw SaveIOError(code: EINVAL) }
        var bytes = Data(count: Int(before.st_size))
        try bytes.withUnsafeMutableBytes { raw in
            var done = 0
            while done < raw.count {
                let count = Darwin.pread(file, raw.baseAddress!.advanced(by: done), raw.count - done, off_t(done))
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw SaveIOError(code: count < 0 ? errno : EIO) }
                done += count
            }
        }
        guard fstat(file, &after) == 0 else { throw SaveIOError(code: errno) }
        guard before.st_dev == after.st_dev, before.st_ino == after.st_ino, before.st_size == after.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec, before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec, before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec else {
            throw SaveIOError(code: EAGAIN)
        }
        return bytes
    }
    func writeAtomic(_ bytes: Data, name: String) throws {
        try Self.component(name)
        var info = stat()
        if fstatat(fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0 {
            guard info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), info.st_nlink == 1 else { throw SaveIOError(code: EINVAL) }
        } else if errno != ENOENT { throw SaveIOError(code: errno) }
        let temporary = ".d2rl-tmp-" + UUID().uuidString
        var file = Darwin.openat(fd, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        guard file >= 0 else { throw SaveIOError(code: errno) }
        defer { if file >= 0 { _ = Darwin.close(file) }; _ = unlinkat(fd, temporary, 0) }
        try bytes.withUnsafeBytes { raw in
            var done = 0
            while done < raw.count {
                let count = Darwin.write(file, raw.baseAddress!.advanced(by: done), raw.count - done)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw SaveIOError(code: count < 0 ? errno : EIO) }
                done += count
            }
        }
        guard Darwin.fsync(file) == 0 else { throw SaveIOError(code: errno) }
        let result = Darwin.close(file); file = -1 // Never retry a possibly already-closed descriptor.
        guard result == 0 else { throw SaveIOError(code: errno) }
        guard renameat(fd, temporary, fd, name) == 0 else { throw SaveIOError(code: errno) }
    }
}
