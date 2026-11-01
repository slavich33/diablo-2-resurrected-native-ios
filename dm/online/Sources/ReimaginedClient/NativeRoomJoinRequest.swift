import Foundation

public enum NativeRoomJoinRequestError: Error, Equatable {
    case wrongLength, wrongOpcode, unterminatedPassword, invalidGameNumber
}

/// The original supported ARM64 engine's 85-byte room-join request.
/// Bytes24...84 contain the room password, not the selected character name.
/// This wrapper never creates a request or changes its password/platform data.
/// Parsing and binding a resolved room do not establish server admission.
public struct NativeRoomJoinRequest {
    private let bytes: [UInt8]

    public init(originalPacket: Data) throws {
        guard originalPacket.count == 85 else { throw NativeRoomJoinRequestError.wrongLength }
        let bytes = Array(originalPacket)
        guard bytes[0] == 0x68 else { throw NativeRoomJoinRequestError.wrongOpcode }
        guard bytes[24...84].contains(0) else { throw NativeRoomJoinRequestError.unterminatedPassword }
        self.bytes = bytes
    }

    public var originalPacket: Data { Data(bytes) }
    public var gameNumber: UInt16 { UInt16(bytes[2]) | UInt16(bytes[3]) << 8 }
    public var hasEmptyPassword: Bool { bytes[24] == 0 }

    /// The coordinator must supply a fresh authenticated resolve result for
    /// the selected room and independently check its eligibility and save scope.
    /// Only the room slot changes; all other original engine bytes are retained.
    public func bindingResolvedGameNumber(_ gameNumber: UInt16) throws -> Data {
        guard (1...1_024).contains(gameNumber) else { throw NativeRoomJoinRequestError.invalidGameNumber }
        var result = bytes
        result[2] = UInt8(truncatingIfNeeded: gameNumber)
        result[3] = UInt8(truncatingIfNeeded: gameNumber >> 8)
        return Data(result)
    }
}
