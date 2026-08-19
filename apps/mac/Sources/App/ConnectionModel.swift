// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

import Foundation
import Observation

/// Why a call failed, decided once instead of by each screen.
///
/// Every screen used to read a sentence and guess. The sentence is still what
/// gets shown, and `FriendlyError` still writes it, but what the app *believes*
/// about the network is decided here, from the error code where there is one.
enum NetworkFailureKind: Equatable {
    /// This device has no working internet.
    case offline
    /// Reached nothing in time.
    case timedOut
    /// Name resolution, TLS, or a refused connection: the service is not
    /// answering the way it should.
    case service
    /// The machine is not on the tunnel right now.
    case peerAbsent
    /// The account is not signed in, or is not allowed to do this. Not a
    /// network problem, and must not be reported as one.
    case account
    /// Something else entirely. Never moves the indicator: a folder that does
    /// not exist is not a network fault.
    case other

    /// Whether this says something about the network as opposed to about the
    /// request.
    var isNetwork: Bool {
        switch self {
        case .offline, .timedOut, .service, .peerAbsent: return true
        case .account, .other: return false
        }
    }
}

/// Which plane a call was on, because the two fail independently.
enum NetworkPlane: Equatable {
    /// The account: usage, plan, machines. Needs the internet.
    case account
    /// A machine over the tunnel. Needs the internet **and** the machine.
    case peer
}

extension NetworkPlane {
    /// Which plane a bridge method is on, or nil for one that says nothing
    /// about the network.
    ///
    /// A local call that fails is a bug or a missing file, not a connection
    /// fault, and letting one move the indicator would teach people to ignore
    /// it. Only the calls that actually leave the device count.
    static func of(method: String) -> NetworkPlane? {
        if method == "remote.call" { return .peer }
        if method.hasPrefix("account.") || method.hasPrefix("sync") { return .account }
        return nil
    }
}

/// Classify a failure from a call.
///
/// Codes first, sentences second. `{"ok": false, "error": {"code", "message"}}`
/// already crosses the boundary and `BridgeError.core` already keeps the code,
/// so the robust half of this carries as much as it can. A phrasing that falls
/// through lands in `.other`, which moves nothing, rather than being mapped to
/// the wrong advice.
enum NetworkClassifier {
    static func kind(of error: Error) -> NetworkFailureKind {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed:
                return .offline
            case .timedOut:
                return .timedOut
            case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed,
                 .secureConnectionFailed, .serverCertificateUntrusted,
                 .badServerResponse, .resourceUnavailable:
                return .service
            case .userAuthenticationRequired:
                return .account
            default:
                return .other
            }
        }
        if let bridge = error as? BridgeError, case let .core(code, message) = bridge {
            return kind(code: code, message: message)
        }
        return kind(code: "", message: error.localizedDescription)
    }

    static func kind(code: String, message: String) -> NetworkFailureKind {
        switch code {
        case "offline":
            return .offline
        case "host_timeout":
            return .timedOut
        case "host_unreachable":
            return .service
        case "no_such_peer", "peer_absent", "tunnel_disconnected":
            return .peerAbsent
        case "not_signed_in", "unauthorized", "not_approved", "not_on_this_plan":
            return .account
        default:
            break
        }
        let lower = message.lowercased()
        if lower.contains("no_such_peer") || lower.contains("not on the tunnel")
            || lower.contains("tunnel is not connected") || lower.contains("tunnel disconnected")
            || lower.contains("did not pair the channel")
        {
            return .peerAbsent
        }
        if lower.contains("offline") || lower.contains("not connected to the internet") {
            return .offline
        }
        if lower.contains("timed out") || lower.contains("timeout") {
            return .timedOut
        }
        if lower.contains("could not resolve") || lower.contains("connection refused")
            || lower.contains("certificate") || lower.contains("tls")
            || lower.contains("bad gateway") || lower.contains("relay")
        {
            return .service
        }
        if lower.contains("sign in") || lower.contains("not approved") {
            return .account
        }
        return .other
    }
}

/// One honest answer about the network, folded from three places that can each
/// break on their own.
///
/// - **Internet**: `ConnectivityModel`, which already has a path monitor and an
///   egress probe that a captive portal cannot fool.
/// - **Service**: whether tokenstat.ai is answering. Derived from the calls the
///   app is already making rather than from a poll, because a poll would ask a
///   question the app asks anyway.
/// - **Peer**: whether the machine being addressed is on the tunnel.
///
/// One model so two screens cannot say different things about one failure.
@MainActor
@Observable
final class ConnectionModel {
    enum Severity: Int, Comparable {
        case ok
        case degraded
        case down

        static func < (lhs: Severity, rhs: Severity) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    /// How many failures in a row before a plane is called unwell.
    ///
    /// One failure is a request, not a state. Two in a row with nothing
    /// succeeding in between is a pattern, and a pattern is worth a word on
    /// screen.
    static let failuresBeforeUnwell = 2

    private(set) var serviceFailing = false
    private(set) var peerFailing = false
    private(set) var lastServiceSuccess: Date?
    private(set) var lastPeerSuccess: Date?
    private var serviceFailures = 0
    private var peerFailures = 0
    private weak var connectivity: ConnectivityModel?

    func attach(_ connectivity: ConnectivityModel) {
        self.connectivity = connectivity
    }

    var isOffline: Bool { connectivity?.isOffline ?? false }

    var severity: Severity {
        if isOffline { return .down }
        if serviceFailing { return .down }
        if peerFailing { return .degraded }
        return .ok
    }

    /// Four words at most, for the chip.
    var title: String {
        if isOffline { return "Offline" }
        if serviceFailing { return "No connection" }
        if peerFailing { return "Computer unreachable" }
        return "Connected"
    }

    /// One sentence, for the popover.
    var detail: String {
        if isOffline {
            return "This device cannot reach the internet. Retrying every "
                + "\(Int(ConnectivityModel.retryInterval.components.seconds)) seconds."
        }
        if serviceFailing {
            return "Signed in, but tokenstat is not answering. Your numbers are the last "
                + "ones this device read."
        }
        if peerFailing {
            return "The internet is fine and the computer is not on the tunnel. It is asleep, "
                + "or tokenstat is not running there."
        }
        return "Everything is answering."
    }

    /// A call came back. Success clears the plane it was on outright: one good
    /// answer proves more than any number of failures suggested.
    func note(plane: NetworkPlane, failure: Error?) {
        guard let failure else {
            switch plane {
            case .account:
                serviceFailures = 0
                serviceFailing = false
                lastServiceSuccess = Date()
            case .peer:
                peerFailures = 0
                peerFailing = false
                lastPeerSuccess = Date()
            }
            return
        }
        let kind = NetworkClassifier.kind(of: failure)
        guard kind.isNetwork else { return }
        // A peer that is absent says nothing about the service, and a service
        // that is down says nothing about that one machine.
        if kind == .peerAbsent {
            peerFailures += 1
            peerFailing = peerFailures >= Self.failuresBeforeUnwell
            return
        }
        switch plane {
        case .account:
            serviceFailures += 1
            serviceFailing = serviceFailures >= Self.failuresBeforeUnwell
        case .peer:
            peerFailures += 1
            peerFailing = peerFailures >= Self.failuresBeforeUnwell
        }
    }

    /// The network came back, or the person pressed Try now. Nothing is known
    /// again until the next call answers, which is honest: the counters were
    /// evidence about a network that no longer exists.
    func reset() {
        serviceFailures = 0
        peerFailures = 0
        serviceFailing = false
        peerFailing = false
    }
}
