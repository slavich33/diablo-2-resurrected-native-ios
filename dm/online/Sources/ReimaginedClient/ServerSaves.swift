import Foundation
import CryptoKit

public enum ServerSaveError: Error, Equatable {
    case expiredSession, wrongLadder, invalidManifest, invalidFile, sizeLimit, digestMismatch
}

/// Read-side contract observed in the Server Saves plugin. Live native access
/// still requires an accepted launch ticket; this is not a local-save importer.
public struct ServerSaveManifest: Decodable {
    public let serverAuthoritative: Bool
    public let files: [ServerSaveMetadata]

    public func validate() throws {
        guard files.count <= 1024 else { throw ServerSaveError.sizeLimit }
        var names = Set<String>()
        var total: Int64 = 0
        for file in files {
            try file.validate()
            // The Windows client treats names without regard to case. Refuse
            // collisions even on a case-sensitive APFS staging volume.
            guard names.insert(file.fileName.precomposedStringWithCanonicalMapping.lowercased()).inserted else {
                throw ServerSaveError.invalidManifest
            }
            total += file.byteCount
            guard total <= 128 * 1024 * 1024 else { throw ServerSaveError.sizeLimit }
        }
    }
}

public struct ServerSaveMetadata: Decodable {
    public let fileName: String
    public let characterName: String?
    public let sha256: String
    public let version: Int64
    public let byteCount: Int64
    public let corrupt: Bool?
    public let lastSavedAtUtc: Date?

    public func validate() throws {
        guard !fileName.isEmpty, fileName.utf8.count <= 128,
              !fileName.hasPrefix("."), !fileName.hasSuffix(" "),
              fileName.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }),
              !fileName.contains(where: { "/\\:<>\"|?*".contains($0) }),
              ["d2s", "d2i"].contains((fileName as NSString).pathExtension.lowercased()),
              !(fileName as NSString).deletingPathExtension.isEmpty,
              sha256.utf8.count == 64, sha256.utf8.allSatisfy({
                  (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0)
              }), version > 0, corrupt != true else { throw ServerSaveError.invalidFile }
        guard byteCount > 0, byteCount <= 16 * 1024 * 1024 else { throw ServerSaveError.sizeLimit }
    }
}

/// A digest-checked download, not proof that a Windows character is compatible
/// with the Switch engine's serializer. No download endpoint is guessed here.
public struct VerifiedServerSave {
    public let metadata: ServerSaveMetadata
    public let bytes: Data

    public init(metadata: ServerSaveMetadata, bytes: Data) throws {
        try metadata.validate()
        guard bytes.count == metadata.byteCount else { throw ServerSaveError.sizeLimit }
        let actual = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        guard actual == metadata.sha256.lowercased() else { throw ServerSaveError.digestMismatch }
        self.metadata = metadata
        self.bytes = bytes
    }
}

/// Commits an entire server snapshot into a new isolated generation. It never
/// activates DM_SAVE, modifies an existing generation, or uploads local bytes.
/// Files retain server names; engine-specific layout/serialization is separate.
public enum ServerSaveSnapshot {
    public static func stage(_ files: [VerifiedServerSave], manifest: ServerSaveManifest,
                             scope: LadderSaveScope, root: URL) throws -> URL {
        try manifest.validate()
        guard files.count == manifest.files.count else { throw ServerSaveError.invalidManifest }
        let expected = Dictionary(uniqueKeysWithValues: manifest.files.map { ($0.fileName, $0) })
        var seen = Set<String>()
        for file in files {
            guard let entry = expected[file.metadata.fileName], seen.insert(entry.fileName).inserted,
                  entry.version == file.metadata.version, entry.byteCount == file.metadata.byteCount,
                  entry.sha256.lowercased() == file.metadata.sha256.lowercased() else {
                throw ServerSaveError.invalidManifest
            }
        }
        let manager = FileManager.default
        let parent = try scope.prepareDirectory(root: root)
        let staging = parent.appendingPathComponent(".staging-" + UUID().uuidString, isDirectory: true)
        let committed = parent.appendingPathComponent("snapshot-" + UUID().uuidString, isDirectory: true)
        try manager.createDirectory(at: staging, withIntermediateDirectories: false,
                                    attributes: [.posixPermissions: 0o700])
        var moved = false
        defer { if !moved { try? manager.removeItem(at: staging) } }
        for file in files {
            let target = staging.appendingPathComponent(file.metadata.fileName, isDirectory: false)
            try file.bytes.write(to: target, options: [.withoutOverwriting])
            try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
        }
        // Same-parent rename makes a partial generation invisible to readers.
        try manager.moveItem(at: staging, to: committed)
        moved = true
        return committed
    }
}
