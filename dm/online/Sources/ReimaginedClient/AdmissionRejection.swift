import Foundation

public enum AdmissionRejectionError: Error, Equatable {
    case invalidCode, invalidFields, invalidLength, wrongControlKind
}

/// The observed kind-9 rejection body. Preserve its three bounded byte fields
/// without guessing their meaning or treating arbitrary bytes as display text.
/// A decoded rejection is a refusal, never admission or a save confirmation.
public struct AdmissionRejection: Equatable {
    public let code: UInt8
    public let details: [Data]

    public init(code: UInt8, details: [Data]) throws {
        guard (1...30).contains(code) else { throw AdmissionRejectionError.invalidCode }
        guard details.count == 3, details.allSatisfy({ $0.count <= 63 }) else {
            throw AdmissionRejectionError.invalidFields
        }
        self.code = code
        self.details = details
    }

    public static func decode(_ control: ControlMessage) throws -> AdmissionRejection {
        guard control.kind == 9 else { throw AdmissionRejectionError.wrongControlKind }
        let bytes = Array(control.payload)
        guard (4...193).contains(bytes.count), bytes.count == 4 + bytes[1...3].reduce(0, { $0 + Int($1) }) else {
            throw AdmissionRejectionError.invalidLength
        }
        var offset = 4, details: [Data] = []
        for length in bytes[1...3] {
            let end = offset + Int(length)
            details.append(Data(bytes[offset..<end])); offset = end
        }
        return try AdmissionRejection(code: bytes[0], details: details)
    }

    public func controlMessage() throws -> ControlMessage {
        var payload = Data([code] + details.map { UInt8($0.count) })
        for detail in details { payload.append(detail) }
        return try ControlMessage(kind: 9, payload: payload)
    }
}
