import XCTest
import Network
import Darwin
@testable import ReimaginedClient

final class GameTransportTests: XCTestCase {
    private final class PeerHolder: @unchecked Sendable {
        private let lock = NSLock()
        private var connection: NWConnection?
        func set(_ value: NWConnection) { lock.lock(); connection = value; lock.unlock() }
        func cancel() { lock.lock(); let value = connection; lock.unlock(); value?.cancel() }
    }
    private func until(_ predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !predicate() {
            guard Date() < deadline else { throw NSError(domain: "TransportTestTimeout", code: 1) }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    func testCABIByteStreamPreservesDataAcrossBackpressureAndEOF() async throws {
        let listener = try NWListener(using: .tcp, on: .any)
        let queue = DispatchQueue(label: "transport-test-peer")
        let listening = expectation(description: "listener ready")
        let requestReceived = expectation(description: "peer receives client bytes")
        let request = try ControlMessage(kind: 7, payload: Data([1, 2, 3, 4])).clientCarrier()
        let expectedRequest = Data([0xd0, 22, 0, 0x44, 0x32, 0x52, 0x4c, 1, 7])
            + Data(repeating: 0, count: 10) + Data([4, 0, 1, 2, 3, 4])
        let reply = Data((0..<600_000).map { UInt8(truncatingIfNeeded: $0) })
        listener.stateUpdateHandler = { if case .ready = $0 { listening.fulfill() } }
        let peer = PeerHolder()
        listener.newConnectionHandler = { connection in
            peer.set(connection)
            var received = Data()
            func next() {
                connection.receive(minimumIncompleteLength: 1, maximumLength: 7) { data, _, _, error in
                    if let data { received.append(data) }
                    guard error == nil else { XCTFail("peer receive failed"); return }
                    if received.count < request.count { next(); return }
                    XCTAssertEqual(received, expectedRequest)
                    requestReceived.fulfill()
                    connection.send(content: reply, contentContext: .finalMessage, isComplete: true,
                                    completion: .contentProcessed { error in XCTAssertNil(error) })
                }
            }
            connection.start(queue: queue)
            next()
        }
        listener.start(queue: queue)
        defer { peer.cancel(); listener.cancel() }
        await fulfillment(of: [listening], timeout: 3)
        let port = try XCTUnwrap(listener.port?.rawValue)
        let handle = try XCTUnwrap("127.0.0.1".withCString { nativeGameTCPOpen($0, UInt32(port), 2_000) })
        defer { nativeGameTCPRelease(handle) }
        try await until { nativeGameTCPState(handle) == GameTCPStream.State.ready.rawValue }
        XCTAssertEqual(request.withUnsafeBytes { nativeGameTCPSend(handle, $0.baseAddress, UInt($0.count)) }, 0)
        await fulfillment(of: [requestReceived], timeout: 3)
        // Fill the 256 KiB receive queue before polling from the engine side.
        try await Task.sleep(nanoseconds: 100_000_000)
        var output = Data(), buffer = [UInt8](repeating: 0, count: 4_093)
        try await until {
            let count = buffer.withUnsafeMutableBytes { nativeGameTCPRead(handle, $0.baseAddress, UInt($0.count)) }
            if count > 0 { output.append(contentsOf: buffer.prefix(Int(count))) }
            else { XCTAssertTrue(count == GameTCPStream.again || count == GameTCPStream.closed) }
            return output.count == reply.count && nativeGameTCPState(handle) == GameTCPStream.State.eof.rawValue
        }
        XCTAssertEqual(output, reply)
        XCTAssertEqual(buffer.withUnsafeMutableBytes { nativeGameTCPRead(handle, $0.baseAddress, UInt($0.count)) }, Int32(GameTCPStream.closed))
        XCTAssertEqual(nativeGameTCPError(handle), 0)
    }

    func testRefusedConnectionAndExplicitCloseAreObservable() async throws {
        let socketFD = socket(AF_INET, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(socketFD, 0)
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(socketFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        XCTAssertEqual(bound, 0)
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(socketFD, $0, &length) } }
        XCTAssertEqual(named, 0)
        Darwin.close(socketFD)
        let stream = try XCTUnwrap(GameTCPStream(host: "127.0.0.1", port: UInt16(bigEndian: address.sin_port), timeoutMilliseconds: 500))
        try await until { stream.state == .failed }
        XCTAssertNotEqual(stream.lastError, 0)
        var bytes = [UInt8](repeating: 0, count: 3)
        XCTAssertEqual(bytes.withUnsafeMutableBytes { stream.read(into: $0) }, GameTCPStream.failed)
        stream.close()
        XCTAssertEqual(stream.state, .closed)
        XCTAssertEqual(bytes.withUnsafeMutableBytes { stream.read(into: $0) }, GameTCPStream.closed)
        XCTAssertEqual(stream.send(Data([1])), GameTCPStream.closed)
    }

    func testCABIRejectsInvalidEndpointsAndOversizedBuffers() throws {
        XCTAssertNil(nativeGameTCPOpen(nil, 4_000, 1_000))
        XCTAssertNil("https://example.test".withCString { nativeGameTCPOpen($0, 4_000, 1_000) })
        XCTAssertNil("127.0.0.1".withCString { nativeGameTCPOpen($0, 0, 1_000) })
        XCTAssertNil("127.0.0.1".withCString { nativeGameTCPOpen($0, 65_536, 1_000) })
        let handle = try XCTUnwrap("127.0.0.1".withCString { nativeGameTCPOpen($0, 1, 100) })
        defer { nativeGameTCPRelease(handle) }
        var byte: UInt8 = 0
        XCTAssertEqual(nativeGameTCPSend(handle, &byte, UInt.max), Int32(GameTCPStream.limit))
        XCTAssertEqual(nativeGameTCPRead(handle, &byte, UInt.max), Int32(GameTCPStream.limit))
        XCTAssertEqual(nativeGameTCPRead(nil, &byte, 1), Int32(GameTCPStream.invalid))
    }
}
