import XCTest
@testable import ReimaginedClient

final class LadderAccountInspectionTests: XCTestCase {
    private final class Transport: HTTPTransport {
        let ladder: UUID, bundle: UUID
        var paths: [String] = []
        var refuseSaves = false, refuseCleanup = false, cancelSaves = false
        var cleanupWasCancelled = false
        init(ladder: UUID, bundle: UUID) { self.ladder = ladder; self.bundle = bundle }
        func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            let path = request.url!.path
            paths.append(path)
            var body: String, status = 200
            if path.hasSuffix("launch-ticket") {
                body = "{\"launchTicket\":\"fixture-ticket\",\"expiresAtUtc\":\"2099-01-01T00:00:00Z\",\"ladderId\":\"\(ladder)\",\"bundleId\":\"\(bundle)\",\"bundleRevision\":1}"
            } else if path.hasSuffix("game-token") {
                body = "{\"accessToken\":\"fixture-game-token\",\"expiresAtUtc\":\"2099-01-01T00:00:00Z\"}"
            } else if path.hasSuffix("/saves") {
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-game-token")
                XCTAssertEqual(request.value(forHTTPHeaderField: "X-Ladder-Launch-Ticket"), "fixture-ticket")
                if cancelSaves { withUnsafeCurrentTask { $0?.cancel() } }
                status = refuseSaves ? 403 : 200
                body = "{\"ladderId\":\"\(ladder)\",\"serverAuthoritative\":true,\"saves\":[]}"
            } else if path.hasSuffix("/games") {
                body = "{\"games\":[],\"totalPlayers\":0}"
            } else if path.hasSuffix("/revoke") {
                cleanupWasCancelled = Task.isCancelled
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-game-token")
                status = refuseCleanup ? 500 : 204; body = ""
            } else { XCTFail("Unexpected route"); body = ""; status = 404 }
            return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
        }
    }

    private func fixture() -> (LadderBundleDescriptor, VerifiedLadderPackage, LauncherSession, Transport) {
        let ladder = UUID(), id = UUID(), hash = String(repeating: "0", count: 64)
        let bundle = LadderBundleDescriptor(id: id, ladderId: ladder, revision: 1, schemaVersion: 1,
            status: "fixture", artifactSha256: hash, manifestSha256: hash, manifestSignature: "fixture", signingKeyId: "fixture",
            artifactSizeBytes: 1, compatibility: BundleCompatibility(minimumLauncherVersion: "0.1", requiredD2RLoaderVersion: "0.1",
                requiredD2RLoaderSha256: "", requiredD2RCoreSha256: "", requiredModVersion: "fixture", supportedGameVersion: "fixture"), downloadPath: "/fixture")
        // Test-only internal construction. Production callers obtain this from
        // LadderArchiveVerifier, exercised independently with signed ZIPs.
        let proof = VerifiedLadderPackage(descriptor: bundle, fileCount: 1)
        let session = LauncherSession(accessToken: "fixture-launcher", expiresAtUtc: .distantFuture,
            refreshToken: "fixture-refresh", refreshExpiresAtUtc: .distantFuture)
        return (bundle, proof, session, Transport(ladder: ladder, bundle: id))
    }

    func testCompleteReadUsesNarrowTokenAndRevokesBeforeReturning() async throws {
        let (bundle, proof, session, transport) = fixture()
        let api = try ReimaginedAPIClient(transport: transport, identity: .init(applicationVersion: "1.0", platform: .iOS))
        let result = try await api.inspectLadderAccount(bundle: bundle, verifiedPackage: proof, session: session)
        XCTAssertTrue(result.saves.serverAuthoritative)
        XCTAssertEqual(result.saves.files.count, 0); XCTAssertEqual(result.lobby.games.count, 0)
        XCTAssertEqual(transport.paths.count, 5)
        XCTAssertTrue(transport.paths.last!.hasSuffix("/revoke"))
    }

    func testRefusalAndCancellationStillRevokeWithoutLauncherFallback() async throws {
        for cancel in [false, true] {
            let (bundle, proof, session, transport) = fixture()
            transport.refuseSaves = !cancel; transport.cancelSaves = cancel
            let api = try ReimaginedAPIClient(transport: transport, identity: .init(applicationVersion: "1.0", platform: .iOS))
            let task = Task { try await api.inspectLadderAccount(bundle: bundle, verifiedPackage: proof, session: session) }
            do { _ = try await task.value; XCTFail("Refusal/cancellation accepted") }
            catch {
                if cancel { XCTAssertTrue(error is CancellationError) }
                else { XCTAssertEqual(error as? ClientError, .http(403)) }
            }
            XCTAssertEqual(transport.paths.count, 4)
            XCTAssertTrue(transport.paths.last!.hasSuffix("/revoke"))
            XCTAssertFalse(transport.cleanupWasCancelled)
        }
    }

    func testWrongProofDoesNotReachNetworkAndCleanupFailureIsVisible() async throws {
        let (bundle, proof, session, transport) = fixture()
        let api = try ReimaginedAPIClient(transport: transport, identity: .init(applicationVersion: "1.0", platform: .iOS))
        let wrong = fixture().1
        do { _ = try await api.inspectLadderAccount(bundle: bundle, verifiedPackage: wrong, session: session); XCTFail("Stale proof accepted") }
        catch { XCTAssertEqual(error as? ClientError, .policyChanged) }
        XCTAssertTrue(transport.paths.isEmpty)
        transport.refuseCleanup = true
        do { _ = try await api.inspectLadderAccount(bundle: bundle, verifiedPackage: proof, session: session); XCTFail("Cleanup failure hidden") }
        catch { XCTAssertEqual(error as? LadderInspectionError, .tokenRevocationFailed) }
    }
}
