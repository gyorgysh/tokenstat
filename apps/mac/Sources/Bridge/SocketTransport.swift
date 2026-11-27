// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import Darwin
import Foundation


/// A daemon on this machine, over its unix socket.
///
/// Preferred whenever one is running. The daemon runs under launchd, so a
/// terminal session belongs to it rather than to this window: closing the app
/// leaves an agent running, and reopening it finds the session again. That is
/// the whole reason this exists, and it is why a socket that fails mid-session
/// **does not silently fall back to the in-process bridge**. Falling back would
/// strand every host-owned process behind an interface that had quietly started
/// answering from somewhere else, which reads as sessions vanishing.
///
/// Framing is the daemon's: one JSON request per line, one response per line,
/// with the request id echoed back.
final class SocketTransport: Transport, @unchecked Sendable {
    private let lock = NSCondition()
    private var idle: [Connection] = []
    private var live = 0

    private static let maxIdle = 8

    private static let maxLive = 16

    private static let maxRemoteLive = 6

    private var remoteLive = 0

    let path: String
    private let expectedProtocolVersion: String?

    var describedAs: String { L10n.text("apple.sockettransport.daemon_at_0.3313a150", "\(path)") }

    init(path: String, expectedProtocolVersion: String? = nil) {
        self.path = path
        self.expectedProtocolVersion = expectedProtocolVersion
    }

    static func connecting(to path: String, expectedProtocolVersion: String? = nil) -> SocketTransport? {
        guard let probe = try? Connection(path: path) else { return nil }
        let transport = SocketTransport(path: path, expectedProtocolVersion: expectedProtocolVersion)
        transport.idle.append(probe)
        transport.live = 1
        return transport
    }

    func call(method: String, params: String, patience: TimeInterval) throws -> String {
        let remote = Self.isRemote(method, params)
        if remote { try beginRemote(patience: patience) }
        defer { if remote { endRemote() } }

        let request = Self.line(method: method, params: params)


        var reserved = false
        if let pooled = try acquire(patience: patience) {
            do {
                pooled.patience = patience
                let response = try roundTrip(request, method: method, on: pooled)
                release(pooled, reusable: !Self.isBusyRefusal(response))
                return response
            } catch let error as ProtocolMismatch {
                release(pooled, reusable: false)
                throw error.failure
            } catch TransportFailure.timedOut {
                release(pooled, reusable: false)
                throw Self.silence(path: path, patience: patience)
            } catch {
                release(pooled, reusable: false)
                if Self.isMutating(method, params), pooled.wroteRequestBytes { throw Self.uncertainSend() }
            }
        } else {
            reserved = true
        }

        if !reserved {
            try reserve(patience: patience)
        }

        let fresh: Connection
        do {
            fresh = try open()
        } catch {
            abandonReservation()
            throw Self.unreachable(path: path)
        }
        do {
            fresh.patience = patience
            let response = try roundTrip(request, method: method, on: fresh)
            release(fresh, reusable: !Self.isBusyRefusal(response))
            return response
        } catch let error as ProtocolMismatch {
            release(fresh, reusable: false)
            throw error.failure
        } catch TransportFailure.timedOut {
            release(fresh, reusable: false)
            throw Self.silence(path: path, patience: patience)
        } catch {
            release(fresh, reusable: false)
            if Self.isMutating(method, params), fresh.wroteRequestBytes { throw Self.uncertainSend() }
            throw Self.unreachable(path: path)
        }
    }

    func callUrgent(method: String, params: String, patience: TimeInterval) throws -> String {
        let request = Self.line(method: method, params: params)
        reserveUrgent()
        let fresh: Connection
        do {
            fresh = try open()
        } catch {
            abandonReservation()
            throw Self.unreachable(path: path)
        }
        do {
            fresh.patience = patience
            let response = try roundTrip(request, method: method, on: fresh)
            release(fresh, reusable: false)
            return response
        } catch let error as ProtocolMismatch {
            release(fresh, reusable: false)
            throw error.failure
        } catch TransportFailure.timedOut {
            release(fresh, reusable: false)
            throw Self.silence(path: path, patience: patience)
        } catch {
            release(fresh, reusable: false)
            if Self.isMutating(method, params), fresh.wroteRequestBytes { throw Self.uncertainSend() }
            throw Self.unreachable(path: path)
        }
    }

    private func roundTrip(_ request: Data, method: String, on connection: Connection) throws -> String {
        if method != "protocol", !connection.verifiedProtocol,
           let expectedProtocolVersion, !expectedProtocolVersion.isEmpty {
            let response = try connection.probeProtocol(Self.line(method: "protocol", params: "{}"))
            if Self.isBusyRefusal(response) { return response }
            struct Reply: Decodable {
                struct Spoken: Decodable { let protocolVersion: String }
                let ok: Bool
                let result: Spoken?
            }
            guard let reply = try? JSONDecoder().decode(Reply.self, from: Data(response.utf8)),
                  reply.ok, reply.result?.protocolVersion == expectedProtocolVersion else {
                throw ProtocolMismatch()
            }
            connection.verifiedProtocol = true
        }
        return try connection.roundTrip(request)
    }

    private struct ProtocolMismatch: Error {
        var failure: BridgeError {
            .core(code: "host_incompatible", message: L10n.text("apple.sockettransport.the_local_helper_does_not_match_this_versi.6fef0842"))
        }
    }

    private static func uncertainSend() -> BridgeError {
        .core(code: "delivery_unknown", message: L10n.text("apple.sockettransport.the_connection_closed_before_message_deliv.f49363c3"))
    }

    private static let mutatingMethods: Set<String> = [
        "chat.send", "chat.compact", "chat.steerSend",
        "workspace.commit",
        "todo.delegate",
        "automation.run",
        "pty.write",
        "ssh.session.write",
        "pulls.merge",
        "workflow.run",
        "pty.spawn",
        "ssh.session.open",
        "chat.create",
        "chat.fork",
        "chat.continueInNew",
        "automation.create",
        "workflow.create",
        "workflow.continue",
        "workflow.design",
        "todo.create",
        "pulls.create",
        "pulls.comment",
        "pulls.review",
        "launcher.signIn",
        "profiles.create",
        "profiles.delete",
        "launcher.install",
        "launcher.update",
        "launcher.reinstall",
        "workspace.lfsSetup",
        "chat.personaDraft",
        "screen.viewer.input",
        "ssh.vault.password.set",
        "ssh.vault.recovery.rotate",
    ]

    private static func isMutating(_ method: String, _ params: String) -> Bool {
        if mutatingMethods.contains(method) { return true }
        guard method == "remote.call", let data = params.data(using: .utf8),
              let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        return (value["method"] as? String).map(mutatingMethods.contains) ?? false
    }

    private static func silence(path: String, patience: TimeInterval) -> BridgeError {
        BridgeError.core(
            code: "host_timeout",
            message: L10n.text("apple.sockettransport.the_tokenstat_host_at_0_said_nothing_for_1.24074cf5", "\(path)", "\(Int(patience))")
        )
    }

    private static func unreachable(path: String) -> BridgeError {
        BridgeError.core(
            code: "host_unreachable",
            message: L10n.text("apple.sockettransport.the_tokenstat_host_is_not_answering_at_0_t.a338f925", "\(path)")
        )
    }

    private static func isBusyRefusal(_ response: String) -> Bool {
        guard response.contains("host_busy") else { return false }
        struct Failure: Decodable { let code: String }
        struct Refusal: Decodable {
            let ok: Bool
            let error: Failure?
        }
        guard let refusal = try? JSONDecoder().decode(Refusal.self, from: Data(response.utf8)) else {
            return false
        }
        return !refusal.ok && refusal.error?.code == "host_busy"
    }

    private static func isRemote(_ method: String, _ params: String) -> Bool {
        if method.hasPrefix("remote.") { return true }
        if params.contains(":\"remote:") { return true }
        return params.contains("\"peer\":")
    }

    private func beginRemote(patience: TimeInterval) throws {
        lock.lock()
        defer { lock.unlock() }
        let deadline = Date().addingTimeInterval(patience)
        while remoteLive >= Self.maxRemoteLive {
            if !lock.wait(until: deadline) {
                throw Self.silence(path: path, patience: patience)
            }
        }
        remoteLive += 1
    }

    private func endRemote() {
        lock.lock()
        remoteLive -= 1
        lock.broadcast()
        lock.unlock()
    }

    private func acquire(patience: TimeInterval) throws -> Connection? {
        lock.lock()
        defer { lock.unlock() }
        let deadline = Date().addingTimeInterval(patience)
        while true {
            if let pooled = idle.popLast() { return pooled }
            if live < Self.maxLive {
                live += 1
                return nil
            }
            if !lock.wait(until: deadline) {
                throw Self.silence(path: path, patience: patience)
            }
        }
    }

    private func open() throws -> Connection {
        try Connection(path: path)
    }

    private func reserve(patience: TimeInterval) throws {
        lock.lock()
        defer { lock.unlock() }
        let deadline = Date().addingTimeInterval(patience)
        while live >= Self.maxLive {
            if !lock.wait(until: deadline) {
                throw Self.silence(path: path, patience: patience)
            }
        }
        live += 1
    }

    private func reserveUrgent() {
        lock.lock()
        live += 1
        lock.unlock()
    }

    private func abandonReservation() {
        lock.lock()
        live -= 1
        lock.broadcast()
        lock.unlock()
    }

    private func release(_ connection: Connection, reusable: Bool) {
        lock.lock()
        defer {
            lock.broadcast()
            lock.unlock()
        }
        if reusable, idle.count < Self.maxIdle {
            idle.append(connection)
        } else {
            live -= 1
        }
    }

    private static func line(method: String, params: String) -> Data {
        let body = params.isEmpty ? "{}" : params
        let name = String(
            decoding: (try? JSONSerialization.data(withJSONObject: [method])) ?? Data(),
            as: UTF8.self
        )
        let quoted = name.dropFirst().dropLast()
        var line = Data("{\"id\":0,\"method\":\(quoted),\"params\":\(body)}".utf8)
        line.append(0x0A)
        return line
    }
}


private final class Connection {
    private let fd: Int32
    var verifiedProtocol = false
    private var pending = Data()

    var patience: TimeInterval = 0 {
        didSet {
            guard patience != oldValue else { return }
            var timeout = timeval(
                tv_sec: Int(patience),
                tv_usec: Int32((patience - patience.rounded(.down)) * 1_000_000)
            )
            let size = socklen_t(MemoryLayout<timeval>.size)
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, size)
            setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, size)
        }
    }

    init(path: String) throws {
        let bytes = Array(path.utf8)
        // A unix address is a fixed struct, and macOS caps the path near 104
        // bytes. The daemon checks this when it binds and says so in words;
        // this end has to as well, or a too-long path reads as "no daemon".
        guard bytes.count < MemoryLayout<sockaddr_un>.size - 2 else {
            throw TransportFailure.path(L10n.text("apple.sockettransport.socket_path_is_too_long_for_a_unix_socket.f1b38e89", "\(path)"))
        }

        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw TransportFailure.system("socket", errno)
        }
        guard fcntl(descriptor, F_SETFD, FD_CLOEXEC) == 0 else {
            let failure = errno
            close(descriptor)
            throw TransportFailure.system("fcntl", failure)
        }

        var on: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }

        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { generic in
                Darwin.connect(descriptor, generic, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else {
            let failure = errno
            close(descriptor)
            throw TransportFailure.system("connect", failure)
        }

        fd = descriptor
    }

    deinit { close(fd) }

    private(set) var wroteRequestBytes = false

    func probeProtocol(_ request: Data) throws -> String {
        defer { wroteRequestBytes = false }
        return try roundTrip(request)
    }

    func roundTrip(_ request: Data) throws -> String {
        wroteRequestBytes = false
        try writeAll(request)
        return try readLine()
    }

    private func writeAll(_ data: Data) throws {
        try data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var sent = 0
            while sent < raw.count {
                let n = write(fd, base.advanced(by: sent), raw.count - sent)
                if n > 0 {
                    wroteRequestBytes = true
                    sent += n
                    continue
                }
                if n < 0 && errno == EINTR { continue }
                if n < 0 && Self.isTimeout(errno) { throw TransportFailure.timedOut }
                throw TransportFailure.system("write", errno)
            }
        }
    }

    private func readLine() throws -> String {
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        var scanned = 0
        while true {
            let tail = pending.dropFirst(scanned)
            if let end = tail.firstIndex(of: 0x0A) {
                let line = pending[..<end]
                let rest = pending[pending.index(after: end)...]
                pending = rest.isEmpty ? Data() : rest
                return String(decoding: line, as: UTF8.self)
            }
            scanned = pending.count
            let n = read(fd, &buffer, buffer.count)
            if n > 0 {
                pending.append(contentsOf: buffer[..<n])
                continue
            }
            if n < 0 && errno == EINTR { continue }
            if n < 0 && Self.isTimeout(errno) { throw TransportFailure.timedOut }
            throw TransportFailure.system("read", n == 0 ? ECONNRESET : errno)
        }
    }

    private static func isTimeout(_ code: Int32) -> Bool {
        code == EAGAIN || code == EWOULDBLOCK
    }
}

private enum TransportFailure: LocalizedError {
    case path(String)
    case system(String, Int32)
    case timedOut

    var errorDescription: String? {
        switch self {
        case .path(let why):
            return why
        case .system(let operation, let code):
            return L10n.text("apple.sockettransport.the_host_connection_failed_during_0_1.3d496ab5", "\(operation)", "\(Self.text(code))")
        case .timedOut:
            return L10n.text("apple.sockettransport.the_host_connection_timed_out.9d74e894")
        }
    }

    private static func text(_ code: Int32) -> String {
        String(cString: strerror(code))
    }
}
