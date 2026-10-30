import XCTest
@testable import ReimaginedClient

final class GameSessionTests: XCTestCase {
    private final class Transport: HTTPTransport {
        var status = 200
        var bytes = Data()
        var requests: [URLRequest] = []
        func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            requests.append(request)
            return (bytes, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
        }
    }
    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    private func session() throws -> LauncherSession {
        try ReimaginedJSON.decoder().decode(LauncherSession.self, from: Data("{\"accessToken\":\"test-launcher\",\"refreshToken\":\"test-refresh\",\"expiresAtUtc\":\"2027-01-01T00:00:00Z\",\"refreshExpiresAtUtc\":\"2027-02-01T00:00:00Z\"}".utf8))
    }

    func testNarrowGameTokenIsMintedAndRevokedWithoutExposingLauncherToken() async throws {
        let transport = Transport(), saved = try session()
        let api = try ReimaginedAPIClient(transport: transport)
        transport.bytes = Data("{\"accessToken\":\"test-game-only\",\"expiresAtUtc\":\"2027-01-01T00:00:00Z\"}".utf8)
        let minted = try await api.createGameToken(session: saved, now: now)
        let token = try XCTUnwrap(minted)
        XCTAssertFalse(String(reflecting: token).contains("test-game-only"))
        XCTAssertEqual(transport.requests.last?.url?.path, "/auth/launcher/game-token")
        XCTAssertEqual(transport.requests.last?.value(forHTTPHeaderField: "Authorization"), "Bearer test-launcher")
        XCTAssertEqual(transport.requests.last?.httpBody?.count, 0)
        XCTAssertNil(transport.requests.last?.value(forHTTPHeaderField: "Content-Type"))
        transport.status = 204; transport.bytes = Data()
        try await api.revokeGameToken(token)
        XCTAssertEqual(transport.requests.last?.url?.path, "/auth/launcher/game-token/revoke")
        XCTAssertEqual(transport.requests.last?.value(forHTTPHeaderField: "Authorization"), "Bearer test-game-only")
    }

    func testMissingEndpointDoesNotFallbackAndExpiredGameTokenIsRejected() async throws {
        let transport = Transport(), saved = try session()
        let api = try ReimaginedAPIClient(transport: transport)
        transport.status = 404
        let missing = try await api.createGameToken(session: saved, now: now)
        XCTAssertNil(missing); XCTAssertEqual(transport.requests.count, 1)
        transport.status = 403
        do { _ = try await api.createGameToken(session: saved, now: now); XCTFail("403 accepted") }
        catch { XCTAssertEqual(error as? ClientError, .http(403)) }
        transport.status = 200
        for payload in [
            "{\"accessToken\":\"test-expired\",\"expiresAtUtc\":\"2020-01-01T00:00:00Z\"}",
            "{\"accessToken\":\"\",\"expiresAtUtc\":\"2027-01-01T00:00:00Z\"}"
        ] {
            transport.bytes = Data(payload.utf8)
            do { _ = try await api.createGameToken(session: saved, now: now); XCTFail("invalid token accepted") }
            catch { XCTAssertEqual(error as? ClientError, .invalidResponse) }
        }
    }

    func testLaunchTicketUsesExactBundleIdentityAndRejectsMismatchedResponse() async throws {
        let transport = Transport(), saved = try session()
        let api = try ReimaginedAPIClient(transport: transport)
        let ladder = UUID(), bundleID = UUID()
        let bundle = LadderBundleDescriptor(id: bundleID, ladderId: ladder, revision: 3, schemaVersion: 1, status: "Published",
            artifactSha256: String(repeating: "a", count: 64), manifestSha256: String(repeating: "b", count: 64),
            manifestSignature: "test-signature", signingKeyId: "test-key", artifactSizeBytes: 100,
            compatibility: BundleCompatibility(minimumLauncherVersion: "0.1.0", requiredD2RLoaderVersion: "test", requiredD2RLoaderSha256: "test", requiredD2RCoreSha256: "test", requiredModVersion: "test", supportedGameVersion: "test"), downloadPath: "/test")
        func response(revision: Int) -> Data {
            Data("{\"launchTicket\":\"test-ticket\",\"expiresAtUtc\":\"2027-01-01T00:00:00Z\",\"ladderId\":\"\(ladder)\",\"bundleId\":\"\(bundleID)\",\"bundleRevision\":\(revision)}".utf8)
        }
        transport.bytes = response(revision: 3)
        let ticket = try await api.launchTicket(ladderID: ladder, bundle: bundle, launcherVersion: "0.1.0", session: saved, now: now)
        XCTAssertFalse(String(reflecting: ticket).contains("test-ticket"))
        let request = try XCTUnwrap(transport.requests.last)
        XCTAssertEqual(request.url?.path, "/ladders/\(ladder.uuidString.lowercased())/launch-ticket")
        let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
        XCTAssertEqual(body["bundleId"] as? String, bundleID.uuidString.lowercased())
        XCTAssertEqual(body["bundleRevision"] as? Int, 3)
        XCTAssertEqual(body["artifactSha256"] as? String, bundle.artifactSha256)
        transport.bytes = response(revision: 4)
        do { _ = try await api.launchTicket(ladderID: ladder, bundle: bundle, launcherVersion: "0.1.0", session: saved, now: now); XCTFail("wrong bundle revision accepted") }
        catch { XCTAssertEqual(error as? ClientError, .invalidResponse) }
    }

    func testSaveScopesSeparateAccountsAndLaddersWithoutMovingOfflineData() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let offline = root.appendingPathComponent("offline-fixture.d2s")
        let original = Data("offline-test-fixture".utf8)
        try original.write(to: offline)
        let ladder = UUID()
        let scope = try LadderSaveScope(ladderID: ladder, accountID: "account-one")
        let first = try scope.prepareDirectory(root: root)
        XCTAssertEqual(try scope.prepareDirectory(root: root), first)
        XCTAssertNotEqual(try LadderSaveScope(ladderID: ladder, accountID: "account-two").prepareDirectory(root: root), first)
        XCTAssertNotEqual(try LadderSaveScope(ladderID: UUID(), accountID: "account-one").prepareDirectory(root: root), first)
        XCTAssertFalse(first.path.contains("account-one"))
        XCTAssertEqual(try Data(contentsOf: offline), original)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: first.path), [])
        let external = root.appendingPathComponent("redirect-target", isDirectory: true)
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: false)
        let another = root.appendingPathComponent("another-root", isDirectory: true)
        try FileManager.default.createDirectory(at: another, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: another.appendingPathComponent("ReimaginedOnline"), withDestinationURL: external)
        XCTAssertThrowsError(try scope.prepareDirectory(root: another))
    }
}
