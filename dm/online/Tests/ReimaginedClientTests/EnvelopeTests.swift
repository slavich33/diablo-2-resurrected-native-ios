// 手写字节向量与畸形输入验证封装边界；不是来自生产会话的捕获包。
// Hand-authored byte vectors and malformed inputs verify envelope boundaries; no captured production session packets.
import XCTest
@testable import ReimaginedClient

final class EnvelopeTests: XCTestCase {
    let golden = Data([0x44, 0x32, 0x45, 0x4d, 3, 0, 9, 0, 0, 0, 1, 0x80, 3, 0, 0, 0, 0x61, 0x62, 0x63])

    func testHandAuthoredLittleEndianVector() throws {
        let decoded = try EnvironmentEnvelope.decode(golden)
        XCTAssertEqual(decoded.fields, [.init(id: 1, required: true, payload: Data("abc".utf8))])
        XCTAssertEqual(decoded.encoded(), golden)
    }

    func testHeaderAndBodyLengthRejection() throws {
        for count in 0..<10 { XCTAssertThrowsError(try EnvironmentEnvelope.decode(golden.prefix(count))) }
        var bytes = golden
        bytes[0] = 0
        XCTAssertThrowsError(try EnvironmentEnvelope.decode(bytes))
        bytes = golden
        bytes[4] = 2
        XCTAssertThrowsError(try EnvironmentEnvelope.decode(bytes))
        bytes = golden
        bytes[6] = 8
        XCTAssertThrowsError(try EnvironmentEnvelope.decode(bytes))
    }

    func testTruncatedFieldPayloadAndOversizedLength() throws {
        var bytes = golden
        bytes[12] = 4
        XCTAssertThrowsError(try EnvironmentEnvelope.decode(bytes))
        for n in 12...15 { bytes[n] = 0xff }
        XCTAssertThrowsError(try EnvironmentEnvelope.decode(bytes))
        bytes = Data([0x44, 0x32, 0x45, 0x4d, 3, 0, 1, 0, 0, 0, 1])
        XCTAssertThrowsError(try EnvironmentEnvelope.decode(bytes))
    }

    func testDuplicateAndInvalidMandatoryFields() throws {
        let field = EnvironmentField(id: 1, required: true, payload: Data())
        XCTAssertThrowsError(try EnvironmentEnvelope(fields: [field, field]))
        XCTAssertThrowsError(try EnvironmentEnvelope(fields: [.init(id: 0, required: false, payload: Data())]))
        XCTAssertThrowsError(try EnvironmentEnvelope(fields: [.init(id: 1, required: false, payload: Data())]))
        XCTAssertThrowsError(try EnvironmentEnvelope(fields: [.init(id: 19, required: true, payload: Data())]))
        XCTAssertThrowsError(try EnvironmentEnvelope(fields: [.init(id: 16, required: true, payload: Data())]))
    }

    func testUnknownOptionalFieldsArePreserved() throws {
        let fields = [EnvironmentField(id: 16, required: false, payload: Data([1, 2])),
                      EnvironmentField(id: 200, required: false, payload: Data([3, 4]))]
        let value = try EnvironmentEnvelope(fields: fields)
        XCTAssertEqual(try EnvironmentEnvelope.decode(value.encoded()).fields, fields)
    }

    func testMaximumFieldCountAndMessageSize() throws {
        let fields = (100..<164).map { EnvironmentField(id: UInt16($0), required: false, payload: Data()) }
        XCTAssertEqual(try EnvironmentEnvelope.decode(EnvironmentEnvelope(fields: fields).encoded()).fields.count, 64)
        XCTAssertThrowsError(try EnvironmentEnvelope(fields: fields + [.init(id: 164, required: false, payload: Data())]))
        let full = try EnvironmentEnvelope(fields: [.init(id: 1, required: true, payload: Data(repeating: 0, count: 65_520))])
        XCTAssertEqual(full.encoded().count, 65_536)
        XCTAssertEqual(try EnvironmentEnvelope.decode(full.encoded()).fields.count, 1)
        XCTAssertThrowsError(try EnvironmentEnvelope(fields: [.init(id: 1, required: true, payload: Data(repeating: 0, count: 65_521))]))
    }
}
