// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
// Compile with SocketTransport.swift.
import Darwin
import Foundation

// The FFI adapter is outside this test. SocketTransport itself is production code.
protocol Transport: Sendable {
    func call(method: String, params: String, patience: TimeInterval) throws -> String
    func callUrgent(method: String, params: String, patience: TimeInterval) throws -> String
    var describedAs: String { get }
}
enum BridgeError: Error {
    case core(code: String, message: String)
}

private final class ClosingServer: @unchecked Sendable {
    let path: String
    private let directory: URL
    private let listener: Int32
    private let finished = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var frames = 0

    init() throws {
        directory = URL(fileURLWithPath: "/tmp").appendingPathComponent("tokenstat-socket-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        path = directory.appendingPathComponent("host.sock").path
        listener = socket(AF_UNIX, SOCK_STREAM, 0)
        assert(listener >= 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let bytes = Array(path.utf8) + [0]
        withUnsafeMutableBytes(of: &address.sun_path) { target in
            assert(bytes.count <= target.count)
            target.copyBytes(from: bytes)
        }
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        assert(bound == 0 && listen(listener, 4) == 0)
        DispatchQueue.global().async { self.serve() }
    }

    deinit {
        close(listener)
        try? FileManager.default.removeItem(at: directory)
    }

    private func serve() {
        defer { finished.signal() }
        for index in 0..<2 {
            var descriptor = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
            guard poll(&descriptor, 1, index == 0 ? 5_000 : 300) > 0 else { return }
            let connection = accept(listener, nil, nil)
            guard connection >= 0 else { return }
            var timeout = timeval(tv_sec: 2, tv_usec: 0)
            setsockopt(connection, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            var noPipe: Int32 = 1
            setsockopt(connection, SOL_SOCKET, SO_NOSIGPIPE, &noPipe, socklen_t(MemoryLayout<Int32>.size))
            var request = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while !request.contains(10) {
                let count = read(connection, &buffer, buffer.count)
                if count <= 0 { break }
                request.append(contentsOf: buffer.prefix(count))
            }
            if !request.isEmpty { lock.lock(); frames += 1; lock.unlock() }
            // Lose the first answer after reading the request. If the client
            // retries, return success so the test sees the unsafe replay.
            if index == 1 {
                let answer = Data("{\"ok\":true,\"result\":{}}\n".utf8)
                answer.withUnsafeBytes { raw in _ = write(connection, raw.baseAddress, raw.count) }
            }
            close(connection)
        }
    }

    func requestCount() -> Int {
        assert(finished.wait(timeout: .now() + 5) == .success)
        lock.lock(); defer { lock.unlock() }
        return frames
    }
}

@main struct SocketTransportTests {
    static func main() throws {
        for pooled in [false, true] {
            for remote in [false, true] {
                let server = try ClosingServer()
                let transport = pooled ? SocketTransport.connecting(to: server.path)! : SocketTransport(path: server.path)
                let method = remote ? "remote.call" : "chat.send"
                let params = remote ? #"{"peer":"fixture","method":"chat.send","params":{"id":"conversation"}}"# : #"{"id":"conversation"}"#
                do {
                    _ = try transport.call(method: method, params: params, patience: 2)
                    assertionFailure("A lost send response was replayed")
                } catch BridgeError.core(let code, _) {
                    assert(code == "delivery_unknown", code)
                }
                assert(server.requestCount() == 1)
            }
        }
        let urgent = try ClosingServer()
        do {
            _ = try SocketTransport(path: urgent.path).callUrgent(method: "chat.send", params: "{}", patience: 2)
            assertionFailure("Urgent send lost its uncertainty")
        } catch BridgeError.core(let code, _) { assert(code == "delivery_unknown", code) }
        assert(urgent.requestCount() == 1)

        // Read-only calls retain the ordinary pooled-connection repair path.
        let reader = try ClosingServer()
        let reading = SocketTransport.connecting(to: reader.path)!
        let response = try reading.call(method: "remote.call", params: #"{"method":"protocol","params":{"text":"chat.send"}}"#, patience: 2)
        assert(response.contains("true") && reader.requestCount() == 2)
        do {
            _ = try SocketTransport(path: reader.path + ".missing").call(method: "chat.send", params: "{}", patience: 2)
            assertionFailure("Connected to a missing socket")
        } catch BridgeError.core(let code, _) { assert(code == "host_unreachable", code) }
        print("Socket transport: written sends are never replayed after disconnect; direct, forwarded, pooled and urgent calls preserve uncertainty")
    }
}
