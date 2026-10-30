import Foundation
import CryptoKit

public struct GameSessionToken: Decodable, CustomStringConvertible, CustomDebugStringConvertible {
    public let accessToken: String
    public let expiresAtUtc: Date
    public var description: String { "GameSessionToken(<redacted>)" }
    public var debugDescription: String { description }
}

public struct LadderLaunchTicket: Decodable, CustomStringConvertible, CustomDebugStringConvertible {
    public let launchTicket: String
    public let expiresAtUtc: Date
    public let ladderId: UUID
    public let bundleId: UUID
    public let bundleRevision: Int
    public var description: String { "LadderLaunchTicket(<redacted>)" }
    public var debugDescription: String { description }
}

public enum SaveScopeError: Error { case invalidRoot, invalidAccount, symbolicLink }

/// Local namespace for a future server-save adapter. Does not upload, import,
/// enumerate or move characters. Supply a stable authenticated account ID,
/// never an access/refresh token; token rotation must not change save paths.
public struct LadderSaveScope {
    public let ladderID: UUID
    public let accountDigest: String

    public init(ladderID: UUID, accountID: String) throws {
        guard !accountID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              accountID.utf8.count <= 256 else { throw SaveScopeError.invalidAccount }
        self.ladderID = ladderID
        accountDigest = SHA256.hash(data: Data(accountID.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    public func prepareDirectory(root: URL) throws -> URL {
        guard root.isFileURL else { throw SaveScopeError.invalidRoot }
        let manager = FileManager.default
        // root is supplied by the app, not by a server. Resolve OS aliases
        // such as /var -> /private/var, while refusing a symlink at root itself.
        if try Self.isSymlink(root) { throw SaveScopeError.symbolicLink }
        var directory = root.resolvingSymlinksInPath().standardizedFileURL
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        for component in ["ReimaginedOnline", ladderID.uuidString.lowercased(), accountDigest] {
            directory.appendPathComponent(component, isDirectory: true)
            if try Self.isSymlink(directory) { throw SaveScopeError.symbolicLink }
            try manager.createDirectory(at: directory, withIntermediateDirectories: true)
            if try Self.isSymlink(directory) { throw SaveScopeError.symbolicLink }
        }
        return directory
    }

    private static func isSymlink(_ url: URL) throws -> Bool {
        do { return try FileManager.default.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType == .typeSymbolicLink }
        catch CocoaError.fileReadNoSuchFile { return false }
    }
}
