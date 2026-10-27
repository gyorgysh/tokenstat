// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
// Compile with MachinesModel.swift DevicePresenceOrder.swift.
import Foundation
import Observation

struct MachineIdentity { var key = "self"; var label = "My Mac"; var words = "two words" }
struct Machine { var id: String; var machineID: String?; var publicIdentity: String?; var label: String?; var online: Bool?; var lastSeenAt: String?; var lastSyncAt: String?; var kind = "host"; var displayName: String { label ?? id } }
struct Account { var signedIn = true; var canRemote: Bool? = true; var tier: String? = "legend"; var vaultTierForSsh: String? = "legend"; var thisMachineID: String?; var machines: [Machine] = [] }
struct Peer { enum Trust { case pending, approved, revoked }; var key: String; var label = "Other"; var fingerprint = "fingerprint"; var trust: Trust = .approved }
struct Candidate { var kind: String; var priority: Int; var address: String }
struct RemoteStatus { var tunnelOnline: Bool? = true; var tunnel: Bool? = true; var tunnelError: String?; var label = "My Mac"; var words = "two words"; var directCandidates: [Candidate]? }
struct HostPolicy { var alwaysOn: Bool }
enum ClientDeviceIcon { static func symbol(for: Machine) -> String { "desktopcomputer" }; static func symbol(name: String, isHost: Bool) -> String { "desktopcomputer" } }
func parseServerDate(_ value: String?) -> Date? { nil }
enum HostAgentInstaller { static func applyPolicy(alwaysOn: Bool) throws {}; static func installAndStart() throws {} }
@MainActor final class WorkSessionContext { static let shared = WorkSessionContext(); var scope: String? }
@MainActor final class WorkAccessStore { static let shared = WorkAccessStore(); func record(_ value: Bool, scope: String, host: String) {} }
@MainActor final class WorkSearchCache { static let shared = WorkSearchCache(); func revokeHost(_ host: String, scope: String) async {} }
enum WorkCacheAccess { static func purge(host: String, scope: String) async {} }
enum WorkspacesModel { static func isWorkspaceRefusal(_ text: String) -> Bool { false }; static func setAutoConnect(_ on: Bool, for key: String) {} }
extension Notification.Name { static let remotePeerDidConnect = Notification.Name("test-connected"); static let remotePeerDidDisconnect = Notification.Name("test-disconnected") }
@MainActor enum Bridge {
    static var isHosted = true
    static var currentAccount = Account()
    static var holdDial = false
    static var dialWaiter: CheckedContinuation<Void, Never>?
    static func reconnect() {}
    static func machineIdentity() async throws -> MachineIdentity { MachineIdentity() }
    static func remoteStatus() async throws -> RemoteStatus { RemoteStatus() }
    static func peers() async throws -> [Peer] { [Peer(key: "other")] }
    static func account() async throws -> Account { currentAccount }
    static func hostPolicy() async throws -> HostPolicy { HostPolicy(alwaysOn: false) }
    static func setHostPolicy(alwaysOn: Bool) async throws -> HostPolicy { HostPolicy(alwaysOn: alwaysOn) }
    static func renameMachine(_ name: String) async throws -> MachineIdentity { MachineIdentity(label: name) }
    static func renameAccountMachine(id: String, name: String) async throws {}
    static func setTunnel(_ enabled: Bool) async throws {}
    static func pair(key: String, label: String, address: String) async throws -> Peer { Peer(key: key, label: label) }
    static func approve(key: String) async throws {}
    static func revoke(key: String) async throws {}
    static func forget(key: String) async throws {}
    static func unlinkMachine(id: String) async throws {}
    static func remoteWorkspaces(peer: Peer) async throws {
        if holdDial { await withCheckedContinuation { dialWaiter = $0 } }
    }
    static func askWorkspaceAccess(peer: String) async throws {}
    static func reconsiderPlan() async throws {}
}
@main struct MachinesModelTests {
    @MainActor static func main() async throws {
        let other = Machine(id: "record", publicIdentity: "other")
        Bridge.currentAccount.machines = [other]
        let model = MachinesModel()
        await model.load()
        assert(model.resolvedName(for: other) == "Other", "missing machine IDs cannot identify another device as this Mac")
        assert(model.canConnect(other), "missing directory ID does not hide a public-key host")
        for tier in ["free", "supporter", "patron", "legend"] {
            Bridge.currentAccount.canRemote = nil
            Bridge.currentAccount.tier = tier
            await model.refresh()
            assert(model.remoteReachAllowed, "signed-in \(tier) accounts can reach their own machines")
        }
        Bridge.currentAccount.canRemote = false
        await model.refresh()
        assert(!model.remoteReachAllowed, "an explicit server denial overrides the tier")
        Bridge.currentAccount.signedIn = false
        await model.refresh()
        assert(model.account == nil && model.accountMachines.isEmpty, "explicit sign-out clears old account")
        Bridge.holdDial = true
        let peer = Peer(key: "other")
        let dialing = Task { await model.connect(peer) }
        for _ in 0..<200 {
            if Bridge.dialWaiter != nil { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        assert(Bridge.dialWaiter != nil)
        model.disconnect(peer)
        Bridge.dialWaiter?.resume()
        Bridge.dialWaiter = nil
        await dialing.value
        assert(!model.connectedPeerKeys.contains(peer.key), "late dial cannot reconnect after Disconnect")
        model.markConnected(peer.key)
        await model.forget(peer)
        assert(!model.connectedPeerKeys.contains(peer.key), "Forget removes stale connection/sidebar state")
        print("Machines identity, sign-out and connection ownership passed")
    }
}
