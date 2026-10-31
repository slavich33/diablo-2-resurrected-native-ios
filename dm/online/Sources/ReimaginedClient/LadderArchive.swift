import Foundation
import CryptoKit
import zlib

public enum LadderArchiveError: Error, Equatable {
    case invalidArchive, unsupportedZIP, sizeLimit, digestMismatch, invalidManifest, descriptorMismatch
}

/// Complete content validation, not runtime plugin compatibility or admission.
/// Only the verifier constructs this proof. A newer policy needs a new proof.
public struct VerifiedLadderPackage {
    private let policy: LadderBundleDescriptor
    public var bundleID: UUID { policy.id }
    public var ladderID: UUID { policy.ladderId }
    public var revision: Int { policy.revision }
    public var artifactSHA256: String { policy.artifactSha256.lowercased() }
    public var manifestSHA256: String { policy.manifestSha256.lowercased() }
    public let fileCount: Int

    init(descriptor: LadderBundleDescriptor, fileCount: Int) {
        policy = descriptor; self.fileCount = fileCount
    }

    public func matches(_ descriptor: LadderBundleDescriptor) -> Bool {
        bundleID == descriptor.id && ladderID == descriptor.ladderId && revision == descriptor.revision &&
            artifactSHA256 == descriptor.artifactSha256.lowercased() &&
            manifestSHA256 == descriptor.manifestSha256.lowercased() &&
            policy.schemaVersion == descriptor.schemaVersion && policy.compatibility == descriptor.compatibility &&
            policy.artifactSizeBytes == descriptor.artifactSizeBytes && policy.signingKeyId == descriptor.signingKeyId &&
            policy.manifestSignature == descriptor.manifestSignature &&
            policy.files.flatMap(LadderArchiveVerifier.fileMap) == descriptor.files.flatMap(LadderArchiveVerifier.fileMap) &&
            policy.plugins.flatMap(LadderArchiveVerifier.pluginMap) == descriptor.plugins.flatMap(LadderArchiveVerifier.pluginMap)
    }
}

/// ZIP32 stored/deflate reader for signed ladder archives. No extraction,
/// execution, archive-supplied trust keys, symlinks or filesystem writes.
/// ZIP64, encryption and data descriptors are deliberately unsupported.
public struct LadderArchiveVerifier {
    private let signatures: ManifestVerifier
    public init(trustedKeys: [String: P256.Signing.PublicKey]) {
        signatures = ManifestVerifier(trustedKeys: trustedKeys)
    }

    public func verify(archive: URL, descriptor: LadderBundleDescriptor) throws -> VerifiedLadderPackage {
        guard archive.isFileURL,
              try archive.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]).isRegularFile == true,
              try archive.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else {
            throw LadderArchiveError.invalidArchive
        }
        let size = try FileManager.default.attributesOfItem(atPath: archive.path)[.size] as? NSNumber
        guard let size, size.int64Value == descriptor.artifactSizeBytes,
              (22...512 * 1024 * 1024).contains(size.int64Value) else { throw LadderArchiveError.sizeLimit }
        return try verify(bytes: Data(contentsOf: archive, options: .mappedIfSafe), descriptor: descriptor)
    }

    // Internal byte form also permits small, independently signed test fixtures.
    func verify(bytes: Data, descriptor: LadderBundleDescriptor) throws -> VerifiedLadderPackage {
        guard descriptor.revision > 0, descriptor.schemaVersion > 0,
              bytes.count == descriptor.artifactSizeBytes,
              bytes.count <= 512 * 1024 * 1024 else { throw LadderArchiveError.sizeLimit }
        guard Self.digest(bytes) == descriptor.artifactSha256.lowercased() else { throw LadderArchiveError.digestMismatch }
        let zip = try ZIP(bytes: bytes)
        guard let manifestEntry = zip.entries["manifest.json"], manifestEntry.size <= 8 * 1024 * 1024,
              let signatureEntry = zip.entries["manifest.sig"], signatureEntry.size <= 4096 else {
            throw LadderArchiveError.invalidManifest
        }
        let manifestBytes = try zip.read(manifestEntry)
        guard let signature = String(data: try zip.read(signatureEntry), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              signature == descriptor.manifestSignature else { throw LadderArchiveError.invalidManifest }
        try signatures.verify(manifest: manifestBytes, expectedSHA256: descriptor.manifestSha256,
                              signatureBase64: signature, signingKeyID: descriptor.signingKeyId)
        let manifest = try ReimaginedJSON.decoder().decode(Manifest.self, from: manifestBytes)
        guard manifest.bundleId == descriptor.id, manifest.ladderId == descriptor.ladderId,
              manifest.revision == descriptor.revision, manifest.schemaVersion == descriptor.schemaVersion,
              manifest.compatibility == descriptor.compatibility,
              let expectedFiles = descriptor.files, let expectedPlugins = descriptor.plugins,
              let actualFiles = Self.fileMap(manifest.files), let policyFiles = Self.fileMap(expectedFiles),
              let actualPlugins = Self.pluginMap(manifest.plugins), let policyPlugins = Self.pluginMap(expectedPlugins),
              actualFiles == policyFiles, actualPlugins == policyPlugins,
              !manifest.files.isEmpty, manifest.files.count <= 20_000,
              manifest.plugins.count <= 1024 else { throw LadderArchiveError.descriptorMismatch }
        var targets = Set<String>(), archivePaths = Set<String>()
        var total: Int64 = 0
        for file in manifest.files {
            try Task.checkCancellation()
            guard Self.path(file.archivePath), Self.path(file.targetPath),
                  file.fileName == (file.targetPath as NSString).lastPathComponent,
                  Self.hexDigest(file.sha256), (0...256 * 1024 * 1024).contains(file.sizeBytes),
                  targets.insert(file.targetPath.precomposedStringWithCanonicalMapping.lowercased()).inserted,
                  archivePaths.insert(file.archivePath).inserted,
                  file.archivePath != "manifest.json", file.archivePath != "manifest.sig",
                  let entry = zip.entries[file.archivePath], entry.size == file.sizeBytes else {
                throw LadderArchiveError.invalidManifest
            }
            total += file.sizeBytes
            guard total <= 4 * 1024 * 1024 * 1024 else { throw LadderArchiveError.sizeLimit }
            guard Self.digest(try zip.read(entry)) == file.sha256.lowercased() else { throw LadderArchiveError.digestMismatch }
        }
        guard Set(zip.entries.keys) == archivePaths.union(["manifest.json", "manifest.sig"]) else {
            throw LadderArchiveError.invalidManifest
        }
        let files = Dictionary(uniqueKeysWithValues: manifest.files.map { ($0.targetPath, $0) })
        for plugin in manifest.plugins {
            guard let file = files[plugin.targetPath], file.fileName == plugin.fileName,
                  file.sha256.lowercased() == plugin.sha256.lowercased(), file.sizeBytes == plugin.sizeBytes else {
                throw LadderArchiveError.invalidManifest
            }
        }
        return VerifiedLadderPackage(descriptor: descriptor, fileCount: manifest.files.count)
    }

    private struct Manifest: Decodable {
        let schemaVersion: Int, bundleId: UUID, ladderId: UUID, revision: Int
        let compatibility: BundleCompatibility
        let files: [LadderBundleFile]
        let plugins: [LadderBundlePlugin]
    }

    fileprivate static func fileMap(_ entries: [LadderBundleFile]) -> [String: LadderBundleFile]? {
        guard Set(entries.map(\.targetPath)).count == entries.count else { return nil }
        return Dictionary(uniqueKeysWithValues: entries.map {
            ($0.targetPath, LadderBundleFile(archivePath: $0.archivePath, targetPath: $0.targetPath,
                fileName: $0.fileName, sha256: $0.sha256.lowercased(), sizeBytes: $0.sizeBytes))
        })
    }
    fileprivate static func pluginMap(_ entries: [LadderBundlePlugin]) -> [String: LadderBundlePlugin]? {
        guard Set(entries.map(\.pluginId)).count == entries.count else { return nil }
        return Dictionary(uniqueKeysWithValues: entries.map {
            ($0.pluginId, LadderBundlePlugin(pluginId: $0.pluginId, name: $0.name,
                fileName: $0.fileName, targetPath: $0.targetPath, sha256: $0.sha256.lowercased(), sizeBytes: $0.sizeBytes))
        })
    }
    private static func digest(_ bytes: Data) -> String {
        SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }
    private static func hexDigest(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy {
            (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0)
        }
    }
    private static func path(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 1024 &&
            !value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) } &&
            !value.contains("\\") && !value.contains(":") &&
            value.split(separator: "/", omittingEmptySubsequences: false).allSatisfy {
                !$0.isEmpty && $0 != "." && $0 != ".." && !$0.hasSuffix(".") && !$0.hasSuffix(" ")
            }
    }

    private struct ZIP {
        struct Entry {
            let size: Int, compressedSize: Int, dataOffset: Int
            let method: UInt16, crc: UInt32
        }
        let bytes: Data
        var entries: [String: Entry] = [:]

        init(bytes: Data) throws {
            self.bytes = bytes
            guard bytes.count >= 22 else { throw LadderArchiveError.invalidArchive }
            let end = bytes.count
            var eocd: Int?
            for offset in stride(from: end - 22, through: max(0, end - 65557), by: -1) {
                if word(offset) == 0x06054b50 && offset + 22 + Int(half(offset + 20)) == end {
                    eocd = offset; break
                }
            }
            guard let eocd, half(eocd + 4) == 0, half(eocd + 6) == 0,
                  half(eocd + 8) == half(eocd + 10) else { throw LadderArchiveError.invalidArchive }
            let count = Int(half(eocd + 10)), centralSize = Int(word(eocd + 12)), start = Int(word(eocd + 16))
            guard count > 0, count <= 20_002, start + centralSize == eocd else { throw LadderArchiveError.sizeLimit }
            var offset = start, spans: [Range<Int>] = []
            for _ in 0..<count {
                guard offset + 46 <= eocd, word(offset) == 0x02014b50 else { throw LadderArchiveError.invalidArchive }
                let flags = half(offset + 8), method = half(offset + 10)
                let compressed = Int(word(offset + 20)), size = Int(word(offset + 24))
                let nameLength = Int(half(offset + 28)), extra = Int(half(offset + 30)), comment = Int(half(offset + 32))
                let local = Int(word(offset + 42)), mode = word(offset + 38) >> 16 & 0xf000
                guard flags & ~UInt16(0x806) == 0, method == 0 || method == 8,
                      half(offset + 6) <= 20, half(offset + 34) == 0,
                      mode == 0 || mode == 0x8000 else { throw LadderArchiveError.unsupportedZIP }
                guard nameLength > 0, nameLength <= 1024,
                      offset + 46 + nameLength + extra + comment <= eocd,
                      size <= 256 * 1024 * 1024, local + 30 <= start else { throw LadderArchiveError.sizeLimit }
                let nameData = bytes.subdata(in: (offset + 46)..<(offset + 46 + nameLength))
                guard let name = String(data: nameData, encoding: .utf8), LadderArchiveVerifier.path(name), entries[name] == nil,
                      word(local) == 0x04034b50, half(local + 6) == flags, half(local + 8) == method,
                      word(local + 14) == word(offset + 16), word(local + 18) == compressed,
                      word(local + 22) == size, Int(half(local + 26)) == nameLength else { throw LadderArchiveError.invalidArchive }
                let dataOffset = local + 30 + nameLength + Int(half(local + 28))
                guard dataOffset + compressed <= start,
                      bytes.subdata(in: (local + 30)..<(local + 30 + nameLength)) == nameData else {
                    throw LadderArchiveError.invalidArchive
                }
                entries[name] = Entry(size: size, compressedSize: compressed, dataOffset: dataOffset,
                    method: method, crc: word(offset + 16))
                spans.append(local..<(dataOffset + compressed))
                offset += 46 + nameLength + extra + comment
            }
            guard offset == eocd else { throw LadderArchiveError.invalidArchive }
            var next = 0
            for span in spans.sorted(by: { $0.lowerBound < $1.lowerBound }) {
                guard span.lowerBound == next else { throw LadderArchiveError.invalidArchive }
                next = span.upperBound
            }
            guard next == start else { throw LadderArchiveError.invalidArchive }
        }

        private func half(_ offset: Int) -> UInt16 {
            UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
        }
        private func word(_ offset: Int) -> UInt32 {
            (0..<4).reduce(0) { $0 | UInt32(bytes[offset + $1]) << (8 * $1) }
        }
        func read(_ entry: Entry) throws -> Data {
            let input = entry.dataOffset..<(entry.dataOffset + entry.compressedSize)
            let output: Data
            if entry.method == 0 {
                guard entry.size == entry.compressedSize else { throw LadderArchiveError.invalidArchive }
                output = bytes.subdata(in: input)
            } else {
                // One extra byte detects a stream larger than its declared size,
                // including an ostensibly empty deflate member.
                var decoded = Data(count: entry.size + 1)
                var stream = z_stream()
                guard inflateInit2_(&stream, -MAX_WBITS, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
                    throw LadderArchiveError.invalidArchive
                }
                defer { inflateEnd(&stream) }
                let result = bytes.withUnsafeBytes { source in
                    decoded.withUnsafeMutableBytes { target in
                        stream.next_in = UnsafeMutablePointer(mutating: source.bindMemory(to: Bytef.self).baseAddress!.advanced(by: input.lowerBound))
                        stream.avail_in = uInt(entry.compressedSize)
                        stream.next_out = target.bindMemory(to: Bytef.self).baseAddress!
                        stream.avail_out = uInt(entry.size + 1)
                        return inflate(&stream, Z_FINISH)
                    }
                }
                guard result == Z_STREAM_END, stream.total_in == entry.compressedSize,
                      stream.total_out == entry.size else { throw LadderArchiveError.invalidArchive }
                decoded.removeLast(); output = decoded
            }
            let crc = output.withUnsafeBytes { crc32(0, $0.bindMemory(to: Bytef.self).baseAddress, uInt(output.count)) }
            guard crc == entry.crc else { throw LadderArchiveError.invalidArchive }
            return output
        }
    }
}
