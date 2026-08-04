// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

import Darwin
import Foundation
import TokenstatFFI

/// One way of reaching a `tokenstat-host` dispatch.
///
/// Both sides of this send the same method names and get back the same
/// envelope, because there is one `dispatch::call` in Rust and every transport
/// is a caller of it. That is what makes a remote machine a change of address
/// rather than a second client layer. See `docs/remote-transport.md`.
///
/// Synchronous on purpose. Every call site already hops off the main actor, and
/// a socket read that blocks its own thread is far easier to reason about than
/// one that suspends.
protocol Transport: Sendable {
    /// Send `method` with a JSON `params` object and return the raw response
    /// JSON. Throws only when the transport itself failed. A method that was
    /// rejected still returns an envelope, and the caller reads `ok`.
    func call(method: String, params: String) throws -> String

    /// What to call this in the interface, and in a bug report.
    var describedAs: String { get }
}

/// The bridge compiled into this process.
///
/// Fast, always available, and it owns the terminals it spawns, which is the
/// catch: a pty started here dies with the window. It is the fallback for a
/// machine with no daemon installed, not the preferred path.
struct InProcessTransport: Transport {
    var describedAs: String { "in-process" }

    func call(method: String, params: String) throws -> String {
        guard let raw = tokenstat_ffi_call(method, params) else {
            throw BridgeError.core(code: "null", message: "The core returned nothing.")
        }
        defer { tokenstat_ffi_string_free(raw) }
        return String(cString: raw)
    }
}

// MARK: - The unix socket

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
    /// Idle connections, checked out for the length of one call.
    ///
    /// A connection is not shared between concurrent calls even though the ids
    /// would allow it. Demultiplexing responses would mean a reader thread, a
    /// pending table and a timeout policy, to save a file descriptor on a
    /// machine that has thousands. The daemon already runs a thread per
    /// connection, and a slow `scan` on one connection is exactly what must not
    /// block a keystroke on another.
    private let lock = NSLock()
    private var idle: [Connection] = []

    /// Kept small. Terminal polling, the file watcher and a report can be in
    /// flight together, and anything past that is a burst that can wait its
    /// turn rather than a reason to hold more descriptors open forever.
    private static let maxIdle = 8

    let path: String

    var describedAs: String { "daemon at \(path)" }

    init(path: String) {
        self.path = path
    }

    /// Open a connection, or nil when nothing is listening.
    ///
    /// This is the probe as well as the constructor: a socket file left behind
    /// by a killed daemon exists but refuses connections, so the only honest
    /// test of "is a host running" is connecting to it.
    static func connecting(to path: String) -> SocketTransport? {
        guard let probe = try? Connection(path: path) else { return nil }
        let transport = SocketTransport(path: path)
        transport.idle.append(probe)
        return transport
    }

    func call(method: String, params: String) throws -> String {
        let request = Self.line(method: method, params: params)

        // One retry, and only on a connection taken from the pool. A daemon
        // that restarted leaves the pooled descriptors dead, and the first call
        // after that is not a failure the user should ever see. A freshly
        // opened connection failing is a real failure and is reported.
        if let pooled = checkout() {
            if let response = try? pooled.roundTrip(request) {
                checkin(pooled)
                return response
            }
        }

        let fresh: Connection
        do {
            fresh = try Connection(path: path)
        } catch {
            throw BridgeError.core(
                code: "host_unreachable",
                message: "The tokenstat host is not answering at \(path). "
                    + "Start it, or reopen the app to work in-process."
            )
        }
        let response = try fresh.roundTrip(request)
        checkin(fresh)
        return response
    }

    private func checkout() -> Connection? {
        lock.lock()
        defer { lock.unlock() }
        return idle.popLast()
    }

    private func checkin(_ connection: Connection) {
        lock.lock()
        defer { lock.unlock() }
        if idle.count < Self.maxIdle {
            idle.append(connection)
        }
    }

    /// Build the request line.
    ///
    /// `params` is already JSON, so it is spliced rather than re-encoded: it can
    /// hold an entire file's text, and round-tripping that through
    /// `JSONSerialization` twice per keystroke is real work for no gain.
    private static func line(method: String, params: String) -> Data {
        let body = params.isEmpty ? "{}" : params
        let name = String(
            decoding: (try? JSONSerialization.data(withJSONObject: [method])) ?? Data(),
            as: UTF8.self
        )
        // `["method"]` minus its brackets is the escaped string literal, which
        // is cheaper than reaching for an encoder to quote one identifier.
        let quoted = name.dropFirst().dropLast()
        var line = Data(#"{"id":0,"method":\#(quoted),"params":\#(body)}"#.utf8)
        line.append(0x0A)
        return line
    }
}

// MARK: - One connection

/// A connected unix socket, with the leftovers of the last read.
///
/// Not thread safe. `SocketTransport` hands one to a single call at a time.
private final class Connection {
    private let fd: Int32
    /// Bytes read past the end of a response line. There should never be any
    /// while one call uses one connection, but a stream is a stream: keeping
    /// them costs a few bytes and losing them would corrupt the next response.
    private var pending = Data()

    init(path: String) throws {
        let bytes = Array(path.utf8)
        // A unix address is a fixed struct, and macOS caps the path near 104
        // bytes. The daemon checks this when it binds and says so in words;
        // this end has to as well, or a too-long path reads as "no daemon".
        guard bytes.count < MemoryLayout<sockaddr_un>.size - 2 else {
            throw TransportFailure.path("socket path is too long for a unix socket: \(path)")
        }

        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw TransportFailure.system("socket", errno)
        }

        // Without this, a daemon that exits between the write and the read
        // raises SIGPIPE, and the default disposition kills the app. An error
        // return is the whole point.
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

    /// Write one request line and read one response line.
    func roundTrip(_ request: Data) throws -> String {
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
                    sent += n
                    continue
                }
                // A short write is normal on a socket. Only EINTR is worth
                // retrying; everything else means this connection is finished.
                if n < 0 && errno == EINTR { continue }
                throw TransportFailure.system("write", errno)
            }
        }
    }

    /// Read until the newline that ends a response.
    ///
    /// The daemon never emits a bare newline inside a value, which is the
    /// reason the protocol is line delimited in the first place, so a newline
    /// is unambiguously the end of a frame.
    private func readLine() throws -> String {
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            if let end = pending.firstIndex(of: 0x0A) {
                let line = pending[..<end]
                pending = pending[pending.index(after: end)...]
                return String(decoding: line, as: UTF8.self)
            }
            let n = read(fd, &buffer, buffer.count)
            if n > 0 {
                pending.append(contentsOf: buffer[..<n])
                continue
            }
            if n < 0 && errno == EINTR { continue }
            // Zero is the daemon closing the connection mid-answer, which is
            // indistinguishable from a crash and is treated the same way.
            throw TransportFailure.system("read", n == 0 ? ECONNRESET : errno)
        }
    }
}

/// Why a transport could not carry the call. Never surfaced directly: the
/// pool turns these into a `BridgeError` with words a user can act on.
private enum TransportFailure: Error {
    case path(String)
    case system(String, Int32)
}
