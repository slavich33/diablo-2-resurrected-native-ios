// 来自公开启动器的 JSON 字段约定；没有游戏内容或账户信息。
// JSON field contracts from the public launcher; no game content or account information.
import Foundation

public struct LadderSchedule: Decodable {
    public let serverTimeUtc: Date
    public let ladders: [LadderScheduleEntry]
}

public struct LadderScheduleEntry: Decodable {
    public let id: UUID
    public let name: String
    public let startDateUtc: Date
    public let endDateUtc: Date
    public let policyVersion: String
    public let isLive: Bool
}

public struct LadderPolicy: Decodable {
    public let id: UUID
    public let name: String
    public let startDateUtc: Date
    public let endDateUtc: Date
    public let activeBundle: LadderBundleDescriptor?
}

public struct LadderBundleDescriptor: Decodable {
    public let id: UUID
    public let ladderId: UUID
    public let revision: Int
    public let schemaVersion: Int
    public let status: String
    public let artifactSha256: String
    public let manifestSha256: String
    public let manifestSignature: String
    public let signingKeyId: String
    public let artifactSizeBytes: Int64
    public let compatibility: BundleCompatibility
    public let downloadPath: String
}

public struct BundleCompatibility: Decodable {
    public let minimumLauncherVersion: String
    public let requiredD2RLoaderVersion: String
    public let requiredD2RLoaderSha256: String
    public let requiredD2RCoreSha256: String
    public let requiredModVersion: String
    public let supportedGameVersion: String
}

public struct LobbyRegion: Decodable, Equatable {
    public let id: String
    public let name: String
    public let available: Bool
    public let pingTargets: [String]?

    enum CodingKeys: String, CodingKey {
        case id, name, available
        case pingTargets = "ping_targets"
    }
}

public enum ReimaginedJSON {
    public static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { value in
            let text = try value.singleValueContainer().decode(String.self)
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let plain = ISO8601DateFormatter()
            guard let date = fractional.date(from: text) ?? plain.date(from: text) else {
                throw DecodingError.dataCorrupted(.init(codingPath: value.codingPath, debugDescription: "Invalid server date"))
            }
            return date
        }
        return decoder
    }
}
