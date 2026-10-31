import XCTest
import CryptoKit
import zlib
@testable import ReimaginedClient

final class LadderArchiveTests: XCTestCase {
    private let key = P256.Signing.PrivateKey()
    private let bundleID = UUID(), ladderID = UUID()

    private func digest(_ bytes: Data) -> String {
        SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    private struct Fixture {
        var bytes: Data
        var policy: [String: Any]
        func descriptor() throws -> LadderBundleDescriptor {
            try JSONDecoder().decode(LadderBundleDescriptor.self, from: JSONSerialization.data(withJSONObject: policy))
        }
    }

    private func fixture(paths: [String] = ["plugins/fixture.txt", "data/empty.txt"],
                         compressed: Bool = false, corruptPayload: Bool = false) throws -> Fixture {
        let payloads = [Data("synthetic test payload, not a game file".utf8), Data()]
        let files = paths.enumerated().map { index, path -> [String: Any] in
            ["archivePath": path, "targetPath": path, "fileName": (path as NSString).lastPathComponent,
             "sha256": digest(payloads[index]), "sizeBytes": payloads[index].count]
        }
        let plugin: [String: Any] = ["pluginId": "fixture", "name": "Fixture", "fileName": "fixture.txt",
            "targetPath": paths[0], "sha256": digest(payloads[0]), "sizeBytes": payloads[0].count]
        let compatibility = ["minimumLauncherVersion": "0.1", "requiredD2RLoaderVersion": "0.1",
            "requiredD2RLoaderSha256": "", "requiredD2RCoreSha256": "", "requiredModVersion": "fixture", "supportedGameVersion": "fixture"]
        let manifest: [String: Any] = ["schemaVersion": 1, "bundleId": bundleID.uuidString,
            "ladderId": ladderID.uuidString, "revision": 1, "compatibility": compatibility,
            "files": files, "plugins": [plugin]]
        let raw = try JSONSerialization.data(withJSONObject: manifest, options: .sortedKeys)
        let signature = try key.signature(for: raw).rawRepresentation.base64EncodedString()
        var entries = paths.enumerated().map { ($0.element, payloads[$0.offset]) }
        if corruptPayload { entries[0].1 = Data(repeating: 1, count: payloads[0].count) }
        entries += [("manifest.json", raw), ("manifest.sig", Data(signature.utf8))]
        let archive = try zip(entries, compressed: compressed)
        return Fixture(bytes: archive, policy: ["id": bundleID.uuidString, "ladderId": ladderID.uuidString,
            "revision": 1, "schemaVersion": 1, "status": "fixture", "artifactSha256": digest(archive),
            "manifestSha256": digest(raw), "manifestSignature": signature, "signingKeyId": "fixture",
            "artifactSizeBytes": archive.count, "compatibility": compatibility, "downloadPath": "/fixture.zip",
            "files": files, "plugins": [plugin]])
    }

    private func verifier() -> LadderArchiveVerifier { LadderArchiveVerifier(trustedKeys: ["fixture": key.publicKey]) }

    func testStoredAndDeflatePackagesVerifyEveryFileAndExactDescriptor() throws {
        for compressed in [false, true] {
            let f = try fixture(compressed: compressed), descriptor = try f.descriptor()
            let verified = try verifier().verify(bytes: f.bytes, descriptor: descriptor)
            XCTAssertEqual(verified.fileCount, 2)
            XCTAssertTrue(verified.matches(descriptor))
            var newer = f; newer.policy["revision"] = 2
            XCTAssertFalse(verified.matches(try newer.descriptor()))
            XCTAssertThrowsError(try verifier().verify(bytes: newer.bytes, descriptor: newer.descriptor()))
            var contradictory = f
            contradictory.policy["files"] = []
            XCTAssertFalse(verified.matches(try contradictory.descriptor()), "Fresh metadata must remain bound to the verified signed contents")
        }
    }

    func testArchiveDigestSignatureAndIndividualContentAreIndependentChecks() throws {
        let f = try fixture()
        var changed = f.bytes; changed[35] ^= 1
        XCTAssertThrowsError(try verifier().verify(bytes: changed, descriptor: f.descriptor())) {
            XCTAssertEqual($0 as? LadderArchiveError, .digestMismatch)
        }
        XCTAssertThrowsError(try LadderArchiveVerifier(trustedKeys: [:]).verify(bytes: f.bytes, descriptor: f.descriptor())) {
            XCTAssertEqual($0 as? ManifestError, .unknownKey)
        }
        let bad = try fixture(corruptPayload: true)
        XCTAssertThrowsError(try verifier().verify(bytes: bad.bytes, descriptor: bad.descriptor())) {
            XCTAssertEqual($0 as? LadderArchiveError, .digestMismatch)
        }
        var contradictory = f
        contradictory.policy["files"] = []
        XCTAssertThrowsError(try verifier().verify(bytes: contradictory.bytes, descriptor: contradictory.descriptor())) {
            XCTAssertEqual($0 as? LadderArchiveError, .descriptorMismatch)
        }
    }

    func testSignedUnsafePathsAndCaseCollisionsAreRejected() throws {
        for paths in [["../fixture.txt", "data/empty.txt"], ["plugins/fixture.txt", "PLUGINS/FIXTURE.TXT"],
                      ["C:/fixture.txt", "data/empty.txt"], ["plugins/fixture.txt", "plugins/fixture.txt"]] {
            let f = try fixture(paths: paths)
            XCTAssertThrowsError(try verifier().verify(bytes: f.bytes, descriptor: f.descriptor()))
        }
    }

    func testMalformedCentralDirectoryEncryptedAndUnsupportedArchivesFail() throws {
        let original = try fixture()
        for mutation in [0, 1, 2, 3] {
            var f = original
            let eocd = f.bytes.count - 22
            let central = Int(f.bytes[eocd + 16]) | Int(f.bytes[eocd + 17]) << 8 |
                Int(f.bytes[eocd + 18]) << 16 | Int(f.bytes[eocd + 19]) << 24
            switch mutation {
            case 0: f.bytes[central + 42] = 0xff; f.bytes[central + 43] = 0xff // impossible local offset
            case 1: f.bytes[central + 8] = 1 // encryption
            case 2: f.bytes[central + 8] = 8 // data descriptor, outside supported subset
            default: f.bytes.removeLast()
            }
            f.policy["artifactSha256"] = digest(f.bytes); f.policy["artifactSizeBytes"] = f.bytes.count
            XCTAssertThrowsError(try verifier().verify(bytes: f.bytes, descriptor: f.descriptor()))
        }
    }

    private func zip(_ files: [(String, Data)], compressed: Bool) throws -> Data {
        var archive = Data(), central = Data()
        func append(_ value: UInt32, _ size: Int, to bytes: inout Data) {
            for i in 0..<size { bytes.append(UInt8(truncatingIfNeeded: value >> (i * 8))) }
        }
        for (name, content) in files {
            let start = archive.count, nameBytes = Data(name.utf8)
            let crc = content.withUnsafeBytes { crc32(0, $0.bindMemory(to: Bytef.self).baseAddress, uInt(content.count)) }
            let body = compressed ? try deflateRaw(content) : content
            append(0x04034b50, 4, to: &archive)
            for value: UInt32 in [20, 0, compressed ? 8 : 0, 0, 0] { append(value, 2, to: &archive) }
            for value in [UInt32(crc), UInt32(body.count), UInt32(content.count)] { append(value, 4, to: &archive) }
            append(UInt32(nameBytes.count), 2, to: &archive); append(0, 2, to: &archive)
            archive.append(nameBytes); archive.append(body)
            append(0x02014b50, 4, to: &central)
            for value: UInt32 in [0x314, 20, 0, compressed ? 8 : 0, 0, 0] { append(value, 2, to: &central) }
            for value in [UInt32(crc), UInt32(body.count), UInt32(content.count)] { append(value, 4, to: &central) }
            for value: UInt32 in [UInt32(nameBytes.count), 0, 0, 0, 0] { append(value, 2, to: &central) }
            append(0o100644 << 16, 4, to: &central); append(UInt32(start), 4, to: &central); central.append(nameBytes)
        }
        let start = archive.count
        archive.append(central); append(0x06054b50, 4, to: &archive)
        for value: UInt32 in [0, 0, UInt32(files.count), UInt32(files.count)] { append(value, 2, to: &archive) }
        append(UInt32(central.count), 4, to: &archive); append(UInt32(start), 4, to: &archive); append(0, 2, to: &archive)
        return archive
    }

    private func deflateRaw(_ bytes: Data) throws -> Data {
        var stream = z_stream()
        guard deflateInit2_(&stream, Z_DEFAULT_COMPRESSION, Z_DEFLATED, -MAX_WBITS, 8,
                            Z_DEFAULT_STRATEGY, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            throw LadderArchiveError.invalidArchive
        }
        defer { deflateEnd(&stream) }
        var output = Data(count: Int(deflateBound(&stream, uLong(bytes.count))))
        let capacity = output.count
        let result = bytes.withUnsafeBytes { input in
            output.withUnsafeMutableBytes { target in
                stream.next_in = UnsafeMutablePointer(mutating: input.bindMemory(to: Bytef.self).baseAddress)
                stream.avail_in = uInt(bytes.count)
                stream.next_out = target.bindMemory(to: Bytef.self).baseAddress
                stream.avail_out = uInt(capacity)
                return deflate(&stream, Z_FINISH)
            }
        }
        guard result == Z_STREAM_END else { throw LadderArchiveError.invalidArchive }
        return output.prefix(Int(stream.total_out))
    }
}
