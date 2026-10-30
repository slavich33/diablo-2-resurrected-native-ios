// 验证 PKCE、签名格式和策略一致性；全部账户数据为测试占位值。
// Exercise PKCE, signature format and policy consistency; all account values are test placeholders.
import XCTest
import CryptoKit
@testable import ReimaginedClient

private final class FixtureTransport: HTTPTransport {
    var status = 200
    var bytes = Data()
    var headers: [String: String] = [:]
    var requests: [URLRequest] = []
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        return (bytes, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!)
    }
}

final class ProtocolTests: XCTestCase {
    let id = "11111111-1111-4111-8111-111111111111"
    let start = "2026-10-01T00:00:00Z"
    let end = "2026-11-01T00:00:00Z"

    func testRFC7636ChallengeAndNativeAuthorizationURL() throws {
        let auth = PKCEAuthorization(verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk", state: "test-state", loopbackPort: 51324)
        XCTAssertEqual(auth.challenge, "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        let url = try XCTUnwrap(URLComponents(url: auth.authorizationURL(), resolvingAgainstBaseURL: false))
        XCTAssertEqual(url.host, "www.d2r-reimagined.com")
        XCTAssertEqual(url.path, "/launcher/authorize")
        let query = Dictionary(uniqueKeysWithValues: url.queryItems!.map { ($0.name, $0.value!) })
        XCTAssertEqual(query["redirect_uri"], "http://127.0.0.1:51324/oauth/callback")
        XCTAssertEqual(query["state"], "test-state")
        XCTAssertEqual(query["code_challenge"], auth.challenge)
        XCTAssertThrowsError(try auth.authorizationURL(website: URL(string: "http://www.d2r-reimagined.com/")!))
    }

    func testRandomPKCEAndState() throws {
        let a = try PKCEAuthorization(loopbackPort: 51000)
        let b = try PKCEAuthorization(loopbackPort: 51000)
        XCTAssertEqual(a.verifier.count, 43)
        XCTAssertEqual(a.state.count, 43)
        XCTAssertNotEqual(a.verifier, b.verifier)
        XCTAssertNotEqual(a.state, b.state)
        XCTAssertThrowsError(try PKCEAuthorization(loopbackPort: 0))
    }

    func testCallbackRejectsStateOriginPortAndDuplicateParameters() throws {
        let auth = PKCEAuthorization(verifier: "test-verifier", state: "expected", loopbackPort: 51324)
        XCTAssertEqual(try auth.code(from: URL(string: "http://127.0.0.1:51324/oauth/callback?code=test-code&state=expected")!), "test-code")
        for bad in [
            "http://127.0.0.1:51324/oauth/callback?code=x&state=other",
            "http://evil.example:51324/oauth/callback?code=x&state=expected",
            "http://127.0.0.1:51325/oauth/callback?code=x&state=expected",
            "http://127.0.0.1:51324/wrong?code=x&state=expected",
            "http://127.0.0.1:51324/oauth/callback?code=x&state=expected&state=other",
            "http://127.0.0.1:51324/oauth/callback?code=x&code=y&state=expected",
            "http://127.0.0.1:51324/oauth/callback?code=&state=expected",
            "http://127.0.0.1:51324/oauth/callback?error=access_denied&state=expected",
            "http://user@127.0.0.1:51324/oauth/callback?code=x&state=expected"
        ] { XCTAssertThrowsError(try auth.code(from: URL(string: bad)!)) }
    }

    func testSignedManifestRejectsTamperingUnknownRootAndDER() throws {
        let key = P256.Signing.PrivateKey()
        let bytes = Data("{\"schemaVersion\":2}".utf8)
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let sig = try key.signature(for: bytes)
        let verifier = ManifestVerifier(trustedKeys: ["test-root": key.publicKey])
        try verifier.verify(manifest: bytes, expectedSHA256: digest.uppercased(), signatureBase64: sig.rawRepresentation.base64EncodedString(), signingKeyID: "test-root")
        XCTAssertThrowsError(try verifier.verify(manifest: bytes + Data([32]), expectedSHA256: digest, signatureBase64: sig.rawRepresentation.base64EncodedString(), signingKeyID: "test-root"))
        XCTAssertThrowsError(try verifier.verify(manifest: bytes, expectedSHA256: digest, signatureBase64: sig.rawRepresentation.base64EncodedString(), signingKeyID: "unknown-root"))
        XCTAssertThrowsError(try verifier.verify(manifest: bytes, expectedSHA256: digest, signatureBase64: sig.derRepresentation.base64EncodedString(), signingKeyID: "test-root"))
        let other = try P256.Signing.PrivateKey().signature(for: bytes)
        XCTAssertThrowsError(try verifier.verify(manifest: bytes, expectedSHA256: digest, signatureBase64: other.rawRepresentation.base64EncodedString(), signingKeyID: "test-root"))
    }

    func testScheduleReadsPublicEndpointWithoutPretendingWindows() async throws {
        let transport = FixtureTransport()
        transport.bytes = Data("{\"serverTimeUtc\":\"2026-10-30T12:50:32.5588853Z\",\"ladders\":[]}".utf8)
        let api = try ReimaginedAPIClient(transport: transport)
        let schedule = try await api.schedule()
        XCTAssertEqual(schedule.ladders.count, 0)
        let request = try XCTUnwrap(transport.requests.last)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.url?.absoluteString, "https://api.d2r-reimagined.com/ladders/schedule")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "D2RMobile-Reimagined/0.1")
    }

    func testPolicyRequiresMatchingVersionDatesAndIdentity() async throws {
        let entryData = Data("{\"id\":\"\(id)\",\"name\":\"Test ladder\",\"startDateUtc\":\"\(start)\",\"endDateUtc\":\"\(end)\",\"policyVersion\":\"test-revision\",\"isLive\":true}".utf8)
        let entry = try ReimaginedJSON.decoder().decode(LadderScheduleEntry.self, from: entryData)
        let transport = FixtureTransport()
        transport.bytes = Data("{\"id\":\"\(id)\",\"name\":\"Test ladder\",\"startDateUtc\":\"\(start)\",\"endDateUtc\":\"\(end)\",\"activeBundle\":null}".utf8)
        let api = try ReimaginedAPIClient(transport: transport)
        do { _ = try await api.policy(for: entry); XCTFail("Missing policy version accepted") }
        catch { XCTAssertEqual(error as? ClientError, .policyChanged) }
        transport.headers["X-Ladder-Policy-Version"] = "test-revision"
        let policy = try await api.policy(for: entry)
        XCTAssertEqual(policy.id, entry.id)
        transport.bytes = Data(String(decoding: transport.bytes, as: UTF8.self).replacingOccurrences(of: end, with: "2027-01-01T00:00:00Z").utf8)
        do { _ = try await api.policy(for: entry); XCTFail("Changed schedule accepted") }
        catch { XCTAssertEqual(error as? ClientError, .scheduleMismatch) }
    }

    func testAuthorizationExchangeUsesContractAndRedactsSession() async throws {
        let transport = FixtureTransport()
        transport.bytes = Data("{\"accessToken\":\"test-access\",\"refreshToken\":\"test-refresh\",\"expiresAtUtc\":\"\(end)\",\"refreshExpiresAtUtc\":\"2027-01-01T00:00:00Z\"}".utf8)
        let api = try ReimaginedAPIClient(transport: transport)
        let auth = PKCEAuthorization(verifier: "test-verifier", state: "test-state", loopbackPort: 51324)
        let session = try await api.exchange(authorization: auth, callback: URL(string: "http://127.0.0.1:51324/oauth/callback?code=test-code&state=test-state")!)
        XCTAssertEqual(session.accessToken, "test-access")
        XCTAssertFalse(String(describing: session).contains("test-access"))
        XCTAssertFalse(String(reflecting: session).contains("test-refresh"))
        let request = transport.requests.last!
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.path, "/auth/launcher/token")
        let object = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: String]
        XCTAssertEqual(object, ["code": "test-code", "codeVerifier": "test-verifier", "redirectUri": auth.redirectURL.absoluteString])
    }

    func testHTTPAndOriginFailures() async throws {
        XCTAssertThrowsError(try ReimaginedAPIClient(origin: URL(string: "http://api.d2r-reimagined.com/")!))
        XCTAssertThrowsError(try ReimaginedAPIClient(origin: URL(string: "https://api.d2r-reimagined.com/?token=x")!))
        let transport = FixtureTransport()
        transport.status = 401
        let api = try ReimaginedAPIClient(transport: transport)
        do { _ = try await api.schedule(); XCTFail("Unauthorized accepted") }
        catch { XCTAssertEqual(error as? ClientError, .http(401)) }
    }

    func testIndependentDotNetSignatureFixture() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "dotnet-p1363", withExtension: "json"))
        let fixture = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        XCTAssertEqual(fixture["signatureBytes"] as? Int, 64)
        let key = try P256.Signing.PublicKey(pemRepresentation: fixture["publicKeyPem"] as! String)
        let manifest = try XCTUnwrap(Data(base64Encoded: fixture["manifestBase64"] as! String))
        let verifier = ManifestVerifier(trustedKeys: ["dotnet-test": key])
        try verifier.verify(manifest: manifest, expectedSHA256: fixture["sha256"] as! String,
                            signatureBase64: fixture["signatureBase64"] as! String, signingKeyID: "dotnet-test")
    }

    func testRefreshRevokeAndAuthenticatedScheduleContracts() async throws {
        let transport = FixtureTransport()
        let payload = Data("{\"accessToken\":\"test-access\",\"refreshToken\":\"test-refresh\",\"expiresAtUtc\":\"2027-01-01T00:00:00Z\",\"refreshExpiresAtUtc\":\"2027-02-01T00:00:00Z\"}".utf8)
        let saved = try ReimaginedJSON.decoder().decode(LauncherSession.self, from: payload)
        let api = try ReimaginedAPIClient(transport: transport)
        transport.bytes = payload
        _ = try await api.refresh(saved)
        XCTAssertEqual(transport.requests.last?.url?.path, "/auth/launcher/refresh")
        XCTAssertNil(transport.requests.last?.value(forHTTPHeaderField: "Authorization"))
        let refresh = try JSONSerialization.jsonObject(with: transport.requests.last!.httpBody!) as! [String: String]
        XCTAssertEqual(refresh, ["refreshToken": "test-refresh"])
        transport.bytes = Data()
        transport.status = 204
        try await api.revoke(saved)
        XCTAssertEqual(transport.requests.last?.url?.path, "/auth/launcher/revoke")
        transport.status = 200
        transport.bytes = Data("[]".utf8)
        let active = try await api.activeLadders(accessToken: saved.accessToken)
        XCTAssertTrue(active.isEmpty)
        XCTAssertEqual(transport.requests.last?.url?.path, "/ladders/active")
        XCTAssertEqual(transport.requests.last?.value(forHTTPHeaderField: "Authorization"), "Bearer test-access")
    }

    func testLobbyRegionSnakeCaseContract() async throws {
        let transport = FixtureTransport()
        transport.bytes = Data("[{\"id\":\"eu-central\",\"name\":\"Europe Central\",\"available\":true,\"ping_targets\":[\"test.example\"]},{\"id\":\"test-offline\",\"name\":\"Test offline\",\"available\":false}]".utf8)
        let api = try ReimaginedAPIClient(transport: transport)
        let regions = try await api.regions(ladderID: UUID(uuidString: id)!, accessToken: "test-access")
        XCTAssertEqual(regions.count, 2)
        XCTAssertEqual(regions[0].pingTargets, ["test.example"])
        XCTAssertTrue(regions[0].available)
        XCTAssertNil(regions[1].pingTargets)
        XCTAssertFalse(regions[1].available)
        XCTAssertEqual(transport.requests.last?.url?.path, "/lobby/ladders/\(id)/regions")
        XCTAssertEqual(transport.requests.last?.value(forHTTPHeaderField: "Authorization"), "Bearer test-access")
    }
}
