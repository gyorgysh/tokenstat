// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

import Foundation
import Observation

/// This machine, the machines it knows, and whether it can be reached.
///
/// Everything here goes through the local daemon. The app never speaks the
/// machine-to-machine protocol, which is why there is no key material in this
/// process and nothing to get wrong in Swift.
@MainActor
@Observable
final class MachinesModel {
    private(set) var identity: MachineIdentity?
    private(set) var status: RemoteStatus?
    private(set) var peers: [Peer] = []
    private(set) var discovered: [DiscoveredDaemon] = []
    private(set) var loading = false
    var errorMessage: String?
    /// Set after an action that worked, so the screen confirms rather than
    /// leaving somebody wondering whether the button did anything.
    var noticeMessage: String?

    private let discovery = BonjourDiscovery()

    /// Peers waiting on a decision, which is the thing somebody opened this
    /// screen to do.
    var pending: [Peer] { peers.filter { $0.trust == .pending } }
    var known: [Peer] { peers.filter { $0.trust != .pending } }

    /// A peer this machine can actually call: approved, and with an address to
    /// dial. Approved without an address is a machine that may connect *to*
    /// this one, which is a real and different state.
    var reachable: [Peer] {
        peers.filter { $0.trust == .approved && $0.address?.isEmpty == false }
    }

    /// The string to paste on another machine to connect. Carries the key
    /// always and the address when this machine is listening, so the other
    /// side can dial without typing a host and port by hand.
    var connectLink: String? {
        guard let identity else { return nil }
        if let address = status?.address, status?.listening == true {
            return "\(identity.key)@\(address)"
        }
        return identity.key
    }

    func load() async {
        discovery.changed = { [weak self] daemons in
            self?.discovered = daemons
        }
        discovery.start()
        loading = true
        defer { loading = false }
        do {
            identity = try await Bridge.machineIdentity()
            status = try await Bridge.remoteStatus()
            peers = try await Bridge.peers()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func pair(_ daemon: DiscoveredDaemon) async {
        guard let address = daemon.address else {
            errorMessage = "Still resolving \(daemon.label)'s address. Try again in a moment."
            return
        }
        await pair(key: daemon.key, label: daemon.label, address: address)
    }

    /// Refresh the peer list alone.
    ///
    /// Separate from `load` because a machine that just connected appears here
    /// and nowhere else, and re-reading the identity to find that out would be
    /// three calls to answer one question.
    func refreshPeers() async {
        do {
            peers = try await Bridge.peers()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func setServing(_ enabled: Bool) async {
        guard let status else { return }
        do {
            let outcome = try await Bridge.setServing(enabled, port: status.port)
            noticeMessage = outcome.serving
                ? "Other machines can reach this one at \(outcome.address ?? "the chosen port")."
                : "This machine no longer accepts connections."
            errorMessage = nil
            await load()
        } catch {
            // The likeliest failure is the port already being in use, and the
            // Rust side already names it. Do not rewrite that.
            errorMessage = error.localizedDescription
        }
    }

    func pair(key: String, label: String, address: String) async {
        do {
            let peer = try await Bridge.pair(
                key: key.trimmingCharacters(in: .whitespacesAndNewlines),
                label: label.trimmingCharacters(in: .whitespacesAndNewlines),
                address: address.trimmingCharacters(in: .whitespacesAndNewlines)
            )
            noticeMessage = """
            Paired with \(peer.label). It will not answer until somebody \
            approves this machine over there too.
            """
            errorMessage = nil
            await refreshPeers()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func approve(_ peer: Peer) async {
        await change(peer) { try await Bridge.approve(key: peer.key) }
        noticeMessage = "\(peer.label) may now reach this machine."
    }

    func revoke(_ peer: Peer) async {
        await change(peer) { try await Bridge.revoke(key: peer.key) }
        noticeMessage = "\(peer.label) can no longer reach this machine."
    }

    func forget(_ peer: Peer) async {
        await change(peer) { try await Bridge.forget(key: peer.key) }
        noticeMessage = "\(peer.label) is forgotten. It will arrive as a stranger next time."
    }

    private func change(_ peer: Peer, _ action: () async throws -> Void) async {
        do {
            try await action()
            errorMessage = nil
            await refreshPeers()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
