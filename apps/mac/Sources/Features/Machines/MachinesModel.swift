// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available: source sharing and own builds are permitted.
// Store and commercial distribution of builds is reserved. See LICENSE.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

import Foundation
import Observation
#if os(macOS)
import AppKit
#else
import UIKit
#endif

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
    #if os(macOS)
    private(set) var hostPolicy: HostPolicy?
    var isSavingHostPolicy = false
    #endif
    private(set) var selectedKind: DeviceKind?
    var errorMessage: String?
    var noticeMessage: String?
    private var noticeGeneration = 0
    private var connectionGeneration: [String: UInt64] = [:]

    private(set) var connectedPeerKeys: Set<String> = []

    enum DeviceKind: Equatable {
        case thisMachine
        case peer(String)
        case account(String)
    }

    enum SelectedDevice {
        case none
        case thisMachine
        case peer(Peer)
        case account(Machine)
    }

    var selectedDevice: SelectedDevice {
        switch selectedKind {
        case .thisMachine:
            return .thisMachine
        case let .peer(key):
            if let peer = peers.first(where: { $0.key == key }) {
                return .peer(peer)
            }
            return .none
        case let .account(id):
            if let machine = accountMachines.first(where: { $0.machineID == id || $0.id == id }) {
                return .account(machine)
            }
            return .none
        case .none:
            return .none
        }
    }

    func selectThisMachine() { selectedKind = .thisMachine }
    func selectPeer(_ peer: Peer) { selectedKind = .peer(peer.key) }
    func selectAccount(_ machine: Machine) {
        selectedKind = .account(machine.machineID ?? machine.id)
    }

    var pending: [Peer] { peers.filter { $0.trust == .pending && $0.key != identity?.key } }
    var known: [Peer] { peers.filter { $0.trust != .pending && $0.key != identity?.key } }

    var tunnelConnected: Bool { status?.tunnelOnline == true }

    var remoteReachAllowed: Bool {
        if let remote = account?.canRemote { return remote }
        guard account?.signedIn == true, let tier = account?.tier?.lowercased() else {
            return false
        }
        return ["free", "supporter", "patron", "legend"].contains(tier)
    }

    var vaultTier: String? {
        account?.vaultTierForSsh
    }

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

    func syncConnectedPeers(_ keys: Set<String>) {
        connectedPeerKeys = keys
    }

    func peer(for machine: Machine) -> Peer? {
        let identity = machine.publicIdentity ?? machine.machineID
        return peers.first { peer in
            peer.key == identity || peer.fingerprint == identity
        }
    }

    func isThisMachine(_ machine: Machine) -> Bool {
        (machine.machineID != nil && machine.machineID == account?.thisMachineID)
            || (machine.publicIdentity != nil && machine.publicIdentity == identity?.key)
    }

    func resolvedName(for machine: Machine) -> String? {
        if let label = machine.label, !label.isEmpty {
            return label
        }
        if isThisMachine(machine) {
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

    func accountName(for peer: Peer) -> String? {
        accountMachines.first { machine in
            let identity = machine.publicIdentity ?? machine.machineID
            return identity == peer.key || identity == peer.fingerprint
        }?.label
    }

    var listedAccountMachines: [Machine] {
        accountMachines.sorted { lhs, rhs in
            let lhsCurrent = isThisMachine(lhs)
            let rhsCurrent = isThisMachine(rhs)
            if lhsCurrent != rhsCurrent { return lhsCurrent }
            if lhs.isHost != rhs.isHost { return lhs.isHost }
            let lhsName = (resolvedName(for: lhs) ?? lhs.displayName).localizedLowercase
            let rhsName = (resolvedName(for: rhs) ?? rhs.displayName).localizedLowercase
            if lhsName != rhsName { return lhsName < rhsName }
            return lhs.id < rhs.id
        }
    }

    func peerSymbol(for peer: Peer) -> String {
        if let machine = accountMachines.first(where: {
            let identity = $0.publicIdentity ?? $0.machineID
            return identity == peer.key || identity == peer.fingerprint
        }) {
            return ClientDeviceIcon.symbol(for: machine)
        }
        let name = (peer.label.isEmpty ? accountName(for: peer) : peer.label) ?? ""
        return ClientDeviceIcon.symbol(name: name, isHost: true)
    }

    var pairingCode: String? {
        guard let key = identity?.key else { return nil }
        guard let address = status?.directCandidates?
            .filter({ $0.kind == "lan" })
            .max(by: { $0.priority < $1.priority })?
            .address else { return key }
        return "\(key)@\(address)"
    }

    func copyInvite() {
        guard let code = pairingCode else { return }
        #if os(macOS)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(code, forType: .string)
        #else
        UIPasteboard.general.string = code
        #endif
        showNotice(L10n.text("apple.machinesmodel.invite_copied_on_the_other_device_choose_a.ff13a35e"))
    }

    var words: String? { identity?.words ?? status?.words }

    private var loadGeneration: UInt64 = 0

    func load() async {
        loadGeneration &+= 1
        let generation = loadGeneration
        let quiet = identity != nil
        if !quiet { loading = true }
        defer { if generation == loadGeneration { loading = false } }
        do {
            async let identityResult = Bridge.machineIdentity()
            async let statusResult = Bridge.remoteStatus()
            async let peersResult = Bridge.peers()
            async let accountResult = Bridge.account()

            let values = try await (identityResult, statusResult, peersResult)
            let freshAccount = try? await accountResult
            guard !Task.isCancelled, generation == loadGeneration else { return }
            identity = values.0
            status = values.1
            peers = values.2
            if let freshAccount {
                account = freshAccount.signedIn ? freshAccount : nil
                accountMachines = freshAccount.signedIn ? freshAccount.machines : []
            }
            errorMessage = nil
            #if os(macOS)
            await loadHostPolicy()
            #endif
            await reconsiderPlanIfNeeded()
        } catch {
            guard !Task.isCancelled, generation == loadGeneration else { return }
            errorMessage = error.localizedDescription
        }
    }

    var isWarmed: Bool { identity != nil }

    func ensureHelper() async {
        #if os(macOS)
        guard !Bridge.isHosted, !settingUpHelper else { return }
        await setupHelper()
        #endif
    }

    func refresh() async {
        if !Bridge.isHosted {
            Bridge.reconnect()
            if Bridge.isHosted {
                await load()
                return
            }
        }
        loadGeneration &+= 1
        let generation = loadGeneration
        do {
            async let statusResult = Bridge.remoteStatus()
            async let peersResult = Bridge.peers()
            async let accountResult = Bridge.account()
            let values = try await (statusResult, peersResult)
            let freshAccount = try? await accountResult
            guard !Task.isCancelled, generation == loadGeneration else { return }
            status = values.0
            peers = values.1
            if let freshAccount {
                account = freshAccount.signedIn ? freshAccount : nil
                accountMachines = freshAccount.signedIn ? freshAccount.machines : []
            }
            errorMessage = nil
            await reconsiderPlanIfNeeded()
        } catch {
            guard !Task.isCancelled, generation == loadGeneration else { return }
            errorMessage = error.localizedDescription
        }
    }

    #if os(macOS)
    private func loadHostPolicy() async {
        hostPolicy = try? await Bridge.hostPolicy()
    }

    /// Flip whether this Mac's host helper outlives the app.
    ///
    /// The same policy the Account screen edits, mirrored here so the setting
    /// lives where somebody is deciding whether other devices may reach this
    /// Mac. The install agent applies the launchd side; a failure there rolls
    /// the stored policy back so the screen never shows a setting the helper
    /// is not honouring.
    func setAlwaysOnHost(_ on: Bool) async {
        guard !isSavingHostPolicy else { return }
        isSavingHostPolicy = true
        defer { isSavingHostPolicy = false }
        let previous = hostPolicy
        do {
            let next = try await Bridge.setHostPolicy(alwaysOn: on)
            do {
                try HostAgentInstaller.applyPolicy(alwaysOn: next.alwaysOn)
                hostPolicy = next
                errorMessage = nil
            } catch {
                if let previous {
                    _ = try? await Bridge.setHostPolicy(alwaysOn: previous.alwaysOn)
                    try? HostAgentInstaller.applyPolicy(alwaysOn: previous.alwaysOn)
                    hostPolicy = previous
                }
                errorMessage = error.localizedDescription
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
    #endif

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
            showNotice(Bridge.isHosted ? L10n.text("apple.machinesmodel.background_helper_is_running.d1b3097f") : L10n.text("apple.machinesmodel.helper_installed_it_is_still_starting_try.dd2ec051"))
        } catch {
            errorMessage = error.localizedDescription
        }
        #endif
    }

    func rename(to name: String) async {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != identity?.label else { return }
        do {
            identity = try await Bridge.renameMachine(trimmed)
            errorMessage = nil
            showNotice(trimmed.isEmpty
                ? L10n.text("apple.machinesmodel.back_to_the_name_this_computer_already_had.574b11b2")
                : L10n.text("apple.machinesmodel.other_devices_will_see_this_one_as_0.e25cb345", "\(identity?.label ?? trimmed)"))
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func renameAccountMachine(_ machine: Machine, to name: String) async {
        guard let id = machine.machineID, !id.isEmpty else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != (machine.label ?? "") else { return }
        do {
            try await Bridge.renameAccountMachine(id: id, name: trimmed)
            if let fresh = try? await Bridge.account(), fresh.signedIn {
                account = fresh
                accountMachines = fresh.machines
            }
            errorMessage = nil
            showNotice(trimmed.isEmpty
                ? L10n.text("apple.machinesmodel.back_to_the_name_that_device_gives_itself.ef51c3b6")
                : L10n.text("apple.machinesmodel.every_screen_on_this_account_calls_it_0_no.d72bed77", "\(trimmed)"))
        } catch {
            errorMessage = error.localizedDescription
        }
    }

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
                ? L10n.text("apple.machinesmodel.remote_reach_is_on_direct_connections_are.f9aa785a")
                : L10n.text("apple.machinesmodel.remote_reach_is_off.701869a6"))
            errorMessage = nil
            await load()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func pair(key: String, label: String, address: String) async {
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard key != identity?.key else {
            errorMessage = L10n.text("apple.machinesmodel.that_is_this_device_it_is_already_here_and.6ca9f067")
            return
        }
        do {
            let peer = try await Bridge.pair(
                key: key,
                label: label.trimmingCharacters(in: .whitespacesAndNewlines),
                address: address.trimmingCharacters(in: .whitespacesAndNewlines)
            )
            showNotice(L10n.text("apple.machinesmodel.paired_with_0_it_will_not_answer_until_som.653a0611", "\(peer.label)"))
            errorMessage = nil
            await refreshPeers()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func approve(_ peer: Peer) async {
        let changed = await change(peer) { try await Bridge.approve(key: peer.key) }
        guard changed else { return }
        showNotice(L10n.text("apple.machinesmodel.0_may_now_reach_this_device.cef66588", "\(peer.label)"))
    }

    func revoke(_ peer: Peer) async {
        let changed = await change(peer) { try await Bridge.revoke(key: peer.key) }
        guard changed else { return }
        clearConnection(peer.key)
        showNotice(L10n.text("apple.machinesmodel.0_can_no_longer_reach_this_device.e6993257", "\(peer.label)"))
    }

    func forget(_ peer: Peer) async {
        let changed = await change(peer) { try await Bridge.forget(key: peer.key) }
        guard changed else { return }
        clearConnection(peer.key)
        showNotice(L10n.text("apple.machinesmodel.0_is_forgotten_it_will_arrive_as_a_strange.c48a4600", "\(peer.label)"))
    }

    func connect(_ peer: Peer) async {
        guard status?.tunnel == true else {
            errorMessage = L10n.text("apple.machinesmodel.turn_on_reach_devices_from_anywhere_before.4930ed6e", "\(peer.label)")
            return
        }
        await dial(peer)
    }

    func connect(_ machine: Machine) async {
        guard machine.machineID == nil || machine.machineID != account?.thisMachineID else { return }
        if let peer = peer(for: machine) {
            await connect(peer)
            return
        }
        guard let key = machine.publicIdentity, !key.isEmpty else {
            errorMessage = L10n.text("apple.machinesmodel.0_has_no_connection_key_on_this_account_re.9e4e975a", "\(machine.displayName)")
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

    func unlink(_ machine: Machine) async {
        guard let id = machine.machineID else { return }
        do {
            try await Bridge.unlinkMachine(id: id)
            if let host = machine.publicIdentity, !host.isEmpty,
               let scope = WorkSessionContext.shared.scope {
                clearConnection(host)
                WorkAccessStore.shared.record(false, scope: scope, host: host)
                await WorkSearchCache.shared.revokeHost(host, scope: scope)
                await WorkCacheAccess.purge(host: host, scope: scope)
            }
            showNotice(L10n.text("apple.machinesmodel.0_removed_from_the_account.008c6cc8", "\(machine.displayName)"))
            await load()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func dial(_ peer: Peer) async {
        connectionGeneration[peer.key, default: 0] &+= 1
        let generation = connectionGeneration[peer.key]
        func isCurrent() -> Bool { !Task.isCancelled && connectionGeneration[peer.key] == generation }
        do {
            _ = try await Bridge.remoteWorkspaces(peer: peer)
            guard isCurrent() else { return }
            connectedPeerKeys.insert(peer.key)
            errorMessage = nil
            showNotice(L10n.text("apple.machinesmodel.connected_to_0_its_workspaces_are_now_avai.c79dc8f5", "\(peer.label)"))
            NotificationCenter.default.post(name: .remotePeerDidConnect, object: peer.key)
        } catch {
            guard isCurrent() else { return }
            connectedPeerKeys.remove(peer.key)
            let text = error.localizedDescription
            if text.contains("has not approved") || text.contains("not approved") {
                showNotice(L10n.text("apple.machinesmodel.0_has_been_asked_to_let_this_device_in_app.6f734666", "\(peer.label)"))
                errorMessage = nil
            } else if WorkspacesModel.isWorkspaceRefusal(text) {
                _ = try? await Bridge.askWorkspaceAccess(peer: peer.key)
                guard isCurrent() else { return }
                showNotice(L10n.text("apple.machinesmodel.0_has_been_asked_to_let_this_device_open_i.961b2eaf", "\(peer.label)"))
                errorMessage = nil
            } else if text.contains("closed before the answer arrived") {
                showNotice(L10n.text("apple.machinesmodel.the_connection_to_0_dropped_mid_answer_it.0e22c33a", "\(peer.label)"))
                errorMessage = nil
            } else if text.localizedCaseInsensitiveContains("offline")
                || text.localizedCaseInsensitiveContains("not reachable")
                || text.localizedCaseInsensitiveContains("timed out")
                || text.localizedCaseInsensitiveContains("timeout")
            {
                errorMessage = L10n.text("apple.machinesmodel.0_is_offline_or_not_reachable_right_now_wa.b6a9fae4", "\(peer.label)")
            } else {
                errorMessage = text
            }
        }
    }

    func setAutoConnect(_ on: Bool, peer: Peer, machine: Machine? = nil) {
        WorkspacesModel.setAutoConnect(on, for: peer.key)
        if on {
            if let machine, !canConnect(machine) {
                return
            }
            Task { await connect(peer) }
        }
    }

    private func clearConnection(_ key: String) {
        connectionGeneration[key, default: 0] &+= 1
        connectedPeerKeys.remove(key)
        NotificationCenter.default.post(name: .remotePeerDidDisconnect, object: key)
    }

    func disconnect(_ peer: Peer) {
        clearConnection(peer.key)
        showNotice(L10n.text("apple.machinesmodel.disconnected_from_0_its_workspaces_are_no.3ecfb24d", "\(peer.label)"))
    }

    func canConnect(_ machine: Machine) -> Bool {
        if machine.machineID != nil, machine.machineID == account?.thisMachineID { return false }
        if let key = identity?.key, machine.publicIdentity == key { return false }
        return machine.kind != "client"
    }

    private func reconsiderPlanIfNeeded() async {
        guard remoteReachAllowed, status?.tunnel == true else { return }
        let planError = status?.tunnelError.map {
            $0.contains("not_on_this_plan")
                || $0.contains("paid-plan")
                || $0.localizedCaseInsensitiveContains("not on this plan")
        } ?? false
        guard planError else { return }
        let generation = loadGeneration
        _ = try? await Bridge.reconsiderPlan()
        let fresh = try? await Bridge.remoteStatus()
        guard !Task.isCancelled, generation == loadGeneration else { return }
        if let fresh { status = fresh }
    }

    private func change(_ peer: Peer, _ action: () async throws -> Void) async -> Bool {
        do {
            try await action()
            errorMessage = nil
            await refreshPeers()
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
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
