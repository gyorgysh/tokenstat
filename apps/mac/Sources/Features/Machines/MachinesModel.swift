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
    enum DeviceState: String {
        case ready = "Ready"
        case settingUp = "Setting up"
        case needsPermission = "Needs permission"
        case needsSignIn = "Needs sign-in"
        case unavailable = "Unavailable"
        case connected = "Connected"
        case waitingApproval = "Waiting for approval"
    }
    private(set) var identity: MachineIdentity?
    private(set) var status: RemoteStatus?
    private(set) var peers: [Peer] = []
    private(set) var accountMachines: [Machine] = []
    private(set) var account: Account?
    private var rawDiscovered: [DiscoveredDaemon] = []
    private(set) var discoveryError: String?
    private(set) var loading = false
    private(set) var settingUpHelper = false
    var errorMessage: String?
    /// Set after an action that worked, so the screen confirms rather than
    /// leaving somebody wondering whether the button did anything.
    var noticeMessage: String?
    private var noticeGeneration = 0

    private let discovery = BonjourDiscovery()

    /// Peers waiting on a decision, which is the thing somebody opened this
    /// screen to do.
    var pending: [Peer] { peers.filter { $0.trust == .pending && $0.key != identity?.key } }
    var known: [Peer] { peers.filter { $0.trust != .pending && $0.key != identity?.key } }

    /// Nearby machines, never this one.
    ///
    /// Bonjour finds a machine's own advertisement too — a Mac that is serving
    /// is registered with the same mDNS responder it browses with. Adding
    /// yourself as a peer is not an error anyone intended, so the row is
    /// filtered out before it can be clicked.
    var discovered: [DiscoveredDaemon] {
        guard let ownKey = identity?.key else { return rawDiscovered }
        return rawDiscovered.filter { $0.key != ownKey }
    }

    /// A peer this machine can actually call: approved, and with an address to
    /// dial. Approved without an address is a machine that may connect *to*
    /// this one, which is a real and different state.
    var reachable: [Peer] {
        peers.filter { $0.trust == .approved && $0.address?.isEmpty == false }
    }

    /// Whether the tunnel is holding a live socket, when the daemon has said.
    var tunnelConnected: Bool { status?.tunnelOnline == true }

    func peer(for machine: Machine) -> Peer? {
        let identity = machine.publicIdentity ?? machine.machineID
        return peers.first { peer in
            peer.key == identity || peer.fingerprint == identity || peer.label == machine.label
        }
    }

    func state(for machine: Machine) -> DeviceState {
        if machine.machineID == account?.thisMachineID { return Bridge.isHosted ? .connected : .settingUp }
        if let peer = peer(for: machine) {
            switch peer.trust {
            case .pending: return .waitingApproval
            case .approved: return peer.address?.isEmpty == false ? .connected : .unavailable
            case .revoked: return .unavailable
            }
        }
        if machine.online == true { return .ready }
        return .unavailable
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

    /// Copy this machine's connection invite to the pasteboard.
    ///
    /// The invite is a pairing code: the key, plus the address when this
    /// machine is listening. Nobody has to read it — Copy is the whole action,
    /// and the other machine's Add device box accepts it as pasted.
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
        discovery.changed = { [weak self] daemons in
            self?.rawDiscovered = daemons
        }
        discovery.errorChanged = { [weak self] message in
            self?.discoveryError = message
        }
        discovery.start()
        loading = true
        defer { loading = false }
        do {
            identity = try await Bridge.machineIdentity()
            status = try await Bridge.remoteStatus()
            peers = try await Bridge.peers()
            if let accountResult = try? await Bridge.account(), accountResult.signedIn {
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

    func pair(_ daemon: DiscoveredDaemon) async {
        guard daemon.serving else {
            errorMessage = "\(daemon.label) is not accepting connections yet. Turn on Link devices on that machine, then try again."
            return
        }
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
            let outcome = try await Bridge.setServing(enabled, tunnel: status.tunnel, port: status.port)
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

    func setTunnel(_ enabled: Bool) async {
        guard let status else { return }
        do {
            _ = try await Bridge.setServing(status.serving, tunnel: enabled, port: status.port)
            showNotice(enabled
                ? "Remote reach is on. Direct connections are still preferred."
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
        // A peer without an address is dialled through the tunnel when that is
        // on: the daemon tries direct first and falls back. Same-account
        // machines never carry an address on the record, so this is the path
        // that makes "connect to my other machines" work anywhere.
        if peer.address?.isEmpty == false {
            await dial(peer)
            return
        }
        guard status?.tunnel == true else {
            errorMessage = "\(peer.label) has no address on this network. Turn on Reach machines from anywhere to connect to it through the tunnel."
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

    private func dial(_ peer: Peer) async {
        do {
            _ = try await Bridge.remoteWorkspaces(peer: peer)
            errorMessage = nil
            showNotice("Connected to \(peer.label). Its workspaces are now available in the sidebar.")
            NotificationCenter.default.post(name: .remotePeerDidConnect, object: nil)
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
                    showNotice("The connection to \(peer.label) dropped mid-answer. It reconnects automatically; try again in a moment.")
                    errorMessage = nil
                } else {
                    errorMessage = text
                }
            }
        }
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
