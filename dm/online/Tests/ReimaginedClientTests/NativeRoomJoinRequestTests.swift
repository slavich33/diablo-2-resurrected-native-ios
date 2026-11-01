import XCTest
@testable import ReimaginedClient

final class NativeRoomJoinRequestTests: XCTestCase {
    private func packet(password: String = "") -> Data {
        var bytes = Data((0..<85).map { UInt8($0) })
        bytes[0] = 0x68; bytes[2] = 1; bytes[3] = 0
        bytes.replaceSubrange(24..<85, with: Data(repeating: 0, count: 61))
        bytes.replaceSubrange(24..<(24 + password.utf8.count), with: password.utf8)
        return bytes
    }

    func testEmptyPasswordIsKeptEmptyWhileOnlyResolvedRoomSlotChanges() throws {
        let original = packet()
        let request = try NativeRoomJoinRequest(originalPacket: original)
        XCTAssertTrue(request.hasEmptyPassword)
        XCTAssertEqual(request.gameNumber, 1)
        for number in [1, 255, 256, 495, 1_024] as [UInt16] {
            let bound = try request.bindingResolvedGameNumber(number)
            XCTAssertEqual(try NativeRoomJoinRequest(originalPacket: bound).gameNumber, number)
            for index in 0..<85 where index != 2 && index != 3 {
                XCTAssertEqual(bound[index], original[index])
            }
        }
        XCTAssertEqual(request.originalPacket, original)
    }

    func testPasswordIsNotInterpretedAsCharacterIdentityOrOverwritten() throws {
        let original = packet(password: "Room 7")
        let request = try NativeRoomJoinRequest(originalPacket: (Data([99]) + original).dropFirst())
        XCTAssertFalse(request.hasEmptyPassword)
        let bound = try request.bindingResolvedGameNumber(512)
        XCTAssertEqual(bound[24...84], original[24...84])
        XCTAssertEqual(request.originalPacket, original)
    }

    func testMalformedNativeInputAndInvalidResolvedSlotsAreRejected() throws {
        for count in [0, 24, 84, 86] {
            XCTAssertThrowsError(try NativeRoomJoinRequest(originalPacket: Data(count: count))) {
                XCTAssertEqual($0 as? NativeRoomJoinRequestError, .wrongLength)
            }
        }
        var bytes = packet(); bytes[0] = 0x67
        XCTAssertThrowsError(try NativeRoomJoinRequest(originalPacket: bytes)) {
            XCTAssertEqual($0 as? NativeRoomJoinRequestError, .wrongOpcode)
        }
        bytes = packet(); bytes.replaceSubrange(24..<85, with: Data(repeating: 65, count: 61))
        XCTAssertThrowsError(try NativeRoomJoinRequest(originalPacket: bytes)) {
            XCTAssertEqual($0 as? NativeRoomJoinRequestError, .unterminatedPassword)
        }
        let request = try NativeRoomJoinRequest(originalPacket: packet())
        for number in [0, 1_025, UInt16.max] as [UInt16] {
            XCTAssertThrowsError(try request.bindingResolvedGameNumber(number)) {
                XCTAssertEqual($0 as? NativeRoomJoinRequestError, .invalidGameNumber)
            }
        }
    }
}
