// 原生 TCP 字节流；游戏包边界与 D2RLoader 准入协议由上层处理。
// Native TCP byte stream; game packet boundaries and D2RLoader admission belong to the caller.
import Foundation
import Network
import Darwin

/// Nonblocking engine-facing transport. No connection is opened by app startup.
/// Receiving TCP bytes is not proof of game admission or of a saved character.
public final class GameTCPStream: @unchecked Sendable {
    public enum State: Int32 { case connecting = 1, ready, eof, closed, failed }
    public static let again = -1, closed = -2, failed = -3, invalid = -4, limit = -5
    public static let maximumChunk = 65_536, maximumBufferedBytes = 262_144
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "org.d2rmobile.game-tcp")
    private let connection: NWConnection
    private var deadline: DispatchWorkItem?
    private var currentState = State.connecting
    private var errorCode: Int32 = 0
    private var chunks: [Data] = []
    private var head = 0, headOffset = 0, buffered = 0, outbound = 0
    private var receiving = false // accessed only on queue

    public init?(host: String, port: UInt16, timeoutMilliseconds: UInt32 = 5_000) {
        guard !host.isEmpty, host.utf8.count <= 253,
              host.utf8.allSatisfy({ (33...126).contains($0) && !"/@?#\\".utf8.contains($0) }),
              let endpointPort = NWEndpoint.Port(rawValue: port), port != 0 else { return nil }
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        connection = NWConnection(host: NWEndpoint.Host(host), port: endpointPort,
                                  using: NWParameters(tls: nil, tcp: tcp))
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.lock.lock()
                if self.currentState == .connecting { self.currentState = .ready; self.errorCode = 0 }
                self.lock.unlock()
                self.deadline?.cancel()
                self.receiveNext()
            case .waiting(let error): self.record(error)
            case .failed(let error): self.finish(.failed, error: Self.code(error))
            case .cancelled: self.finish(.closed)
            default: break
            }
        }
        let timeout = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let connecting = self.currentState == .connecting
            self.lock.unlock()
            if connecting { self.finish(.failed, error: ETIMEDOUT) }
        }
        deadline = timeout
        let milliseconds = min(30_000, max(100, timeoutMilliseconds == 0 ? 5_000 : timeoutMilliseconds))
        queue.asyncAfter(deadline: .now() + .milliseconds(Int(milliseconds)), execute: timeout)
        connection.start(queue: queue)
    }

    deinit { deadline?.cancel(); connection.cancel() }

    public var state: State { lock.lock(); defer { lock.unlock() }; return currentState }
    public var lastError: Int32 { lock.lock(); defer { lock.unlock() }; return errorCode }

    /// Zero means accepted into the bounded send queue, not acknowledged by the peer.
    public func send(_ data: Data) -> Int {
        guard data.count <= Self.maximumChunk else { return Self.limit }
        lock.lock()
        guard currentState == .ready else {
            let result = terminalResult()
            lock.unlock(); return result
        }
        guard data.count <= Self.maximumBufferedBytes - outbound else { lock.unlock(); return Self.again }
        if data.isEmpty { lock.unlock(); return 0 }
        outbound += data.count
        lock.unlock()
        queue.async { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let ready = self.currentState == .ready
            if !ready { self.outbound = max(0, self.outbound - data.count) }
            self.lock.unlock()
            guard ready else { return }
            self.connection.send(content: data, completion: .contentProcessed { [weak self] error in
                guard let self else { return }
                self.lock.lock(); self.outbound = max(0, self.outbound - data.count); self.lock.unlock()
                if let error { self.finish(.failed, error: Self.code(error)) }
            })
        }
        return 0
    }

    /// Copies available bytes without blocking. TCP read chunks are not game packets.
    public func read(into destination: UnsafeMutableRawBufferPointer) -> Int {
        guard destination.count > 0, let base = destination.baseAddress else { return Self.invalid }
        lock.lock()
        guard buffered > 0 else { let result = terminalResult(); lock.unlock(); return result }
        let count = min(destination.count, buffered, Self.maximumChunk)
        var copied = 0
        while copied < count {
            let part = min(count - copied, chunks[head].count - headOffset)
            chunks[head].withUnsafeBytes { bytes in
                base.advanced(by: copied).copyMemory(from: bytes.baseAddress!.advanced(by: headOffset), byteCount: part)
            }
            copied += part; headOffset += part
            if headOffset == chunks[head].count { head += 1; headOffset = 0 }
        }
        buffered -= copied
        if head > 64 || head == chunks.count { chunks.removeFirst(head); head = 0 }
        lock.unlock()
        queue.async { [weak self] in self?.receiveNext() }
        return copied
    }

    public func close() {
        lock.lock()
        currentState = .closed
        chunks.removeAll(); head = 0; headOffset = 0; buffered = 0
        lock.unlock()
        deadline?.cancel()
        connection.cancel()
    }

    // lock must be held
    private func terminalResult() -> Int {
        switch currentState {
        case .connecting, .ready: return Self.again
        case .eof, .closed: return Self.closed
        case .failed: return Self.failed
        }
    }

    private func receiveNext() {
        guard !receiving else { return }
        lock.lock()
        let capacity = Self.maximumBufferedBytes - buffered
        let eligible = currentState == .ready && capacity > 0 && chunks.count - head < 1_024
        lock.unlock()
        guard eligible else { return } // pause reads; let TCP apply backpressure
        receiving = true
        connection.receive(minimumIncompleteLength: 1, maximumLength: min(capacity, Self.maximumChunk)) { [weak self] data, _, complete, error in
            guard let self else { return }
            self.receiving = false
            self.lock.lock()
            if self.currentState == .ready, let data, !data.isEmpty {
                self.chunks.append(data); self.buffered += data.count
            }
            self.lock.unlock()
            if let error { self.finish(.failed, error: Self.code(error)) }
            else if complete { self.finish(.eof) }
            else { self.receiveNext() }
        }
    }

    private func record(_ error: NWError) {
        lock.lock(); defer { lock.unlock() }
        if currentState == .connecting { errorCode = Self.code(error) }
    }

    private func finish(_ state: State, error: Int32 = 0) {
        lock.lock()
        if currentState == .connecting || currentState == .ready { currentState = state; errorCode = error }
        lock.unlock()
        deadline?.cancel()
        connection.cancel()
    }

    private static func code(_ error: NWError) -> Int32 {
        switch error {
        case .posix(let value): return value.rawValue
        case .dns(let value): return value
        case .tls(let value): return value
        default: return EIO
        }
    }
}

// C ABI used by native engine adapters; handles are owned and released by the caller.
@_cdecl("dm_online_tcp_open")
public func nativeGameTCPOpen(_ host: UnsafePointer<CChar>?, _ port: UInt16, _ timeout: UInt32) -> UnsafeMutableRawPointer? {
    guard let host, strnlen(host, 254) < 254, let text = String(validatingCString: host),
          let stream = GameTCPStream(host: text, port: port, timeoutMilliseconds: timeout) else { return nil }
    return Unmanaged.passRetained(stream).toOpaque()
}

@_cdecl("dm_online_tcp_state")
public func nativeGameTCPState(_ handle: UnsafeMutableRawPointer?) -> Int32 {
    guard let handle else { return Int32(GameTCPStream.invalid) }
    return Unmanaged<GameTCPStream>.fromOpaque(handle).takeUnretainedValue().state.rawValue
}

@_cdecl("dm_online_tcp_error")
public func nativeGameTCPError(_ handle: UnsafeMutableRawPointer?) -> Int32 {
    guard let handle else { return EINVAL }
    return Unmanaged<GameTCPStream>.fromOpaque(handle).takeUnretainedValue().lastError
}

@_cdecl("dm_online_tcp_send")
public func nativeGameTCPSend(_ handle: UnsafeMutableRawPointer?, _ bytes: UnsafeRawPointer?, _ count: UInt) -> Int32 {
    guard let handle, let bytes, count > 0 else { return Int32(GameTCPStream.invalid) }
    guard count <= GameTCPStream.maximumChunk else { return Int32(GameTCPStream.limit) }
    let stream = Unmanaged<GameTCPStream>.fromOpaque(handle).takeUnretainedValue()
    return Int32(stream.send(Data(bytes: bytes, count: Int(count))))
}

@_cdecl("dm_online_tcp_read")
public func nativeGameTCPRead(_ handle: UnsafeMutableRawPointer?, _ bytes: UnsafeMutableRawPointer?, _ capacity: UInt) -> Int32 {
    guard let handle, let bytes, capacity > 0 else { return Int32(GameTCPStream.invalid) }
    guard capacity <= GameTCPStream.maximumBufferedBytes else { return Int32(GameTCPStream.limit) }
    let stream = Unmanaged<GameTCPStream>.fromOpaque(handle).takeUnretainedValue()
    return Int32(stream.read(into: UnsafeMutableRawBufferPointer(start: bytes, count: Int(capacity))))
}

@_cdecl("dm_online_tcp_release")
public func nativeGameTCPRelease(_ handle: UnsafeMutableRawPointer?) {
    guard let handle else { return }
    Unmanaged<GameTCPStream>.fromOpaque(handle).takeRetainedValue().close()
}
