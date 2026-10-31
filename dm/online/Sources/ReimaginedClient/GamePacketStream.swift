import Foundation

public enum GamePacketStreamError: Error, Equatable {
    case bufferFull, inputEnded, truncatedPacket, invalidLength, unsupportedPacket(UInt8)
}

/// The original engine must supply the length of ordinary game packets.
/// Returning needMore does not consume input or authorize gameplay.
public enum GamePacketLength {
    case length(Int)
    case needMore
    case unsupported
}

public enum DecodedGamePacket {
    case control(ControlMessage)
    case gameplay(Data)
}

/// Single-consumer incremental decoder at the *game-packet* layer. Feed bytes
/// only after any TCP transport framing/compression has been removed. A stock
/// packet-size resolver is required; unknown packets are never skipped/scanned
/// for magic. Control parsing does not implement or grant environment admission.
public final class GamePacketStream {
    public static let maximumPacketBytes = 65_536
    public static let maximumBufferedBytes = 262_144
    public static let maximumHeaderBytes = 512
    public typealias LengthResolver = (Data) -> GamePacketLength

    private let resolve: LengthResolver
    private var storage = Data()
    private var offset = 0
    private var ended = false
    private var failure: Error?

    public init(resolvePacketLength: @escaping LengthResolver) {
        resolve = resolvePacketLength
    }

    public var bufferedBytes: Int { storage.count - offset }

    /// Atomic acceptance: bufferFull leaves the stream unchanged so the caller
    /// may drain complete packets and retry the *same* input. No silent drops.
    public func append(_ bytes: Data) throws {
        if let failure { throw failure }
        guard !ended else { throw GamePacketStreamError.inputEnded }
        guard bytes.count <= Self.maximumBufferedBytes - bufferedBytes else {
            throw GamePacketStreamError.bufferFull
        }
        if offset > 0 { storage = Data(storage.dropFirst(offset)); offset = 0 }
        storage.append(bytes)
    }

    public func endOfInput() { ended = true }

    /// At most one packet per call keeps engine work per poll bounded. nil
    /// means more bytes are needed (or input ended cleanly with nothing left).
    /// A malformed/truncated packet makes the decoder terminal; reconnect with
    /// a new instance instead of trying to resynchronize inside gameplay data.
    public func nextPacket() throws -> DecodedGamePacket? {
        if let failure { throw failure }
        guard bufferedBytes > 0 else { return nil }
        do {
            let header = Data(storage.dropFirst(offset).prefix(Self.maximumHeaderBytes))
            let control = header[0] == 0xd0
            let length: Int
            if control {
                guard header.count >= 3 else { return try incomplete() }
                length = 3 + Int(header[1]) + (Int(header[2]) << 8)
                guard (21...245).contains(length) else { throw GamePacketStreamError.invalidLength }
            } else {
                switch resolve(header) {
                case .length(let count): length = count
                case .needMore:
                    // The resolver sees at most 512 bytes. Asking for more
                    // after that cannot make progress; never spin forever.
                    guard header.count < Self.maximumHeaderBytes else { throw GamePacketStreamError.invalidLength }
                    return try incomplete()
                case .unsupported: throw GamePacketStreamError.unsupportedPacket(header[0])
                }
                guard (1...Self.maximumPacketBytes).contains(length) else { throw GamePacketStreamError.invalidLength }
            }
            guard bufferedBytes >= length else { return try incomplete() }
            let bytes = storage.subdata(in: offset..<(offset + length))
            let packet: DecodedGamePacket = control ? .control(try ControlMessage.decodeGameCarrier(bytes)) : .gameplay(bytes)
            offset += length
            if offset == storage.count { storage.removeAll(keepingCapacity: false); offset = 0 }
            return packet
        } catch {
            failure = error
            storage.removeAll(keepingCapacity: false); offset = 0
            throw error
        }
    }

    private func incomplete() throws -> DecodedGamePacket? {
        if ended { throw GamePacketStreamError.truncatedPacket }
        return nil
    }
}
