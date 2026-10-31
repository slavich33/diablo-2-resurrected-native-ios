// Offline replay of a trusted, private original-engine packet capture.
// No network, authentication, engine startup or save writes are performed.
// Build alongside ControlMessage, LoaderFrame, GamePacketStream and
// StockServerPacketLengths. Never publish the captured game payloads.
import Foundation
import CryptoKit

private enum CaptureFailure: Error { case arguments, size, record, mismatch }
private struct Record: Decodable {
    let sequence: Int
    let direction: String
    let id: Int
    let length: Int
    let payload: String
}

@main private enum PacketCaptureCheck {
    private static func nibble(_ byte: UInt8) throws -> UInt8 {
        switch byte {
        case 48...57: return byte - 48
        case 65...70: return byte - 55
        case 97...102: return byte - 87
        default: throw CaptureFailure.record
        }
    }

    private static func check() throws {
        guard CommandLine.arguments.count == 2 else { throw CaptureFailure.arguments }
        let source = try FileHandle(forReadingFrom: URL(fileURLWithPath: CommandLine.arguments[1]))
        defer { try? source.close() }
        let maximum = 32 * 1024 * 1024
        var capture = Data()
        while let part = try source.read(upToCount: min(65_536, maximum + 1 - capture.count)), !part.isEmpty {
            capture.append(part)
            guard capture.count <= maximum else { throw CaptureFailure.size }
        }
        guard let text = String(data: capture, encoding: .utf8) else { throw CaptureFailure.record }
        let lines = text.split(separator: "\n")
        guard !lines.isEmpty, lines.count <= 10_000 else { throw CaptureFailure.size }
        var packets: [Data] = [], previous = 0, total = 0
        for line in lines {
            let row = try JSONDecoder().decode(Record.self, from: Data(line.utf8))
            guard row.sequence == previous + 1, row.direction == "s2c-game", (0...255).contains(row.id),
                  (1...65_536).contains(row.length) else { throw CaptureFailure.record }
            previous = row.sequence
            let hex = Array(row.payload.utf8)
            guard hex.count == 2 * row.length else { throw CaptureFailure.record }
            var packet = Data(); packet.reserveCapacity(row.length)
            for index in stride(from: 0, to: hex.count, by: 2) {
                packet.append(try (nibble(hex[index]) << 4) | nibble(hex[index + 1]))
            }
            guard Int(packet[0]) == row.id else { throw CaptureFailure.record }
            total += packet.count
            guard total <= 8 * 1024 * 1024 else { throw CaptureFailure.size }
            packets.append(packet)
        }
        var streamBytes = Data(); streamBytes.reserveCapacity(total)
        for packet in packets { streamBytes.append(packet) }
        let chunks = [1, 2, 3, 7, 31, 127, 512, 4096, 65_536]
        for chunk in chunks {
            let stream = GamePacketStream(resolvePacketLength: StockServerPacketLengths.resolve)
            var read = 0
            func drain() throws {
                while let decoded = try stream.nextPacket() {
                    guard case .gameplay(let packet) = decoded, read < packets.count,
                          packet == packets[read] else { throw CaptureFailure.mismatch }
                    read += 1
                }
            }
            for offset in stride(from: 0, to: streamBytes.count, by: chunk) {
                try stream.append(streamBytes.subdata(in: offset..<min(offset + chunk, streamBytes.count)))
                try drain()
            }
            stream.endOfInput(); try drain()
            guard read == packets.count, stream.bufferedBytes == 0 else { throw CaptureFailure.mismatch }
        }
        let opcodes = Set(packets.map { $0[0] })
        let report: [String: Any] = [
            "captureSHA256": SHA256.hash(data: capture).map { String(format: "%02x", $0) }.joined(),
            "packets": packets.count, "bytes": total, "chunkSizes": chunks,
            "exactPacketComparisons": packets.count * chunks.count,
            "coveredVariableOpcodes": StockServerPacketLengths.supportedVariableOpcodes.filter(opcodes.contains).map { String(format: "0x%02x", $0) },
            "allPacketBytesAndBoundariesMatched": true, "gameAdmissionVerified": false,
        ]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        FileHandle.standardOutput.write(data + Data([10]))
    }

    static func main() {
        do { try check() }
        catch {
            // Never print packet bytes, character names or arbitrary decoded data.
            FileHandle.standardError.write(Data("Private capture replay failed: \(type(of: error))\n".utf8))
            exit(1)
        }
    }
}
