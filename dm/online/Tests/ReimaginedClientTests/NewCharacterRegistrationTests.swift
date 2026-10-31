import XCTest
import CryptoKit
@testable import ReimaginedClient

final class NewCharacterRegistrationTests: XCTestCase {
    private func header() throws -> NewCharacterHeader {
        var b = [UInt8](repeating: 0, count: 403)
        func word(_ p: Int, _ v: UInt32) { for i in 0..<4 { b[p+i] = UInt8(truncatingIfNeeded: v >> (8*i)) } }
        word(0, 0xaa55aa55); word(4, 105); word(8, 403); word(20, 1)
        b[24] = 4; b[25] = 16; b[26] = 30; b[27] = 1; b[248] = 3
        for (i, value) in "Fixture".utf8.enumerated() { b[299+i] = value }
        var crc: UInt32 = 0
        for byte in b { crc = ((crc << 1) | (crc >> 31)) &+ UInt32(byte) }
        word(12, crc)
        return try NewCharacterHeader(characterName: "Fixture", bytes: Data(b))
    }
    private func session(subject: String = "fixture-account", nonce: Int = 1) throws -> LauncherSession {
        let data = try JSONSerialization.data(withJSONObject: ["sub": subject, "nonce": nonce])
        let payload = data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        // Deliberately unsigned test token: its payload is a namespace hint,
        // never authentication. The transport fixtures authorize the tests.
        return LauncherSession(accessToken: "fixture." + payload + ".unsigned", expiresAtUtc: .distantFuture,
            refreshToken: "fixture-refresh", refreshExpiresAtUtc: .distantFuture)
    }
    private func bundle() -> LadderBundleDescriptor {
        LadderBundleDescriptor(id: UUID(), ladderId: UUID(), revision: 6, schemaVersion: 1, status: "fixture",
            artifactSha256: String(repeating: "a", count: 64), manifestSha256: String(repeating: "b", count: 64),
            manifestSignature: "fixture", signingKeyId: "fixture", artifactSizeBytes: 1,
            compatibility: BundleCompatibility(minimumLauncherVersion: "0.1", requiredD2RLoaderVersion: "0.1",
                requiredD2RLoaderSha256: "", requiredD2RCoreSha256: "", requiredModVersion: "fixture", supportedGameVersion: "fixture"), downloadPath: "/fixture")
    }
    private func root() throws -> URL {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: false)
        return path
    }
    private final class Transport: HTTPTransport {
        let bundle: LadderBundleDescriptor, header: NewCharacterHeader
        let root: URL
        var posted: [Data] = [], paths: [String] = []
        var created = false, timeoutAfterCommit = false, timeoutWithoutCommit = false
        var operation: String?
        init(bundle: LadderBundleDescriptor, header: NewCharacterHeader, root: URL) { self.bundle = bundle; self.header = header; self.root = root }
        func response(_ body: Any) throws -> Data { try JSONSerialization.data(withJSONObject: body) }
        func receipt() throws -> Data {
            try response(["operationId": operation!, "written": [["fileName": header.fileName, "sha256": header.sha256, "version": 1]], "deleted": []])
        }
        func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            let path = request.url!.path; paths.append(path)
            var status = 200, data = Data()
            if path.hasSuffix("/launch-ticket") {
                data = try response(["launchTicket": "fixture-ticket", "expiresAtUtc": "2099-01-01T00:00:00Z",
                    "ladderId": bundle.ladderId.uuidString, "bundleId": bundle.id.uuidString, "bundleRevision": bundle.revision])
            } else if path.hasSuffix("/game-token") {
                data = try response(["accessToken": "fixture-game", "expiresAtUtc": "2099-01-01T00:00:00Z"])
            } else if path.hasSuffix("/game-token/revoke") { status = 204 }
            else if path.contains("/snapshot/receipts/") {
                if created, let operation, path.hasSuffix(operation.lowercased()) { data = try receipt() }
                else { status = 404 }
            } else if path.hasSuffix("/snapshot") {
                XCTAssertEqual(request.httpMethod, "POST")
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-game")
                XCTAssertEqual(request.value(forHTTPHeaderField: "X-Ladder-Launch-Ticket"), "fixture-ticket")
                let body = try XCTUnwrap(request.httpBody); posted.append(body)
                let object = try JSONSerialization.jsonObject(with: body) as! [String: Any]
                operation = object["operationId"] as? String
                XCTAssertEqual(Set(object.keys), ["operationId", "bundleIdentity", "files"])
                let file = (object["files"] as! [[String: Any]])[0]
                XCTAssertEqual(Set(file.keys), ["fileName", "contentBase64"])
                XCTAssertEqual(Data(base64Encoded: file["contentBase64"] as! String), header.bytes)
                let journals = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)!.compactMap { $0 as? URL }.filter { $0.lastPathComponent == "fixture.json" }
                let journal = try JSONSerialization.jsonObject(with: Data(contentsOf: XCTUnwrap(journals.first))) as! [String: Any]
                XCTAssertEqual(journal["state"] as? String, "attempted", "Marker must exist before network write")
                if timeoutWithoutCommit { throw URLError(.timedOut) }
                created = true
                if timeoutAfterCommit { throw URLError(.timedOut) }
                data = try receipt()
            } else if path.hasSuffix("/characters/saves") {
                let files: [[String: Any]] = created ? [["fileName": header.fileName, "characterName": header.characterName,
                    "sha256": header.sha256, "version": 1, "byteCount": header.bytes.count, "corrupt": false]] : []
                data = try response(["ladderId": bundle.ladderId.uuidString, "serverAuthoritative": true, "saves": files])
            } else if path.hasSuffix("/characters/saves/" + header.fileName) { data = header.bytes }
            else { XCTFail("Unexpected route"); status = 404 }
            return (data, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
        }
    }

    func testNamespaceSurvivesTokenRotationAndSeparatesAccounts() throws {
        let origin = ReimaginedAPIClient.production, ladder = UUID()
        let a = try session(nonce: 1).localSaveScope(origin: origin, ladderID: ladder)
        let b = try session(nonce: 2).localSaveScope(origin: origin, ladderID: ladder)
        let c = try session(subject: "other").localSaveScope(origin: origin, ladderID: ladder)
        XCTAssertEqual(a.accountDigest, b.accountDigest); XCTAssertNotEqual(a.accountDigest, c.accountDigest)
        let invalid = LauncherSession(accessToken: "opaque", expiresAtUtc: .distantFuture, refreshToken: "fixture", refreshExpiresAtUtc: .distantFuture)
        XCTAssertThrowsError(try invalid.localSaveScope(origin: origin, ladderID: ladder))
    }

    func testJournalReloadPreservesExactOperationAndOnlyOneInstanceCanClaim() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let header = try header(), bundle = bundle(), proof = VerifiedLadderPackage(descriptor: bundle, fileCount: 1)
        let scope = try session().localSaveScope(origin: ReimaginedAPIClient.production, ladderID: bundle.ladderId)
        let first = try NewCharacterJournal(header: header, scope: scope, package: proof, root: root)
        let other = try NewCharacterJournal(header: header, scope: scope, package: proof, root: root)
        XCTAssertEqual(first.operationID, other.operationID); XCTAssertEqual(first.requestBody, other.requestBody)
        XCTAssertEqual(first.operationID.utf8.count, 64)
        XCTAssertTrue(first.operationID.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) })
        try first.beginAttempt(package: proof)
        XCTAssertThrowsError(try other.beginAttempt(package: proof)) { XCTAssertEqual($0 as? RegistrationError, .alreadyAttempted) }
        let resumed = try NewCharacterJournal(header: header, scope: scope, package: proof, root: root)
        XCTAssertEqual(resumed.state, .attempted)
        XCTAssertEqual(resumed.operationID, first.operationID)
        XCTAssertFalse(String(decoding: try Data(contentsOf: first.url), as: UTF8.self).contains("fixture-refresh"))
        let mode = try FileManager.default.attributesOfItem(atPath: first.url.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.intValue, 0o600)
    }

    func testRegistrationRequiresIndependentReceiptDownloadAndIsolatesOfflineData() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let offline = root.appendingPathComponent("offline.d2s"), original = Data("unrelated offline fixture".utf8)
        try original.write(to: offline)
        let header = try header(), bundle = bundle(), proof = VerifiedLadderPackage(descriptor: bundle, fileCount: 1)
        let transport = Transport(bundle: bundle, header: header, root: root)
        let api = try ReimaginedAPIClient(transport: transport, identity: .init(applicationVersion: "1.0", platform: .iOS))
        let result = try await api.registerNewCharacter(header: header, bundle: bundle, package: proof, session: session(), root: root)
        XCTAssertEqual(transport.posted.count, 1); XCTAssertEqual(result.initialCharacter.bytes, header.bytes)
        XCTAssertEqual(try Data(contentsOf: result.isolatedSnapshot.appendingPathComponent("Fixture/Fixture.d2s")), header.bytes)
        XCTAssertEqual(try Data(contentsOf: offline), original)
        XCTAssertTrue(transport.paths.last!.hasSuffix("/revoke"))
        let scope = try session().localSaveScope(origin: api.origin, ladderID: bundle.ladderId)
        XCTAssertEqual(try NewCharacterJournal(header: header, scope: scope, package: proof, root: root).state, .confirmed)
    }

    func testLostReplyReconcilesSameOperationWithoutResubmitting() async throws {
        for committed in [false, true] {
            let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
            let header = try header(), bundle = bundle(), proof = VerifiedLadderPackage(descriptor: bundle, fileCount: 1)
            let transport = Transport(bundle: bundle, header: header, root: root)
            transport.timeoutAfterCommit = committed; transport.timeoutWithoutCommit = !committed
            let api = try ReimaginedAPIClient(transport: transport, identity: .init(applicationVersion: "1.0", platform: .iOS))
            do { _ = try await api.registerNewCharacter(header: header, bundle: bundle, package: proof, session: session(), root: root); XCTFail("Lost reply accepted") }
            catch { XCTAssertEqual((error as? URLError)?.code, .timedOut) }
            if committed {
                let result = try await api.registerNewCharacter(header: header, bundle: bundle, package: proof, session: session(), root: root)
                XCTAssertEqual(result.initialCharacter.bytes, header.bytes)
            } else {
                do { _ = try await api.registerNewCharacter(header: header, bundle: bundle, package: proof, session: session(), root: root); XCTFail("Unknown outcome retried") }
                catch { XCTAssertEqual(error as? RegistrationError, .receiptPending) }
            }
            XCTAssertEqual(transport.posted.count, 1, "A lost reply must not create another operation or repeat POST")
        }
    }

    func testExistingCharacterIsNotOverwritten() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let header = try header(), bundle = bundle(), proof = VerifiedLadderPackage(descriptor: bundle, fileCount: 1)
        let transport = Transport(bundle: bundle, header: header, root: root); transport.created = true
        let api = try ReimaginedAPIClient(transport: transport, identity: .init(applicationVersion: "1.0", platform: .iOS))
        do { _ = try await api.registerNewCharacter(header: header, bundle: bundle, package: proof, session: session(), root: root); XCTFail("Existing character overwritten") }
        catch { XCTAssertEqual(error as? RegistrationError, .characterExists) }
        XCTAssertTrue(transport.posted.isEmpty)
        XCTAssertTrue(transport.paths.last!.hasSuffix("/revoke"))
    }

    func testCorruptedJournalAndMismatchedReceiptNeverConfirm() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let header = try header(), bundle = bundle(), proof = VerifiedLadderPackage(descriptor: bundle, fileCount: 1)
        let scope = try session().localSaveScope(origin: ReimaginedAPIClient.production, ladderID: bundle.ladderId)
        let journal = try NewCharacterJournal(header: header, scope: scope, package: proof, root: root)
        let bad = try JSONSerialization.data(withJSONObject: ["written": [["fileName": header.fileName, "sha256": "wrong", "version": 1]]])
        XCTAssertThrowsError(try journal.observeReceipt(bad)); XCTAssertEqual(journal.state, .prepared)
        var data = try JSONSerialization.jsonObject(with: Data(contentsOf: journal.url)) as! [String: Any]
        data["bodySHA256"] = "wrong"
        try JSONSerialization.data(withJSONObject: data).write(to: journal.url)
        XCTAssertThrowsError(try journal.beginAttempt(package: proof)) { XCTAssertEqual($0 as? RegistrationError, .invalidJournal) }
        XCTAssertThrowsError(try NewCharacterJournal(header: header, scope: scope, package: proof, root: root))
    }

    func testLegacyGUIDMigrationIsLimitedToUnattemptedRequests() throws {
        for attempted in [false, true] {
            let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
            let header = try header(), bundle = bundle(), proof = VerifiedLadderPackage(descriptor: bundle, fileCount: 1)
            let scope = try session().localSaveScope(origin: ReimaginedAPIClient.production, ladderID: bundle.ladderId)
            let first = try NewCharacterJournal(header: header, scope: scope, package: proof, root: root)
            var record = try JSONSerialization.jsonObject(with: Data(contentsOf: first.url)) as! [String: Any]
            let legacy = UUID().uuidString
            var body = try JSONSerialization.jsonObject(with: first.requestBody) as! [String: Any]
            body["operationId"] = legacy.lowercased()
            let bytes = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys, .withoutEscapingSlashes])
            record["format"] = 1; record["operationID"] = legacy; record["body"] = bytes.base64EncodedString()
            record["bodySHA256"] = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
            record["state"] = attempted ? "attempted" : "prepared"
            try JSONSerialization.data(withJSONObject: record).write(to: first.url)
            if attempted {
                XCTAssertThrowsError(try NewCharacterJournal(header: header, scope: scope, package: proof, root: root)) {
                    XCTAssertEqual($0 as? RegistrationError, .receiptPending)
                }
                let unchanged = try JSONSerialization.jsonObject(with: Data(contentsOf: first.url)) as! [String: Any]
                XCTAssertEqual(unchanged["operationID"] as? String, legacy)
            } else {
                let migrated = try NewCharacterJournal(header: header, scope: scope, package: proof, root: root)
                XCTAssertEqual(migrated.state, .prepared); XCTAssertEqual(migrated.operationID.count, 64)
                let saved = try JSONSerialization.jsonObject(with: Data(contentsOf: first.url)) as! [String: Any]
                XCTAssertEqual(saved["legacyUnsentOperationID"] as? String, legacy)
                XCTAssertEqual(saved["format"] as? Int, 2)
            }
        }
    }
}
