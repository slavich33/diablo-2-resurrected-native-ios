import XCTest
import CryptoKit
@testable import ReimaginedClient

final class ServerSavesTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    private let bytes = Data("synthetic opaque save fixture, not game data".utf8)

    private func metadata(name: String = "Fixture.d2s", version: Int64 = 1) -> ServerSaveMetadata {
        ServerSaveMetadata(fileName: name, characterName: "Fixture",
            sha256: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined(),
            version: version, byteCount: Int64(bytes.count), corrupt: false, lastSavedAtUtc: nil)
    }

    private final class Transport: HTTPTransport {
        var requests: [URLRequest] = []
        var status = 200
        var body = Data("{\"serverAuthoritative\":true,\"files\":[]}".utf8)
        func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            requests.append(request)
            return (body, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
        }
    }

    func testManifestReadUsesNarrowCredentialsAndStopsOnRefusal() async throws {
        let ladder = UUID(), transport = Transport()
        let api = try ReimaginedAPIClient(transport: transport)
        let token = GameSessionToken(accessToken: "fixture-game-token", expiresAtUtc: now.addingTimeInterval(60))
        let ticket = LadderLaunchTicket(launchTicket: "fixture-ticket", expiresAtUtc: now.addingTimeInterval(60),
            ladderId: ladder, bundleId: UUID(), bundleRevision: 4)
        let manifest = try await api.serverSaveManifest(ladderID: ladder, gameToken: token, ticket: ticket, now: now)
        XCTAssertTrue(manifest.serverAuthoritative)
        let request = try XCTUnwrap(transport.requests.last)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertNil(request.httpBody)
        XCTAssertEqual(request.url?.path, "/characters/saves")
        XCTAssertEqual(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems,
            [URLQueryItem(name: "ladderId", value: ladder.uuidString.lowercased())])
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-game-token")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Ladder-Launch-Ticket"), "fixture-ticket")
        transport.status = 403
        do { _ = try await api.serverSaveManifest(ladderID: ladder, gameToken: token, ticket: ticket, now: now); XCTFail("Refused save accepted") }
        catch { XCTAssertEqual(error as? ClientError, .http(403)) }
        XCTAssertEqual(transport.requests.count, 2, "No credential substitution or automatic retry")
        do { _ = try await api.serverSaveManifest(ladderID: UUID(), gameToken: token, ticket: ticket, now: now); XCTFail("Wrong ladder accepted") }
        catch { XCTAssertEqual(error as? ServerSaveError, .wrongLadder) }
        do { _ = try await api.serverSaveManifest(ladderID: ladder, gameToken: token, ticket: ticket, now: now.addingTimeInterval(60)); XCTFail("Expired ticket accepted") }
        catch { XCTAssertEqual(error as? ServerSaveError, .expiredSession) }
        XCTAssertEqual(transport.requests.count, 2)
    }

    func testSnapshotReadbackAndFailedReplacementPreserveOfflineAndPreviousSnapshot() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let offline = root.appendingPathComponent("offline.d2s")
        let original = Data("independent offline bytes".utf8)
        try original.write(to: offline)
        let scope = try LadderSaveScope(ladderID: UUID(), accountID: "fixture-account")
        let entry = metadata(), verified = try VerifiedServerSave(metadata: entry, bytes: bytes)
        let manifest = ServerSaveManifest(serverAuthoritative: true, files: [entry])
        let first = try ServerSaveSnapshot.stage([verified], manifest: manifest, scope: scope, root: root)
        XCTAssertEqual(try Data(contentsOf: first.appendingPathComponent(entry.fileName)), bytes)
        XCTAssertEqual(try Data(contentsOf: offline), original)
        let newer = ServerSaveManifest(serverAuthoritative: true, files: [metadata(version: 2)])
        XCTAssertThrowsError(try ServerSaveSnapshot.stage([verified], manifest: newer, scope: scope, root: root))
        XCTAssertEqual(try Data(contentsOf: first.appendingPathComponent(entry.fileName)), bytes)
        XCTAssertEqual(try Data(contentsOf: offline), original)
        let parent = first.deletingLastPathComponent()
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: parent.path), [first.lastPathComponent])
        XCTAssertThrowsError(try VerifiedServerSave(metadata: entry, bytes: Data(repeating: 0, count: bytes.count)))
        XCTAssertThrowsError(try VerifiedServerSave(metadata: entry, bytes: bytes + Data([0])))
    }

    func testUntrustedNamesAndCaseCollisionsAreRejectedBeforeFilesystemWrites() throws {
        for name in ["../escape.d2s", "sub/name.d2s", "sub\\name.d2s", "C:save.d2s", ".hidden.d2s", "file.d2s ", "file\n.d2s", "file.txt", "file.d2s/other"] {
            XCTAssertThrowsError(try metadata(name: name).validate(), name)
        }
        let collision = ServerSaveManifest(serverAuthoritative: true, files: [metadata(), metadata(name: "fixture.D2S")])
        XCTAssertThrowsError(try collision.validate())
        // Authority is mandatory: do not default an absent/changed field to a
        // mode that would permit uploads. This client contains no upload API.
        XCTAssertThrowsError(try ReimaginedJSON.decoder().decode(ServerSaveManifest.self, from: Data("{\"files\":[]}".utf8)))
    }
}
