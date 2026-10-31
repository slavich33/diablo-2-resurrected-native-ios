// Offline required-field compatibility check against a synthetic original-core
// corpus. No network, authentication, engine entry or character access.
import Foundation

private enum VerificationFailure: Error { case arguments, size, corpus, mismatch(Int) }
private struct Corpus: Decodable {
    struct Entry: Decodable { let envelopeHex: String; let accepted: Bool }
    let referenceSHA256: String
    let cases: [Entry]
}

@main private enum EnvironmentDescriptionCheck {
    static func main() {
        do { try check() }
        catch { fputs("Required-environment reference verification failed: \(type(of: error))\n", stderr); exit(1) }
    }

    private static func check() throws {
        guard CommandLine.arguments.count == 2 else { throw VerificationFailure.arguments }
        let file = try FileHandle(forReadingFrom: URL(fileURLWithPath: CommandLine.arguments[1]))
        defer { try? file.close() }
        let data = try file.read(upToCount: 8 * 1024 * 1024 + 1) ?? Data()
        guard data.count <= 8 * 1024 * 1024 else { throw VerificationFailure.size }
        let corpus = try JSONDecoder().decode(Corpus.self, from: data)
        guard corpus.referenceSHA256 == "2a868d013d2e0830bd2d9e04b918b19e46a73cf726c833e70d089b948fdeb5a2",
              !corpus.cases.isEmpty, corpus.cases.count <= 4096 else { throw VerificationFailure.corpus }
        var accepted = 0
        for (index, entry) in corpus.cases.enumerated() {
            let text = Array(entry.envelopeHex.utf8)
            guard text.count.isMultiple(of: 2), text.count <= 2 * EnvironmentEnvelope.maximumBytes else { throw VerificationFailure.size }
            func nibble(_ byte: UInt8) throws -> UInt8 {
                switch byte {
                case 48...57: return byte - 48
                case 65...70: return byte - 55
                case 97...102: return byte - 87
                default: throw VerificationFailure.corpus
                }
            }
            var bytes = Data(); bytes.reserveCapacity(text.count / 2)
            for offset in stride(from: 0, to: text.count, by: 2) { bytes.append(try nibble(text[offset]) << 4 | nibble(text[offset + 1])) }
            let result: EnvironmentDescription?
            do { result = try EnvironmentDescription.decode(EnvironmentEnvelope.decode(bytes)) }
            catch { result = nil }
            guard (result != nil) == entry.accepted else { throw VerificationFailure.mismatch(index) }
            if let result {
                // This corpus has canonical outer field order and no named
                // records; it does not claim their full metadata equivalence.
                guard try result.envelope().encoded() == bytes else { throw VerificationFailure.mismatch(index) }
                accepted += 1
            }
        }
        print("Required D2EM reference:", corpus.cases.count, "cases matched;", accepted, "accepted. Admission remains unverified.")
    }
}
