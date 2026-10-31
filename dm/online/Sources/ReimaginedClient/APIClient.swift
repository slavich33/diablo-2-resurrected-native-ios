// 原生 HTTPS 客户端：公开赛季与策略读取，和真实 PKCE 授权码兑换。
// Native HTTPS client: public schedule/policy reads and genuine PKCE authorization-code exchange.
import Foundation

public enum ClientError: Error, Equatable {
    case invalidOrigin, invalidResponse, http(Int), oversizedResponse, policyChanged, scheduleMismatch
}

public protocol HTTPTransport {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

private final class NoRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

public final class SessionTransport: HTTPTransport {
    private let session = URLSession(configuration: .ephemeral, delegate: NoRedirects(), delegateQueue: nil)

    public init() {}
    deinit { session.invalidateAndCancel() }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (stream, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw ClientError.invalidResponse }
        guard response.expectedContentLength <= 8 * 1024 * 1024 else { throw ClientError.oversizedResponse }
        var bytes = Data()
        for try await byte in stream {
            guard bytes.count < 8 * 1024 * 1024 else { throw ClientError.oversizedResponse }
            bytes.append(byte)
        }
        return (bytes, http)
    }

}

public final class ReimaginedAPIClient {
    public static let production = URL(string: "https://api.d2r-reimagined.com/")!
    public let origin: URL
    private let transport: HTTPTransport

    public init(origin: URL = ReimaginedAPIClient.production, transport: HTTPTransport = SessionTransport()) throws {
        guard origin.scheme == "https", origin.host != nil, origin.user == nil, origin.password == nil,
              origin.query == nil, origin.fragment == nil, origin.path == "/" || origin.path.isEmpty else {
            throw ClientError.invalidOrigin
        }
        self.origin = origin
        self.transport = transport
    }

    public func schedule(accessToken: String? = nil) async throws -> LadderSchedule {
        let (bytes, _) = try await json(path: "ladders/schedule", token: accessToken)
        return try ReimaginedJSON.decoder().decode(LadderSchedule.self, from: bytes)
    }

    public func activeLadders(accessToken: String? = nil) async throws -> [LadderPolicy] {
        let (bytes, _) = try await json(path: "ladders/active", token: accessToken)
        return try ReimaginedJSON.decoder().decode([LadderPolicy].self, from: bytes)
    }

    public func regions(ladderID: UUID, accessToken: String? = nil) async throws -> [LobbyRegion] {
        let (bytes, _) = try await json(path: "lobby/ladders/\(ladderID.uuidString.lowercased())/regions", token: accessToken)
        return try ReimaginedJSON.decoder().decode([LobbyRegion].self, from: bytes)
    }

    /// Only the narrow game token may be handed to a future game/save adapter.
    /// No fallback to the launcher's long-lived token on older servers.
    public func createGameToken(session: LauncherSession, now: Date = Date()) async throws -> GameSessionToken? {
        let bytes: Data
        do { (bytes, _) = try await json(path: "auth/launcher/game-token", method: "POST", body: Data(), token: session.accessToken) }
        catch ClientError.http(404) { return nil }
        let result = try ReimaginedJSON.decoder().decode(GameSessionToken.self, from: bytes)
        guard Self.validSecret(result.accessToken), result.expiresAtUtc > now else { throw ClientError.invalidResponse }
        return result
    }

    public func revokeGameToken(_ token: GameSessionToken) async throws {
        _ = try await json(path: "auth/launcher/game-token/revoke", method: "POST", body: Data(), token: token.accessToken)
    }

    /// Read-only Server Saves metadata. Requires a narrow game token and a
    /// current ticket for this ladder. The launcher token is never a fallback.
    /// The response schema is statically observed, not live-native verified.
    public func serverSaveManifest(ladderID: UUID, gameToken: GameSessionToken,
                                   ticket: LadderLaunchTicket, now: Date = Date()) async throws -> ServerSaveManifest {
        guard ticket.ladderId == ladderID else { throw ServerSaveError.wrongLadder }
        guard gameToken.expiresAtUtc > now, ticket.expiresAtUtc > now,
              Self.validSecret(gameToken.accessToken), Self.validSecret(ticket.launchTicket) else {
            throw ServerSaveError.expiredSession
        }
        let (bytes, _) = try await json(path: "characters/saves", token: gameToken.accessToken,
            query: [URLQueryItem(name: "ladderId", value: ladderID.uuidString.lowercased())],
            launchTicket: ticket.launchTicket)
        let manifest = try ReimaginedJSON.decoder().decode(ServerSaveManifest.self, from: bytes)
        try manifest.validate()
        return manifest
    }

    /// Transport contract only: a returned ticket does not validate the bundle
    /// or admit the native engine. Call only after complete bundle validation.
    public func launchTicket(ladderID: UUID, bundle: LadderBundleDescriptor, launcherVersion: String,
                             session: LauncherSession, now: Date = Date()) async throws -> LadderLaunchTicket {
        guard bundle.ladderId == ladderID, bundle.revision > 0,
              bundle.artifactSha256.count == 64, bundle.artifactSha256.utf8.allSatisfy(Self.hexDigit),
              !launcherVersion.isEmpty, launcherVersion.utf8.count <= 64,
              launcherVersion.utf8.allSatisfy({ (33...126).contains($0) }) else { throw ClientError.invalidResponse }
        let body = try JSONSerialization.data(withJSONObject: [
            "bundleId": bundle.id.uuidString.lowercased(), "bundleRevision": bundle.revision,
            "launcherVersion": launcherVersion, "artifactSha256": bundle.artifactSha256
        ])
        let (bytes, _) = try await json(path: "ladders/\(ladderID.uuidString.lowercased())/launch-ticket", method: "POST", body: body, token: session.accessToken)
        let result = try ReimaginedJSON.decoder().decode(LadderLaunchTicket.self, from: bytes)
        guard result.ladderId == ladderID, result.bundleId == bundle.id, result.bundleRevision == bundle.revision,
              result.expiresAtUtc > now, Self.validSecret(result.launchTicket) else { throw ClientError.invalidResponse }
        return result
    }

    private static func validSecret(_ text: String) -> Bool {
        !text.isEmpty && text.utf8.count <= 16_384 && text.utf8.allSatisfy { (33...126).contains($0) }
    }

    private static func hexDigit(_ byte: UInt8) -> Bool {
        (48...57).contains(byte) || (65...70).contains(byte) || (97...102).contains(byte)
    }

    public func refresh(_ session: LauncherSession) async throws -> LauncherSession {
        let body = try JSONSerialization.data(withJSONObject: ["refreshToken": session.refreshToken])
        let (bytes, _) = try await json(path: "auth/launcher/refresh", method: "POST", body: body)
        return try ReimaginedJSON.decoder().decode(LauncherSession.self, from: bytes)
    }

    public func revoke(_ session: LauncherSession) async throws {
        let body = try JSONSerialization.data(withJSONObject: ["refreshToken": session.refreshToken])
        _ = try await json(path: "auth/launcher/revoke", method: "POST", body: body)
    }

    public func policy(for entry: LadderScheduleEntry, accessToken: String? = nil) async throws -> LadderPolicy {
        let (bytes, response) = try await json(path: "ladders/\(entry.id.uuidString.lowercased())/client-policy", token: accessToken)
        guard response.value(forHTTPHeaderField: "X-Ladder-Policy-Version") == entry.policyVersion else {
            throw ClientError.policyChanged
        }
        let policy = try ReimaginedJSON.decoder().decode(LadderPolicy.self, from: bytes)
        guard policy.id == entry.id, policy.startDateUtc == entry.startDateUtc, policy.endDateUtc == entry.endDateUtc else {
            throw ClientError.scheduleMismatch
        }
        return policy
    }

    public func exchange(authorization: PKCEAuthorization, callback: URL) async throws -> LauncherSession {
        let body = try authorization.tokenExchangeBody(callback: callback)
        let (bytes, _) = try await json(path: "auth/launcher/token", method: "POST", body: body)
        let result = try ReimaginedJSON.decoder().decode(LauncherSession.self, from: bytes)
        guard !result.accessToken.isEmpty, !result.refreshToken.isEmpty else { throw ClientError.invalidResponse }
        return result
    }

    private func json(path: String, method: String = "GET", body: Data? = nil, token: String? = nil,
                      query: [URLQueryItem] = [], launchTicket: String? = nil) async throws -> (Data, HTTPURLResponse) {
        var components = URLComponents(url: origin.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query }
        guard let url = components.url else { throw ClientError.invalidOrigin }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
        request.httpMethod = method
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-cache, no-store", forHTTPHeaderField: "Cache-Control")
        request.setValue("D2RMobile-Reimagined/0.1", forHTTPHeaderField: "User-Agent")
        if let body, !body.isEmpty { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let launchTicket { request.setValue(launchTicket, forHTTPHeaderField: "X-Ladder-Launch-Ticket") }
        let (bytes, response) = try await transport.send(request)
        guard (200..<300).contains(response.statusCode) else { throw ClientError.http(response.statusCode) }
        guard bytes.count <= 8 * 1024 * 1024 else { throw ClientError.oversizedResponse }
        return (bytes, response)
    }
}

public struct LauncherSession: Codable, CustomStringConvertible, CustomDebugStringConvertible {
    public let accessToken: String
    public let expiresAtUtc: Date
    public let refreshToken: String
    public let refreshExpiresAtUtc: Date
    public var description: String { "LauncherSession(<redacted>)" }
    public var debugDescription: String { description }
}
