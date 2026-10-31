import Foundation
import CryptoKit
import Darwin

public enum RegistrationError: Error, Equatable {
    case invalidScope, invalidJournal, alreadyAttempted, receiptPending, invalidReceipt, characterExists, durabilityFailure
}

extension LauncherSession {
    /// A local namespace hint, NOT JWT authentication. The server must accept
    /// the actual bearer/ticket before any registration is attempted. Never
    /// use the rotating access token itself as a save-directory identifier.
    public func localSaveScope(origin: URL, ladderID: UUID) throws -> LadderSaveScope {
        let parts = accessToken.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[1].utf8.count <= 16_384 else { throw RegistrationError.invalidScope }
        var encoded = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        encoded += String(repeating: "=", count: (4 - encoded.count % 4) % 4)
        guard let data = Data(base64Encoded: encoded),
              let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let subject = (payload["sub"] ?? payload["http://schemas.xmlsoap.org/ws/2005/05/identity/claims/nameidentifier"]) as? String,
              !subject.isEmpty, subject.utf8.count <= 128,
              !subject.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw RegistrationError.invalidScope
        }
        return try LadderSaveScope(ladderID: ladderID, accountID: origin.absoluteString + "|" + subject)
    }
}

/// One immutable fresh-character request and durable attempt state. No token,
/// existing progress import, general save upload, retry or deletion API.
public final class NewCharacterJournal {
    public enum State: String, Codable { case prepared, attempted, confirmed }
    private struct Record: Codable {
        var format: Int
        var operationID: UUID
        var accountDigest: String
        var ladderID: UUID
        var bundleID: UUID
        var bundleRevision: Int
        var artifactSHA256: String
        var manifestSHA256: String
        var name: String
        var header: Data
        var body: Data
        var bodySHA256: String
        var state: State
        var postResponse: Data?
        var receiptResponse: Data?
        var serverVersion: Int64?
    }
    private var record: Record
    public let url: URL
    public var operationID: UUID { record.operationID }
    public var ladderID: UUID { record.ladderID }
    public var state: State { record.state }
    public var fileName: String { record.name + ".d2s" }
    public var fileSHA256: String { Self.digest(record.header) }
    public var headerBytes: Data { record.header }
    public var requestBody: Data { record.body }

    public init(header: NewCharacterHeader, scope: LadderSaveScope, package: VerifiedLadderPackage, root: URL) throws {
        guard scope.ladderID == package.ladderID else { throw RegistrationError.invalidScope }
        let parent = try scope.prepareDirectory(root: root).appendingPathComponent("new-characters", isDirectory: true)
        let manager = FileManager.default
        if manager.fileExists(atPath: parent.path) {
            guard try manager.attributesOfItem(atPath: parent.path)[.type] as? FileAttributeType == .typeDirectory else {
                throw RegistrationError.invalidJournal
            }
        } else { try manager.createDirectory(at: parent, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]) }
        let destination = parent.appendingPathComponent(header.characterName.lowercased() + ".json")
        url = destination
        let lockFD = try Self.acquireLock(destination)
        defer { flock(lockFD, LOCK_UN); Darwin.close(lockFD) }
        if manager.fileExists(atPath: destination.path) {
            let attributes = try manager.attributesOfItem(atPath: destination.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular,
                  ((attributes[.size] as? NSNumber)?.intValue ?? Int.max) <= 65_536 else { throw RegistrationError.invalidJournal }
            record = try JSONDecoder().decode(Record.self, from: Data(contentsOf: destination))
            guard record.format == 1, record.accountDigest == scope.accountDigest, record.ladderID == scope.ladderID,
                  record.name == header.characterName, record.header == header.bytes,
                  record.bundleRevision > 0, record.artifactSHA256.utf8.count == 64, record.manifestSHA256.utf8.count == 64,
                  record.bodySHA256 == Self.digest(record.body),
                  record.body == Self.body(operationID: record.operationID, bundleID: record.bundleID,
                      revision: record.bundleRevision, artifactSHA256: record.artifactSHA256, header: header) else {
                throw RegistrationError.invalidJournal
            }
        } else {
            let operation = UUID()
            let body = Self.body(operationID: operation, bundleID: package.bundleID, revision: package.revision,
                                 artifactSHA256: package.artifactSHA256, header: header)
            record = Record(format: 1, operationID: operation, accountDigest: scope.accountDigest, ladderID: package.ladderID,
                bundleID: package.bundleID, bundleRevision: package.revision, artifactSHA256: package.artifactSHA256,
                manifestSHA256: package.manifestSHA256, name: header.characterName, header: header.bytes,
                body: body, bodySHA256: Self.digest(body), state: .prepared)
            try persist()
        }
    }

    public func matches(_ package: VerifiedLadderPackage) -> Bool {
        record.ladderID == package.ladderID && record.bundleID == package.bundleID && record.bundleRevision == package.revision &&
            record.artifactSHA256 == package.artifactSHA256 && record.manifestSHA256 == package.manifestSHA256
    }

    /// Must complete durable state BEFORE the first network write. An unknown
    /// outcome stays attempted: subsequent callers may only read its receipt.
    func beginAttempt(package: VerifiedLadderPackage) throws {
        let fd = try Self.acquireLock(url)
        defer { flock(fd, LOCK_UN); Darwin.close(fd) }
        let disk = try JSONDecoder().decode(Record.self, from: Data(contentsOf: url))
        guard disk.operationID == record.operationID, disk.body == record.body, disk.header == record.header,
              disk.accountDigest == record.accountDigest else { throw RegistrationError.invalidJournal }
        guard disk.state == .prepared else { throw RegistrationError.alreadyAttempted }
        record = disk
        guard matches(package) else { throw ClientError.policyChanged }
        record.state = .attempted
        try persist()
    }

    func rememberPost(_ body: Data) throws {
        guard body.count <= 16_384 else { throw ServerSaveError.sizeLimit }
        record.postResponse = body; try persist()
    }
    func observeReceipt(_ body: Data) throws {
        guard body.count <= 16_384 else { throw ServerSaveError.sizeLimit }
        try ServerSaveWriteReceipt.decodeAndValidate(body, journal: self)
        if record.state == .prepared { record.state = .attempted }
        record.receiptResponse = body
        try persist()
    }
    func confirm(receipt: Data, metadata: ServerSaveMetadata, download: VerifiedServerSave) throws {
        guard record.state != .prepared, metadata.fileName.caseInsensitiveCompare(fileName) == .orderedSame,
              metadata.sha256.lowercased() == fileSHA256, download.bytes == record.header else {
            throw RegistrationError.invalidReceipt
        }
        guard receipt.count <= 16_384 else { throw ServerSaveError.sizeLimit }
        try ServerSaveWriteReceipt.decodeAndValidate(receipt, journal: self)
        record.receiptResponse = receipt; record.serverVersion = metadata.version; record.state = .confirmed
        try persist()
    }

    private func persist() throws {
        let data = try JSONEncoder().encode(record)
        guard data.count <= 65_536 else { throw ServerSaveError.sizeLimit }
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        // Atomic rename prevents partial records; fsync the file and parent
        // makes the operation/attempt marker durable before allowing HTTP.
        for path in [url.path, url.deletingLastPathComponent().path] {
            let fd = Darwin.open(path, O_RDONLY | O_NOFOLLOW)
            guard fd >= 0 else { throw RegistrationError.durabilityFailure }
            let status = fsync(fd); Darwin.close(fd)
            guard status == 0 else { throw RegistrationError.durabilityFailure }
        }
    }

    private static func acquireLock(_ url: URL) throws -> Int32 {
        let fd = Darwin.open(url.appendingPathExtension("lock").path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw RegistrationError.durabilityFailure }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            Darwin.close(fd); throw RegistrationError.alreadyAttempted
        }
        return fd
    }

    private static func body(operationID: UUID, bundleID: UUID, revision: Int,
                             artifactSHA256: String, header: NewCharacterHeader) -> Data {
        // Fresh registration intentionally omits expectedVersion. It never
        // sends journal/progress/deletion fields or an existing offline save.
        try! JSONSerialization.data(withJSONObject: [
            "bundleIdentity": "\(bundleID.uuidString.lowercased()):\(revision):\(artifactSHA256.lowercased())",
            "operationId": operationID.uuidString.lowercased(),
            "files": [["fileName": header.fileName, "contentBase64": header.bytes.base64EncodedString()]]
        ], options: [.sortedKeys, .withoutEscapingSlashes])
    }
    private static func digest(_ bytes: Data) -> String { SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() }
}

public struct NewCharacterRegistrationResult {
    public let operationID: UUID
    public let initialCharacter: VerifiedServerSave
    public let isolatedSnapshot: URL
    public let snapshotFileCount: Int
}

extension ReimaginedAPIClient {
    /// Creates only a fresh engine-generated header. Existing server characters
    /// are read, never overwritten. All downloads remain in a new isolated
    /// generation; this does not activate DM_SAVE or enter a game.
    public func registerNewCharacter(header: NewCharacterHeader, bundle: LadderBundleDescriptor,
                                     package: VerifiedLadderPackage, session: LauncherSession,
                                     root: URL) async throws -> NewCharacterRegistrationResult {
        let ticket = try await launchTicket(ladderID: bundle.ladderId, bundle: bundle,
                                            verifiedPackage: package, session: session)
        guard let token = try await createGameToken(session: session) else { throw LadderInspectionError.gameTokenUnavailable }
        let result: Result<NewCharacterRegistrationResult, Error>
        do {
            let before = try await serverSaveManifest(ladderID: bundle.ladderId, gameToken: token, ticket: ticket)
            guard before.serverAuthoritative else { throw RegistrationError.invalidScope }
            let scope = try session.localSaveScope(origin: origin, ladderID: bundle.ladderId)
            let journal = try NewCharacterJournal(header: header, scope: scope, package: package, root: root)
            var receipt = try await newCharacterReceipt(journal, gameToken: token, ticket: ticket)
            if receipt == nil {
                guard journal.state == .prepared else { throw RegistrationError.receiptPending }
                guard !before.files.contains(where: { $0.fileName.caseInsensitiveCompare(header.fileName) == .orderedSame }) else {
                    throw RegistrationError.characterExists
                }
                try Task.checkCancellation()
                _ = try await submitNewCharacter(journal, package: package, gameToken: token, ticket: ticket)
                receipt = try await newCharacterReceipt(journal, gameToken: token, ticket: ticket)
            }
            guard let receipt else { throw RegistrationError.receiptPending }
            try journal.observeReceipt(receipt)
            let manifest = try await serverSaveManifest(ladderID: bundle.ladderId, gameToken: token, ticket: ticket)
            guard manifest.serverAuthoritative,
                  let metadata = manifest.files.first(where: { $0.fileName.caseInsensitiveCompare(header.fileName) == .orderedSame }) else {
                throw RegistrationError.invalidReceipt
            }
            var files: [VerifiedServerSave] = []
            for entry in manifest.files {
                try Task.checkCancellation()
                files.append(try await downloadServerSave(entry, ladderID: bundle.ladderId, gameToken: token, ticket: ticket))
            }
            guard let character = files.first(where: { $0.metadata.fileName.caseInsensitiveCompare(header.fileName) == .orderedSame }) else {
                throw RegistrationError.invalidReceipt
            }
            try journal.confirm(receipt: receipt, metadata: metadata, download: character)
            let snapshot = try ServerSaveSnapshot.stage(files, manifest: manifest, scope: scope, root: root, layout: .switchVersion105)
            result = .success(NewCharacterRegistrationResult(operationID: journal.operationID, initialCharacter: character,
                isolatedSnapshot: snapshot, snapshotFileCount: files.count))
        } catch { result = .failure(error) }
        let cleanup = Task { try await self.revokeGameToken(token) }
        do { try await cleanup.value }
        catch { throw LadderInspectionError.tokenRevocationFailed }
        return try result.get()
    }
}

/// Static plugin contract pending independent live verification. The GET
/// receipt and downloaded save must both match before the journal is confirmed.
public struct ServerSaveWriteReceipt: Decodable {
    public struct Written: Decodable {
        public let fileName: String
        public let sha256: String
        public let version: Int64?
    }
    public let operationId: UUID?
    public let written: [Written]
    public let deleted: [String]?

    @discardableResult
    public static func decodeAndValidate(_ data: Data, journal: NewCharacterJournal) throws -> ServerSaveWriteReceipt {
        let result = try ReimaginedJSON.decoder().decode(Self.self, from: data)
        guard result.operationId == nil || result.operationId == journal.operationID,
              result.deleted?.isEmpty != false, result.written.count == 1,
              let file = result.written.first, file.fileName.caseInsensitiveCompare(journal.fileName) == .orderedSame,
              file.sha256.lowercased() == journal.fileSHA256, file.version == nil || file.version! > 0 else {
            throw RegistrationError.invalidReceipt
        }
        return result
    }
}
