// 用真实本地套接字验证回调拒绝、成功、超时与取消；不访问生产账户。
// Use real local sockets to verify rejected callbacks, success, timeout and cancellation; no production account access.
import XCTest
@testable import ReimaginedClient

final class LoopbackTests: XCTestCase {
    func testLoopbackRejectsWrongStateThenAcceptsOneValidCallback() async throws {
        let login = try LoopbackLogin()
        let waiting = Task { try await login.waitForCallback(timeout: 5) }
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        var bad = URLComponents(url: login.authorization.redirectURL, resolvingAgainstBaseURL: false)!
        bad.queryItems = [.init(name: "code", value: "test-code"), .init(name: "state", value: "wrong-test-state")]
        let (_, rejected) = try await session.data(from: bad.url!)
        XCTAssertEqual((rejected as? HTTPURLResponse)?.statusCode, 400)
        var good = bad
        good.queryItems = [.init(name: "code", value: "test-code"), .init(name: "state", value: login.authorization.state)]
        let (body, accepted) = try await session.data(from: good.url!)
        XCTAssertEqual((accepted as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual((accepted as? HTTPURLResponse)?.value(forHTTPHeaderField: "Cache-Control"), "no-store")
        XCTAssertFalse(String(decoding: body, as: UTF8.self).contains("test-code"))
        let callback = try await waiting.value
        XCTAssertEqual(try login.authorization.code(from: callback), "test-code")
        do { _ = try await login.waitForCallback(); XCTFail("Listener reused") }
        catch { XCTAssertEqual(error as? LoginListenerError, .alreadyStarted) }
    }

    func testLoopbackTimeoutAndCancellation() async throws {
        let timed = try LoopbackLogin()
        do { _ = try await timed.waitForCallback(timeout: 0.01); XCTFail("No timeout") }
        catch { XCTAssertEqual(error as? LoginListenerError, .timedOut) }
        let cancelled = try LoopbackLogin()
        cancelled.cancel()
        do { _ = try await cancelled.waitForCallback(timeout: 1); XCTFail("Cancellation ignored") }
        catch { XCTAssertEqual(error as? LoginListenerError, .cancelled) }
    }

    func testSessionSerializationRoundTrip() throws {
        let data = Data("{\"accessToken\":\"test-access\",\"refreshToken\":\"test-refresh\",\"expiresAtUtc\":\"2027-01-01T00:00:00Z\",\"refreshExpiresAtUtc\":\"2027-02-01T00:00:00Z\"}".utf8)
        let value = try ReimaginedJSON.decoder().decode(LauncherSession.self, from: data)
        let restored = try JSONDecoder().decode(LauncherSession.self, from: JSONEncoder().encode(value))
        XCTAssertEqual(restored.accessToken, value.accessToken)
        XCTAssertEqual(restored.refreshToken, value.refreshToken)
        XCTAssertEqual(restored.expiresAtUtc, value.expiresAtUtc)
    }
}
