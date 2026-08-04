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
    private var noticeGeneration = 0

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

    /// The one string to move to the other machine.
    ///
    /// It carries the key always and the address when this machine is
    /// listening, so the far end can dial without anybody reading an address
    /// aloud. Deliberately not called a key on screen: it is the thing you
    /// paste, and what is inside it is our problem rather than the user's.
    var pairingCode: String? {
        guard let identity else { return nil }
        if let address = status?.address, status?.listening == true {
            return "\(identity.key)@\(address)"
        }
        return identity.key
    }

    /// The two words for this machine, which is what a person compares against
    /// the other screen.
    var words: String? { identity?.words ?? status?.words }

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

    /// Call this machine something, or clear the name to get the computer's own
    /// name back.
    ///
    /// The name reaches a paired machine and nowhere else. It is not synced and
    /// it is not part of the identity: the key is what is pinned, so renaming a
    /// machine never changes who it is to a peer that already trusts it.
    func rename(to name: String) async {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != identity?.label else { return }
        do {
            identity = try await Bridge.renameMachine(trimmed)
            errorMessage = nil
            showNotice(trimmed.isEmpty
                ? "Back to the name this computer already had."
                : "Other machines will see this one as \(identity?.label ?? trimmed).")
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
            showNotice(outcome.serving
                ? "Other machines can now reach this one."
                : "This machine no longer accepts connections.")
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
            showNotice("""
            Paired with \(peer.label). It will not answer until somebody \
            approves this machine over there too.
            """)
            errorMessage = nil
            await refreshPeers()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func approve(_ peer: Peer) async {
        await change(peer) { try await Bridge.approve(key: peer.key) }
        showNotice("\(peer.label) may now reach this machine.")
    }

    func revoke(_ peer: Peer) async {
        await change(peer) { try await Bridge.revoke(key: peer.key) }
        showNotice("\(peer.label) can no longer reach this machine.")
    }

    func forget(_ peer: Peer) async {
        await change(peer) { try await Bridge.forget(key: peer.key) }
        showNotice("\(peer.label) is forgotten. It will arrive as a stranger next time.")
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

    private func showNotice(_ message: String) {
        noticeGeneration += 1
        let generation = noticeGeneration
        noticeMessage = message
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard let self, self.noticeGeneration == generation else { return }
            self.noticeMessage = nil
        }
    }
}
