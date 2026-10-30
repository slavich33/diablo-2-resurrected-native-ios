// 监听随机回环端口，验证 PKCE 回调；协议来自公开启动器，套接字仅绑定 127.0.0.1。
// Listen on a random loopback port and validate PKCE callbacks; public launcher contract, bound to 127.0.0.1 only.
import Foundation
import Darwin

public enum LoginListenerError: Error, Equatable {
    case socket(Int32), alreadyStarted, timedOut, cancelled
}

public final class LoopbackLogin: @unchecked Sendable {
    public let authorization: PKCEAuthorization
    private let descriptor: Int32
    private let lock = NSLock()
    private var started = false
    private var cancelled = false

    public init() throws {
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw LoginListenerError.socket(errno) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0, Darwin.listen(fd, 4) == 0 else {
            let code = errno; Darwin.close(fd); throw LoginListenerError.socket(code)
        }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.getsockname(fd, $0, &length) }
        }
        guard named == 0 else { let code = errno; Darwin.close(fd); throw LoginListenerError.socket(code) }
        do { authorization = try PKCEAuthorization(loopbackPort: UInt16(bigEndian: address.sin_port)) }
        catch { Darwin.close(fd); throw error }
        descriptor = fd
    }

    deinit { Darwin.close(descriptor) }

    public func cancel() { lock.lock(); cancelled = true; lock.unlock() }

    public func waitForCallback(timeout: TimeInterval = 180) async throws -> URL {
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                guard !started else { lock.unlock(); continuation.resume(throwing: LoginListenerError.alreadyStarted); return }
                started = true
                lock.unlock()
                DispatchQueue.global(qos: .userInitiated).async {
                    do { continuation.resume(returning: try self.receive(timeout: timeout)) }
                    catch { continuation.resume(throwing: error) }
                }
            }
        }, onCancel: { self.cancel() })
    }

    private func receive(timeout: TimeInterval) throws -> URL {
        let deadline = ProcessInfo.processInfo.systemUptime + max(0, timeout)
        while ProcessInfo.processInfo.systemUptime < deadline {
            lock.lock(); let stop = cancelled; lock.unlock()
            if stop { throw LoginListenerError.cancelled }
            var event = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            let result = Darwin.poll(&event, 1, 100)
            if result < 0 { if errno == EINTR { continue }; throw LoginListenerError.socket(errno) }
            if result == 0 { continue }
            let client = Darwin.accept(descriptor, nil, nil)
            if client < 0 { if errno == EINTR { continue }; throw LoginListenerError.socket(errno) }
            defer { Darwin.close(client) }
            var limit = timeval(tv_sec: 1, tv_usec: 0)
            setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &limit, socklen_t(MemoryLayout<timeval>.size))
            setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, &limit, socklen_t(MemoryLayout<timeval>.size))
            var one: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
            let requestDeadline = min(deadline, ProcessInfo.processInfo.systemUptime + 2)
            var request = Data(), block = [UInt8](repeating: 0, count: 1024)
            while request.count < 8192 && !request.containsHeadersEnd && ProcessInfo.processInfo.systemUptime < requestDeadline {
                let count = Darwin.recv(client, &block, min(block.count, 8192 - request.count), 0)
                if count <= 0 { break }
                request.append(contentsOf: block.prefix(count))
            }
            guard request.containsHeadersEnd, let text = String(data: request, encoding: .utf8),
                  let callback = callbackURL(request: text) else {
                respond(client, status: "400 Bad Request"); continue
            }
            do {
                _ = try authorization.code(from: callback)
                respond(client, status: "200 OK")
                return callback
            } catch AuthorizationError.providerRejected {
                respond(client, status: "400 Bad Request"); throw AuthorizationError.providerRejected
            } catch { respond(client, status: "400 Bad Request") }
        }
        throw LoginListenerError.timedOut
    }

    private func callbackURL(request: String) -> URL? {
        let lines = request.components(separatedBy: "\r\n")
        let first = (lines.first ?? "").split(separator: " ", omittingEmptySubsequences: false)
        guard first.count == 3, first[0] == "GET", first[2] == "HTTP/1.1", first[1].hasPrefix("/oauth/callback?") else { return nil }
        let hosts = lines.dropFirst().filter { $0.lowercased().hasPrefix("host:") }
        guard hosts.count == 1, hosts[0].dropFirst(5).trimmingCharacters(in: .whitespaces) == "127.0.0.1:\(authorization.redirectURL.port!)" else { return nil }
        return URL(string: String(first[1]), relativeTo: authorization.redirectURL)?.absoluteURL
    }

    private func respond(_ fd: Int32, status: String) {
        let body = status == "200 OK" ? "Authorization received. Return to the application." : "Callback not accepted."
        let response = "HTTP/1.1 \(status)\r\nContent-Type: text/plain; charset=utf-8\r\nCache-Control: no-store\r\nContent-Security-Policy: default-src 'none'\r\nConnection: close\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)"
        let data = Data(response.utf8)
        data.withUnsafeBytes { ptr in
            var position = 0
            while position < ptr.count {
                let sent = Darwin.send(fd, ptr.baseAddress!.advanced(by: position), ptr.count - position, 0)
                if sent <= 0 { break }
                position += sent
            }
        }
    }
}

private extension Data {
    var containsHeadersEnd: Bool { range(of: Data([13, 10, 13, 10])) != nil }
}
