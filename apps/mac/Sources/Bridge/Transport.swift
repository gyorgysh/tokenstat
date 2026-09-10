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
    ///
    /// `patience` is how long the transport waits without hearing anything
    /// before it gives up. It is a silence budget rather than a deadline: a
    /// long answer that keeps arriving is never cut off, and a daemon that
    /// stopped answering is not waited on forever. See `Bridge.Patience`.
    func call(method: String, params: String, patience: TimeInterval) throws -> String

    /// A one-shot call the user is waiting on (opening a terminal, closing
    /// one). The default is the ordinary pooled path; the socket transport
    /// overrides it to skip the pool wait.
    func callUrgent(method: String, params: String, patience: TimeInterval) throws -> String

    /// What to call this in the interface, and in a bug report.
    var describedAs: String { get }
}

extension Transport {
    func callUrgent(method: String, params: String, patience: TimeInterval) throws -> String {
        try call(method: method, params: params, patience: patience)
    }
}

/// The bridge compiled into this process.
///
/// Fast, always available, and it owns the terminals it spawns, which is the
/// catch: a pty started here dies with the window. It is the fallback for a
/// machine with no daemon installed, not the preferred path.
struct InProcessTransport: Transport {
    var describedAs: String { "in-process" }

    /// The wire contract compiled into this app.
    ///
    /// Its own C entry point rather than the `protocol` method, and it lives
    /// here because this file is where the C boundary lives. A call through
    /// `tokenstat_ffi_call` warms the login environment and the shell pool, and
    /// this is asked at launch by an app that is usually about to hand that
    /// work to the daemon instead. The pointer is a string constant and must
    /// not be freed.
    static var protocolVersion: String {
        guard let raw = tokenstat_ffi_protocol_version() else { return "" }
        return String(cString: raw)
    }

    /// `patience` is ignored. This is a function call into the same process:
    /// there is no socket to time out, and a call that hangs here has hung the
    /// thread it was made on with nothing left to cancel.
    func call(method: String, params: String, patience _: TimeInterval) throws -> String {
        guard let raw = tokenstat_ffi_call(method, params) else {
            throw BridgeError.core(code: "null", message: "The core returned nothing.")
        }
        defer { tokenstat_ffi_string_free(raw) }
        return String(cString: raw)
    }
}
