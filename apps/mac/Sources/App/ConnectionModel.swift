// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available: source sharing and own builds are permitted.
// Store and commercial distribution of builds is reserved. See LICENSE.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

import Foundation
import Observation

enum NetworkFailureKind: Equatable {
    case offline
    case timedOut
    case service
    case peerAbsent
    case account
    case other

    var isNetwork: Bool {
        switch self {
        case .offline, .timedOut, .service, .peerAbsent: return true
        case .account, .other: return false
        }
    }
}

enum NetworkPlane: Equatable {
    case account
    case peer
}

extension NetworkPlane {
    static func of(method: String) -> NetworkPlane? {
        if method == "remote.call" { return .peer }
        if ["account.logout", "account.cancelLogin", "sync.scheduleStatus"].contains(method) { return nil }
        if method.hasPrefix("account.") || method.hasPrefix("sync") { return .account }
        return nil
    }
}

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

@MainActor
@Observable
final class ConnectionModel {
    enum Severity: Int, Comparable {
        case ok
        case degraded
        case down

        static func < (lhs: Severity, rhs: Severity) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    static let failuresBeforeUnwell = 2

    private(set) var serviceFailing = false
    private(set) var lastServiceSuccess: Date?
    private(set) var lastPeerSuccess: Date?
    private var serviceFailures = 0
    private var peerFailures: [String: Int] = [:]
    private var peersSeenWorking: Set<String> = []
    private(set) var unreachablePeers: Set<String> = []
    private var peerNames: [String: String] = [:]
    private var dismissedSignature: String?
    private weak var connectivity: ConnectivityModel?

    func attach(_ connectivity: ConnectivityModel) {
        self.connectivity = connectivity
    }

    var isOffline: Bool { connectivity?.isOffline ?? false }

    var peerFailing: Bool { !unreachablePeers.isEmpty }

    private var signature: String {
        "\(serviceFailing ? 1 : 0)|\(unreachablePeers.sorted().joined(separator: ","))"
    }

    var isDismissed: Bool {
        guard let dismissed = dismissedSignature else { return false }
        return dismissed == signature
    }

    func dismiss() {
        dismissedSignature = signature
    }

    var severity: Severity {
        if isOffline { return .down }
        if serviceFailing { return .down }
        if peerFailing { return .degraded }
        return .ok
    }

    func setPeerNames(_ peers: [Peer]) {
        for peer in peers where !peer.label.isEmpty {
            peerNames[peer.key] = peer.label
        }
    }

    private var unreachableName: String? {
        guard unreachablePeers.count == 1, let key = unreachablePeers.first else { return nil }
        return peerNames[key]
    }

    var title: String {
        if isOffline { return L10n.text("common.offline") }
        if serviceFailing { return L10n.text("apple.connectionmodel.no_connection.c9e1a200") }
        if peerFailing {
            if let name = unreachableName { return L10n.text("apple.connectionmodel.0_unreachable.c9592a5e", "\(name)") }
            return unreachablePeers.count > 1 ? L10n.text("apple.connectionmodel.computers_unreachable.5c57873d") : L10n.text("apple.connectionmodel.computer_unreachable.289a05cc")
        }
        return L10n.text("apple.connectionmodel.connected.22965568")
    }

    var detail: String {
        if isOffline {
            return L10n.text("apple.connectionmodel.this_device_cannot_reach_the_internet_retr.4fb94fa0", "\(Int(ConnectivityModel.retryInterval.components.seconds))")
        }
        if serviceFailing {
            return L10n.text("apple.connectionmodel.signed_in_but_tokenstat_is_not_answering_y.0b89409f")
        }
        if peerFailing {
            let subject = unreachableName ?? L10n.text("apple.connectionmodel.the_computer.da52d93a")
            return L10n.text("apple.connectionmodel.the_internet_is_fine_and_0_stopped_answeri.ff980764", "\(subject)")
        }
        return L10n.text("apple.connectionmodel.everything_is_answering.0be29a29")
    }

    func note(plane: NetworkPlane, peer: String?, failure: Error?) {
        guard let failure else {
            switch plane {
            case .account:
                serviceFailures = 0
                serviceFailing = false
                lastServiceSuccess = Date()
                clearDismissalIfWell()
            case .peer:
                lastPeerSuccess = Date()
                guard let peer else { return }
                peerFailures[peer] = 0
                peersSeenWorking.insert(peer)
                unreachablePeers.remove(peer)
                clearDismissalIfWell()
            }
            return
        }
        let kind = NetworkClassifier.kind(of: failure)
        guard kind.isNetwork else { return }
        if plane == .peer || kind == .peerAbsent {
            guard let peer else { return }
            let failures = (peerFailures[peer] ?? 0) + 1
            peerFailures[peer] = failures
            guard peersSeenWorking.contains(peer) else { return }
            if failures >= Self.failuresBeforeUnwell {
                unreachablePeers.insert(peer)
            }
            return
        }
        if plane == .account {
            serviceFailures += 1
            serviceFailing = serviceFailures >= Self.failuresBeforeUnwell
        }
    }

    private func clearDismissalIfWell() {
        if !serviceFailing && unreachablePeers.isEmpty {
            dismissedSignature = nil
        }
    }

    func reset() {
        serviceFailures = 0
        peerFailures.removeAll()
        serviceFailing = false
        unreachablePeers.removeAll()
        dismissedSignature = nil
    }
}
