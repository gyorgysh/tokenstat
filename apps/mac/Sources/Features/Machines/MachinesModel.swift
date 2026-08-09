// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

import Foundation
import AppKit
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
    private(set) var accountMachines: [Machine] = []
    private(set) var account: Account?
    private(set) var loading = false
    private(set) var settingUpHelper = false
    var errorMessage: String?
    /// Set after an action that worked, so the screen confirms rather than
    /// leaving somebody wondering whether the button did anything.
    var noticeMessage: String?
    private var noticeGeneration = 0

    /// Peers whose workspaces are listed in the sidebar right now. Set by the
    /// explicit Connect and kept in sync when the peer sweep or a Disconnect
    /// changes the sidebar, so the row can offer Disconnect instead of
    /// Connect once a machine is actually reachable from here.
    private(set) var connectedPeerKeys: Set<String> = []

    /// Peers waiting on a decision, which is the thing somebody opened this
    /// screen to do.
    var pending: [Peer] { peers.filter { $0.trust == .pending && $0.key != identity?.key } }
    var known: [Peer] { peers.filter { $0.trust != .pending && $0.key != identity?.key } }

    /// Whether the tunnel is holding a live socket, when the daemon has said.
    var tunnelConnected: Bool { status?.tunnelOnline == true }

    /// Whether this account may use remote reach. The relay enforces the plan
    /// at every HELLO, so this is the courtesy copy of the same gate: a free
    /// or expired account must not be invited to flip a switch the relay will
    /// refuse.
    var remoteReachAllowed: Bool {
        guard account?.signedIn == true, let tier = account?.tier?.lowercased() else {
            return false
        }
        return tier == "supporter" || tier == "patron"
    }

    /// Whether an account machine's workspaces are in the sidebar, which is
    /// what "Connected" means on this screen: not just reachable, but dialled
    /// from here.
    func isConnected(_ machine: Machine) -> Bool {
        guard let peer = peer(for: machine) else { return false }
        return connectedPeerKeys.contains(peer.key)
    }

    func markConnected(_ peerKey: String) {
        connectedPeerKeys.insert(peerKey)
    }

    func markDisconnected(_ peerKey: String) {
        connectedPeerKeys.remove(peerKey)
    }

    func peer(for machine: Machine) -> Peer? {
        let identity = machine.publicIdentity ?? machine.machineID
        return peers.first { peer in
            peer.key == identity || peer.fingerprint == identity || peer.label == machine.label
        }
    }

    /// The best name this machine has for an account machine.
    ///
    /// A machine that was never named on the server shows only its code, which
    /// is a row of strangers on a screen meant to answer "which one is my
    /// other computer". The app knows two of them by a name anyway: this
    /// machine's own identity, and any peer it has already approved. Those
    /// resolved names are used in place of "Machine abc" / "Unnamed machine";
    /// nil means nobody here knows it yet and the code stays the title.
    func resolvedName(for machine: Machine) -> String? {
        if let label = machine.label, !label.isEmpty {
            return label
        }
        let isSelf = machine.machineID == account?.thisMachineID
            || machine.publicIdentity == identity?.key
        if isSelf {
            if let label = identity?.label, !label.isEmpty {
                return label
            }
            return status?.label
        }
        if let peer = peer(for: machine), !peer.label.isEmpty {
            return peer.label
        }
        return nil
    }

    /// The account directory's name for a peer, when the peer itself is
    /// unnamed. Mirrors `peer(for:)` in reverse, so the two directions agree
    /// on which keys identify the same machine.
    func accountName(for peer: Peer) -> String? {
        accountMachines.first { machine in
            let identity = machine.publicIdentity ?? machine.machineID
            return identity == peer.key || identity == peer.fingerprint
        }?.label
    }

    /// The one string to move to the other machine: the key. Everything rides
    /// the tunnel now, so there is no address to carry; the far end's Add
    /// device box accepts the key as pasted.
    var pairingCode: String? { identity?.key }

    /// Copy this machine's connection invite to the pasteboard.
    ///
    /// The invite is the key. Nobody has to read it — Copy is the whole
    /// action, and the other machine's Add device box accepts it as pasted.
    func copyInvite() {
        guard let code = pairingCode else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(code, forType: .string)
        showNotice("Invite copied. On the other machine, choose Add device and paste it there.")
    }

    /// The two words for this machine, which is what a person compares against
    /// the other screen.
    var words: String? { identity?.words ?? status?.words }

    func load() async {
        // Already warm from Home's post-heatmap pass: do not flip the loading
        // banner for a refresh that will paint the same content.
        let quiet = identity != nil
        if !quiet { loading = true }
        defer { loading = false }
        do {
            // These four do not depend on each other. Sequential awaits made
            // the first Machines open pay four host RTTs; in parallel it is
            // one slowest-call, which is what the warm cache also wants.
            async let identityResult = Bridge.machineIdentity()
            async let statusResult = Bridge.remoteStatus()
            async let peersResult = Bridge.peers()
            async let accountResult = Bridge.account()

            identity = try await identityResult
            status = try await statusResult
            peers = try await peersResult
            if let accountResult = try? await accountResult, accountResult.signedIn {
                account = accountResult
                accountMachines = accountResult.machines
            } else {
                account = nil
                accountMachines = []
            }
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// True once identity has been fetched at least once (warm or user open).
    var isWarmed: Bool { identity != nil }

    /// Provision the tokenstat-owned helper when this screen is opened. It is
    /// safe to repeat: the installer repairs the launch agent and reconnects
    /// the bridge instead of asking the user to restart the app.
    func ensureHelper() async {
        #if os(macOS)
        guard !Bridge.isHosted, !settingUpHelper else { return }
        await setupHelper()
        #endif
    }

    /// Keep the device list live while the screen is open. In particular this
    /// catches a launch agent that comes up after the initial bridge probe.
    func refresh() async {
        if !Bridge.isHosted {
            Bridge.reconnect()
            if Bridge.isHosted {
                await load()
                return
            }
        }
        do {
            status = try await Bridge.remoteStatus()
            peers = try await Bridge.peers()
            if let accountResult = try? await Bridge.account(), accountResult.signedIn {
                account = accountResult
                accountMachines = accountResult.machines
            }
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func setupHelper() async {
        #if os(macOS)
        guard !settingUpHelper else { return }
        settingUpHelper = true
        errorMessage = nil
        defer { settingUpHelper = false }
        do {
            try HostAgentInstaller.installAndStart()
            Bridge.reconnect()
            await load()
            showNotice(Bridge.isHosted ? "Background helper is running." : "Helper installed. It is still starting. Try again in a moment.")
        } catch {
            errorMessage = error.localizedDescription
        }
        #endif
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

    func setTunnel(_ enabled: Bool) async {
        do {
            _ = try await Bridge.setTunnel(enabled)
            showNotice(enabled
                ? "Remote reach is on. Everything between machines goes through the tunnel."
                : "Remote reach is off.")
            errorMessage = nil
            await load()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func pair(key: String, label: String, address: String) async {
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard key != identity?.key else {
            errorMessage = "That is this machine. It is already here and does not need to be added."
            return
        }
        do {
            let peer = try await Bridge.pair(
                key: key,
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

    func connect(_ peer: Peer) async {
        // One transport: the tunnel. It works from any network, which is the
        // point; there is no direct path to prefer.
        guard status?.tunnel == true else {
            errorMessage = "\(peer.label) is reachable through the tunnel. Turn on Reach machines from anywhere first."
            return
        }
        await dial(peer)
    }

    /// Connect to a machine that belongs to this account.
    ///
    /// The account record carries the public key, so this is the same exchange
    /// as nearby discovery — pin the identity, dial, and let the far end
    /// decide — without anybody copying or comparing anything. Direct when the
    /// network allows it, tunnel otherwise.
    func connect(_ machine: Machine) async {
        guard machine.machineID != account?.thisMachineID else { return }
        if let peer = peer(for: machine) {
            await connect(peer)
            return
        }
        guard let key = machine.publicIdentity, !key.isEmpty else {
            errorMessage = "\(machine.displayName) has no connection key on this account record yet. Open the Machines screen on that machine so it registers one, then try again."
            return
        }
        guard key != identity?.key else { return }
        do {
            let name = machine.displayName
            let peer = try await Bridge.pair(
                key: key,
                label: name,
                address: ""
            )
            errorMessage = nil
            await refreshPeers()
            if let now = peers.first(where: { $0.key == peer.key }) {
                await connect(now)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Remove a machine from the account directory. Destructive on the
    /// server: the machine's uploaded history is deleted, which is exactly
    /// what a stale machine id (a reinstall) needs so a live machine can use
    /// its slot.
    func unlink(_ machine: Machine) async {
        guard let id = machine.machineID else { return }
        do {
            try await Bridge.unlinkMachine(id: id)
            showNotice("\(machine.displayName) removed from the account.")
            await load()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func dial(_ peer: Peer) async {
            do {
                connectedPeerKeys.insert(peer.key)
                _ = try await Bridge.remoteWorkspaces(peer: peer)
                errorMessage = nil
                showNotice("Connected to \(peer.label). Its workspaces are now available in the sidebar.")
                NotificationCenter.default.post(name: .remotePeerDidConnect, object: peer.key)
        } catch {
            // First contact always ends with the far end being asked to
            // approve this machine. That is the point, not a failure to
            // present as one: the other screen shows this machine waiting.
            let text = error.localizedDescription
            if text.contains("has not approved") || text.contains("not approved") {
                showNotice("\(peer.label) has been asked to let this machine in. Approve it on the other device and its workspaces will appear here.")
                errorMessage = nil
            } else {
                // A drop mid-answer is the peer's daemon swapping its tunnel
                // listener or a connection that died between two machines that
                // are both retrying. It resolves itself; naming it as a hard
                // failure would send somebody down a debugging rabbit hole.
                if text.contains("closed before the answer arrived") {
                    showNotice("The connection to \(peer.label) dropped mid-answer. It reconnects automatically. Try again in a moment.")
                    errorMessage = nil
                } else {
                    errorMessage = text
                }
            }
        }
    }

    /// Drop the peer's workspaces from the sidebar and mark the row back to
    /// Connect. The connection itself is a tunnel channel that ends when its
    /// last use does; what the user asked for is that the machine stops
    /// appearing as connected here.
    func disconnect(_ peer: Peer) {
        connectedPeerKeys.remove(peer.key)
        NotificationCenter.default.post(name: .remotePeerDidDisconnect, object: peer.key)
        showNotice("Disconnected from \(peer.label). Its workspaces are no longer in the sidebar.")
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
