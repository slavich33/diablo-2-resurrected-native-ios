import Foundation

public enum GameLobbyError: Error, Equatable {
    case wrongLadder, expiredSession, invalidGameID, invalidResponse
}

/// Only the advertised level restriction, never game or account admission.
public enum LobbyLevelCompatibility: Equatable {
    case allowed, outsideRange, unverified
}

/// Read-only player lobby metadata. These summaries describe the server's
/// environment; they are never used as evidence of the native client's own
/// compatibility or copied into an admission manifest.
public struct LobbyEnvironmentSummary: Decodable, Equatable {
    public struct Group: Decodable, Equatable {
        public let id: String
        public let policyVersion: UInt16
        public let componentCount: UInt32
        public let coverage: String
        public let sha256: String
        enum CodingKeys: String, CodingKey {
            case id, coverage, sha256
            case policyVersion = "policy_version", componentCount = "component_count"
        }
    }
    public struct SharedPlugin: Decodable, Equatable {
        public let id: String
        public let scope: String
        public let sha256: String
    }
    public let policyVersion: UInt16
    public let componentCount: UInt32
    public let coverage: String
    public let sha256: String
    public let groups: [Group]
    public let sharedPlugins: [SharedPlugin]
    enum CodingKeys: String, CodingKey {
        case coverage, sha256, groups
        case policyVersion = "policy_version", componentCount = "component_count", sharedPlugins = "shared_plugins"
    }

    fileprivate func validate() throws {
        // This is metadata validation, not the D2EM compatibility algorithm.
        guard Self.digest(sha256), Self.text(coverage, limit: 32),
              groups.count <= 32, sharedPlugins.count <= 256,
              Set(groups.map(\.id)).count == groups.count,
              Set(sharedPlugins.map(\.id)).count == sharedPlugins.count,
              groups.allSatisfy({ Self.text($0.id, limit: 128) && Self.text($0.coverage, limit: 32) && Self.digest($0.sha256) }),
              sharedPlugins.allSatisfy({ Self.text($0.id, limit: 256) && Self.text($0.scope, limit: 64) && Self.digest($0.sha256) })
        else { throw GameLobbyError.invalidResponse }
    }

    private static func digest(_ value: String) -> Bool {
        value.isEmpty || (value.utf8.count == 64 && value.utf8.allSatisfy {
            (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0)
        })
    }
    private static func text(_ value: String, limit: Int) -> Bool {
        !value.isEmpty && value.utf8.count <= limit && !value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }
}

public struct LobbyGameList: Decodable, Equatable {
    public let games: [LobbyGame]
    public let totalPlayers: Int

    public func validate() throws {
        guard totalPlayers >= 0, games.count <= 8192,
              Set(games.map(\.gameID)).count == games.count else { throw GameLobbyError.invalidResponse }
        for game in games { try game.validate() }
    }
}

public struct LobbyGame: Decodable, Equatable {
    public struct Player: Decodable, Equatable {
        public let name: String
        public let level: UInt16
        public let characterClass: String
        enum CodingKeys: String, CodingKey { case name, level; case characterClass = "class" }
    }
    public let gameID: String
    public let name: String
    public let description: String
    public let difficulty: String
    public let gameMode: String
    public let gameVersion: String
    public let loaderVersion: String
    public let modIdentity: String
    public let modVersion: String
    public let type: String
    public let hardcore: Bool
    public let levelDifferenceEnabled: Bool?
    public let levelDifference: UInt16?
    public let rejectsCheatedCharacters: Bool?
    public let passwordRequired: Bool
    public let maxPlayers: UInt16
    public let players: [Player]
    public let regionIDs: [String]
    public let environment: LobbyEnvironmentSummary

    enum CodingKeys: String, CodingKey {
        case name, description, difficulty, type, hardcore, players
        case gameID = "game_id", gameMode = "game_mode", gameVersion = "game_version", loaderVersion = "loader_version"
        case modIdentity = "mod_identity", modVersion = "mod_version", passwordRequired = "password_required"
        case maxPlayers = "max_players", regionIDs = "region_ids", environment = "environment_fingerprint"
        case levelDifferenceEnabled = "level_difference_enabled", levelDifference = "level_difference"
        case rejectsCheatedCharacters = "rejects_cheated_characters"
    }

    public static func isValidID(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 128 && value.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95
        }
    }

    fileprivate func validate() throws {
        guard Self.isValidID(gameID), name.utf8.count <= 1024, description.utf8.count <= 16_384,
              maxPlayers > 0, players.count <= 256, regionIDs.count <= 64,
              players.allSatisfy({ $0.name.utf8.count <= 1024 && $0.characterClass.utf8.count <= 128 }),
              regionIDs.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 128 }) else { throw GameLobbyError.invalidResponse }
        try environment.validate()
    }
}

/// An address/port and the game number chosen by the player lobby. Resolving
/// one does not connect, create a character, mount saves or admit the engine.
public struct ResolvedLobbyGame: Decodable, Equatable {
    public let address: String
    public let port: UInt16
    public let gameNumber: UInt16
    public let difficulty: String
    public let gameMode: String
    public let hardcore: Bool
    public let hostLevel: UInt16?
    public let levelDifferenceEnabled: Bool?
    public let levelDifference: UInt16?
    public let type: String
    public let modIdentity: String
    public let environment: LobbyEnvironmentSummary
    enum CodingKeys: String, CodingKey {
        case address, port, difficulty, hardcore, type
        case gameNumber = "game_number", gameMode = "game_mode", modIdentity = "mod_identity", environment = "environment_fingerprint"
        case hostLevel = "host_level", levelDifferenceEnabled = "level_difference_enabled", levelDifference = "level_difference"
    }

    /// The current original engine startup field has 24 bytes including NUL.
    /// Do not truncate a longer DNS name to make it fit.
    public var fitsOriginalEngineAddress: Bool { address.utf8.count < 24 }

    /// Supply the actual selected character's level. Missing restriction data
    /// stays unknown; it must not silently become an unrestricted room.
    public func levelCompatibility(characterLevel: UInt16) -> LobbyLevelCompatibility {
        guard characterLevel > 0, let enabled = levelDifferenceEnabled else { return .unverified }
        guard enabled else { return .allowed }
        guard let maximum = levelDifference, let host = hostLevel, host > 0 else { return .unverified }
        return abs(Int(characterLevel) - Int(host)) <= Int(maximum) ? .allowed : .outsideRange
    }

    public func validate() throws {
        guard !address.isEmpty, address.utf8.count <= 253,
              address.utf8.allSatisfy({ (33...126).contains($0) && !"/@?#\\".utf8.contains($0) }),
              port != 0, gameNumber != 0 else { throw GameLobbyError.invalidResponse }
        try environment.validate()
    }
}
