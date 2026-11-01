import XCTest
@testable import ReimaginedClient

final class GameLobbyTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    private final class Transport: HTTPTransport {
        var requests: [URLRequest] = []
        var body = Data()
        var status = 200
        func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            requests.append(request)
            return (body, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
        }
    }
    private var environment: [String: Any] {
        ["policy_version": 4, "component_count": 1, "coverage": "complete", "sha256": String(repeating: "a", count: 64),
         "groups": [["id": "contract", "policy_version": 4, "component_count": 1, "coverage": "complete", "sha256": String(repeating: "b", count: 64)]],
         "shared_plugins": [["id": "fixture-plugin", "scope": "Shared", "sha256": String(repeating: "c", count: 64)]], "shared_patches": []]
    }
    private var listing: [String: Any] {
        ["game_id": "fixture-1", "name": "Synthetic room", "description": "Synthetic metadata, no game/player data",
         "difficulty": "Normal", "game_mode": "Expansion", "game_version": "3.3.0", "loader_version": "1.3.1-beta",
         "mod_identity": "fixture-mod", "mod_version": "1.0", "type": "Modded", "hardcore": false,
         "password_required": false, "max_players": 8, "players": [["name": "Fixture", "level": 1, "class": "Amazon"]],
         "region_ids": ["fixture-region"], "environment_fingerprint": environment]
    }
    private var resolved: [String: Any] {
        ["address": "127.0.0.1", "port": 4000, "game_number": 42, "difficulty": "Normal", "game_mode": "Expansion",
         "hardcore": false, "type": "Modded", "mod_identity": "fixture-mod", "environment_fingerprint": environment]
    }
    private func credentials(_ ladder: UUID) -> (GameSessionToken, LadderLaunchTicket) {
        (GameSessionToken(accessToken: "fixture-narrow-token", expiresAtUtc: now.addingTimeInterval(60)),
         LadderLaunchTicket(launchTicket: "fixture-ticket", expiresAtUtc: now.addingTimeInterval(60), ladderId: ladder,
                            bundleId: UUID(), bundleRevision: 5))
    }
    private func bytes(_ value: Any) throws -> Data { try JSONSerialization.data(withJSONObject: value) }

    func testPlayerListAndResolveUseNarrowTicketScopedGETs() async throws {
        let transport = Transport(), ladder = UUID()
        let api = try ReimaginedAPIClient(transport: transport)
        let (token, ticket) = credentials(ladder)
        transport.body = try bytes(["games": [listing], "totalPlayers": 1])
        let list = try await api.lobbyGames(ladderID: ladder, gameToken: token, ticket: ticket, now: now)
        XCTAssertEqual(list.totalPlayers, 1)
        XCTAssertEqual(list.games.first?.players.first?.characterClass, "Amazon")
        XCTAssertEqual(list.games.first?.environment.groups.first?.componentCount, 1)
        let base = "/lobby/ladders/\(ladder.uuidString.lowercased())/v2/games"
        XCTAssertEqual(transport.requests.last?.url?.path, base)
        transport.body = try bytes(resolved)
        let game = try await api.resolveLobbyGame(gameID: list.games[0].gameID, ladderID: ladder, gameToken: token, ticket: ticket, now: now)
        XCTAssertEqual(game.gameNumber, 42)
        XCTAssertTrue(game.fitsOriginalEngineAddress)
        XCTAssertEqual(transport.requests.last?.url?.path, base + "/fixture-1/resolve")
        for request in transport.requests {
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertNil(request.httpBody)
            XCTAssertNil(request.url?.query)
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-narrow-token")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Ladder-Launch-Ticket"), "fixture-ticket")
            XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), api.identity.userAgent)
        }
    }

    func testInvalidScopeExpiredSessionAndPathInjectionSendNoRequest() async throws {
        let transport = Transport(), ladder = UUID()
        let api = try ReimaginedAPIClient(transport: transport)
        let (token, ticket) = credentials(ladder)
        for id in ["", "..", "a/b", "%2f", "a?x", "a#x", "a\\b", String(repeating: "a", count: 129)] {
            do { _ = try await api.resolveLobbyGame(gameID: id, ladderID: ladder, gameToken: token, ticket: ticket, now: now); XCTFail(id) }
            catch { XCTAssertEqual(error as? GameLobbyError, .invalidGameID) }
        }
        do { _ = try await api.lobbyGames(ladderID: UUID(), gameToken: token, ticket: ticket, now: now); XCTFail() }
        catch { XCTAssertEqual(error as? GameLobbyError, .wrongLadder) }
        do { _ = try await api.lobbyGames(ladderID: ladder, gameToken: token, ticket: ticket, now: now.addingTimeInterval(60)); XCTFail() }
        catch { XCTAssertEqual(error as? GameLobbyError, .expiredSession) }
        XCTAssertTrue(transport.requests.isEmpty)
    }

    func testRefusalIsNotRetriedAndResolutionCannotBecomeAnHTTPURL() async throws {
        let transport = Transport(), ladder = UUID()
        let api = try ReimaginedAPIClient(transport: transport)
        let (token, ticket) = credentials(ladder)
        transport.status = 403
        do { _ = try await api.lobbyGames(ladderID: ladder, gameToken: token, ticket: ticket, now: now); XCTFail() }
        catch { XCTAssertEqual(error as? ClientError, .http(403)) }
        XCTAssertEqual(transport.requests.count, 1)
        for address in ["", "https://example.test", "user@host", "a\nb", "a/b", String(repeating: "a", count: 254)] {
            var object = resolved; object["address"] = address
            let game = try ReimaginedJSON.decoder().decode(ResolvedLobbyGame.self, from: bytes(object))
            XCTAssertThrowsError(try game.validate(), address)
        }
        for key in ["port", "game_number"] {
            var object = resolved; object[key] = 65_536
            XCTAssertThrowsError(try ReimaginedJSON.decoder().decode(ResolvedLobbyGame.self, from: bytes(object)))
            object[key] = 0
            XCTAssertThrowsError(try ReimaginedJSON.decoder().decode(ResolvedLobbyGame.self, from: bytes(object)).validate())
        }
        var object = resolved; object["address"] = "long-subdomain.example.test"
        let game = try ReimaginedJSON.decoder().decode(ResolvedLobbyGame.self, from: bytes(object))
        try game.validate()
        XCTAssertFalse(game.fitsOriginalEngineAddress, "Valid transport hostname must not be truncated to fit the engine")
    }

    func testContradictoryMetadataIsNotPassedToTheCaller() throws {
        for (games, count) in [([listing, listing], 2), ([listing], -1)] {
            let list = try ReimaginedJSON.decoder().decode(LobbyGameList.self, from: bytes(["games": games, "totalPlayers": count]))
            XCTAssertThrowsError(try list.validate())
        }
        var badEnvironment = environment
        let groups = try XCTUnwrap(environment["groups"] as? [[String: Any]])
        badEnvironment["groups"] = groups + groups
        var game = listing; game["environment_fingerprint"] = badEnvironment
        var list = try ReimaginedJSON.decoder().decode(LobbyGameList.self, from: bytes(["games": [game], "totalPlayers": 1]))
        XCTAssertThrowsError(try list.validate())
        badEnvironment = environment; badEnvironment["sha256"] = "not-a-digest"
        game["environment_fingerprint"] = badEnvironment
        list = try ReimaginedJSON.decoder().decode(LobbyGameList.self, from: bytes(["games": [game], "totalPlayers": 1]))
        XCTAssertThrowsError(try list.validate())
    }

    func testCurrentRoomRestrictionFieldsAreRetained() throws {
        var room = listing
        room["level_difference_enabled"] = true
        room["level_difference"] = 10
        room["rejects_cheated_characters"] = true
        let list = try ReimaginedJSON.decoder().decode(LobbyGameList.self, from: bytes(["games": [room], "totalPlayers": 1]))
        try list.validate()
        XCTAssertEqual(list.games[0].levelDifferenceEnabled, true)
        XCTAssertEqual(list.games[0].levelDifference, 10)
        XCTAssertEqual(list.games[0].rejectsCheatedCharacters, true)

        var endpoint = resolved
        endpoint["level_difference_enabled"] = true
        endpoint["level_difference"] = 10
        endpoint["host_level"] = 50
        let game = try ReimaginedJSON.decoder().decode(ResolvedLobbyGame.self, from: bytes(endpoint))
        try game.validate()
        XCTAssertEqual(game.hostLevel, 50)
        for level in [40, 50, 60] as [UInt16] { XCTAssertEqual(game.levelCompatibility(characterLevel: level), .allowed) }
        for level in [1, 39, 61, 1_023] as [UInt16] { XCTAssertEqual(game.levelCompatibility(characterLevel: level), .outsideRange) }
    }

    func testMissingAndDisabledRestrictionsStayDistinct() throws {
        let oldResponse = try ReimaginedJSON.decoder().decode(ResolvedLobbyGame.self, from: bytes(resolved))
        XCTAssertEqual(oldResponse.levelCompatibility(characterLevel: 1), .unverified)
        let incomplete: [[String: Any]] = [
            ["level_difference_enabled": true],
            ["level_difference_enabled": true, "host_level": 50],
            ["level_difference_enabled": true, "host_level": 0, "level_difference": 10]
        ]
        for fields in incomplete {
            let game = try ReimaginedJSON.decoder().decode(ResolvedLobbyGame.self, from: bytes(resolved.merging(fields) { _, new in new }))
            XCTAssertEqual(game.levelCompatibility(characterLevel: 1), .unverified)
        }
        var endpoint = resolved
        endpoint["level_difference_enabled"] = false
        let game = try ReimaginedJSON.decoder().decode(ResolvedLobbyGame.self, from: bytes(endpoint))
        XCTAssertEqual(game.levelCompatibility(characterLevel: 1), .allowed)
        XCTAssertEqual(game.levelCompatibility(characterLevel: 0), .unverified)
    }

    func testLevelRestrictionBoundsDoNotWrapOrCoerceMalformedFields() throws {
        var endpoint = resolved
        endpoint["level_difference_enabled"] = true
        endpoint["level_difference"] = 65_534
        endpoint["host_level"] = 1
        var game = try ReimaginedJSON.decoder().decode(ResolvedLobbyGame.self, from: bytes(endpoint))
        XCTAssertEqual(game.levelCompatibility(characterLevel: .max), .allowed)
        endpoint["level_difference"] = 65_533
        game = try ReimaginedJSON.decoder().decode(ResolvedLobbyGame.self, from: bytes(endpoint))
        XCTAssertEqual(game.levelCompatibility(characterLevel: .max), .outsideRange)
        for key in ["host_level", "level_difference"] {
            for value in [-1, 65_536, 1.5, "1"] as [Any] {
                var malformed = endpoint; malformed[key] = value
                XCTAssertThrowsError(try ReimaginedJSON.decoder().decode(ResolvedLobbyGame.self, from: bytes(malformed)))
            }
        }
        var malformed = endpoint; malformed["level_difference_enabled"] = "false"
        XCTAssertThrowsError(try ReimaginedJSON.decoder().decode(ResolvedLobbyGame.self, from: bytes(malformed)))
    }
}
