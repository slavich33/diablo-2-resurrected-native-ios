// 独立实现的 D2RL v1 控制消息与环境分片；不是完整 TCP 游戏载荷。
// Independently implemented D2RL v1 control messages/environment fragments, not complete TCP game packets.
import Foundation

public enum ControlMessageError: Error, Equatable {
    case invalidSize, invalidMagic, unsupportedVersion, unsupportedKind, invalidReservedFields
    case lengthMismatch, invalidFragment, unexpectedFragment, transferAlreadyComplete
}

/// Control payload inside the loader's shared game-packet carrier. Transport
/// processing and native engine admission are deliberately not inferred.
public struct ControlMessage {
    public static let headerSize = 18, maximumPayload = 224
    public let kind: UInt8
    public let payload: Data

    public init(kind: UInt8, payload: Data) throws {
        guard (7...10).contains(kind) else { throw ControlMessageError.unsupportedKind }
        guard payload.count <= Self.maximumPayload else { throw ControlMessageError.invalidSize }
        self.kind = kind; self.payload = payload
    }

    public func encoded() -> Data {
        var data = Data([0x44, 0x32, 0x52, 0x4c, 1, kind])
        data.append(Data(repeating: 0, count: 10))
        data.append(UInt8(truncatingIfNeeded: payload.count))
        data.append(UInt8(truncatingIfNeeded: payload.count >> 8))
        data.append(payload)
        return data
    }

    /// Game-packet carrier used by the inspected client and server control
    /// senders, before transport-specific processing. Not a TCP record header.
    public func gameCarrier() -> Data {
        let body = encoded()
        return Data([0xd0, UInt8(truncatingIfNeeded: body.count), UInt8(truncatingIfNeeded: body.count >> 8)]) + body
    }

    public static func decodeGameCarrier(_ data: Data) throws -> ControlMessage {
        guard (21...245).contains(data.count) else { throw ControlMessageError.invalidSize }
        let bytes = Array(data)
        guard bytes[0] == 0xd0 else { throw ControlMessageError.invalidMagic }
        guard Int(bytes[1]) | Int(bytes[2]) << 8 == bytes.count - 3 else { throw ControlMessageError.lengthMismatch }
        return try decode(Data(bytes[3...]))
    }

    // Compatibility names retained for existing callers.
    public func clientCarrier() -> Data { gameCarrier() }
    public static func decodeClientCarrier(_ data: Data) throws -> ControlMessage {
        try decodeGameCarrier(data)
    }

    public static func decode(_ data: Data) throws -> ControlMessage {
        guard (headerSize...(headerSize + maximumPayload)).contains(data.count) else { throw ControlMessageError.invalidSize }
        let bytes = Array(data)
        guard Array(bytes[0..<4]) == [0x44, 0x32, 0x52, 0x4c] else { throw ControlMessageError.invalidMagic }
        guard bytes[4] == 1 else { throw ControlMessageError.unsupportedVersion }
        guard bytes[6..<16].allSatisfy({ $0 == 0 }) else { throw ControlMessageError.invalidReservedFields }
        let count = Int(bytes[16]) | Int(bytes[17]) << 8
        guard count == bytes.count - headerSize else { throw ControlMessageError.lengthMismatch }
        return try ControlMessage(kind: bytes[5], payload: Data(bytes[headerSize...]))
    }
}

public struct EnvironmentFragment {
    public static let maximumTotal = 65_536, maximumChunk = 216
    public let total: Int
    public let offset: Int
    public let bytes: Data

    public init(total: Int, offset: Int, bytes: Data) throws {
        guard (1...Self.maximumTotal).contains(total), (0..<total).contains(offset),
              (1...Self.maximumChunk).contains(bytes.count), bytes.count <= total - offset else {
            throw ControlMessageError.invalidFragment
        }
        self.total = total; self.offset = offset; self.bytes = bytes
    }

    public func encoded() -> Data {
        var data = Data()
        for value in [total, offset] {
            for shift in stride(from: 0, to: 32, by: 8) { data.append(UInt8(truncatingIfNeeded: value >> shift)) }
        }
        data.append(bytes)
        return data
    }

    public static func decode(_ data: Data) throws -> EnvironmentFragment {
        guard (9...224).contains(data.count) else { throw ControlMessageError.invalidFragment }
        let bytes = Array(data)
        func value(_ start: Int) -> Int { (0..<4).reduce(0) { $0 | Int(bytes[start + $1]) << ($1 * 8) } }
        return try EnvironmentFragment(total: value(0), offset: value(4), bytes: Data(bytes[8...]))
    }

    public static func split(_ environment: Data) throws -> [EnvironmentFragment] {
        guard (1...maximumTotal).contains(environment.count) else { throw ControlMessageError.invalidFragment }
        return try stride(from: 0, to: environment.count, by: maximumChunk).map { offset in
            try EnvironmentFragment(total: environment.count, offset: offset,
                                    bytes: environment.subdata(in: offset..<min(offset + maximumChunk, environment.count)))
        }
    }
}

/// Conservative ordered assembler for a single peer/connection. This is a
/// local memory policy, not a claim about the loader's complete receive FSM.
/// A caller must reset it on rejection, timeout, disconnect or a new peer.
public struct EnvironmentAssembly {
    private var total: Int?
    private var data = Data()
    private var complete = false
    public init() {}

    public mutating func append(_ fragment: EnvironmentFragment) throws -> Data? {
        guard !complete else { throw ControlMessageError.transferAlreadyComplete }
        guard fragment.offset == data.count, total == nil || total == fragment.total else {
            throw ControlMessageError.unexpectedFragment
        }
        if total == nil { total = fragment.total }
        data.append(fragment.bytes)
        if data.count == fragment.total { complete = true; return data }
        return nil
    }

    public mutating func reset() { total = nil; data.removeAll(keepingCapacity: false); complete = false }
}
