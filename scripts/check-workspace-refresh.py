#!/usr/bin/env python3
# SPDX-License-Identifier: LicenseRef-tokenstat-source-available
"""Exercise actual workspace refresh methods without a UI, account, or network."""
from pathlib import Path
import subprocess
import tempfile
root = Path(__file__).resolve().parents[1]
source = (root / 'apps/mac/Sources/Client/ClientWorkspacesView.swift').read_text()
def method(signature):
    start = source.index(signature, source.index('final class ClientWorkspacesModel'))
    brace = source.index('{\n', start)
    end, depth = brace + 1, 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[start:end].replace('private func', 'func')
methods = '\n'.join(method(s) for s in ['    func refresh(', '    func connect(', '    func deactivate(', '    private func reloadRemote(', '    private func performRemoteRefresh('])
swift = r'''import Foundation
struct ClientHost: Equatable { let peerKey: String; let name: String; let online: Bool?; let machineID: String? }
struct Machine { var isHost = true; let publicIdentity: String?; var label: String?; var machineID: String?; var online: Bool? = true }
struct Account { var thisMachineID: String?; let machines: [Machine] }
struct Identity { let key: String; let label: String }
struct Peer { let key: String }
struct WorkspaceFolder: Equatable { let id: String }
struct PtySessionInfo: Equatable { let id: String }
struct ChatRecentConversation: Equatable { let id: String }
enum ClientDeviceName { static let marketing = "Phone" }
@MainActor final class WorkSessionContext { static let shared = WorkSessionContext(); var scope: String? = "A" }
@MainActor enum EcosystemPublisher { static var lease: Int? = 1 }
@MainActor enum Bridge {
    static var identities: [CheckedContinuation<Identity, Error>?] = []
    static var identityCalls = 0, remoteCalls = 0
    static var folderWaiters: [CheckedContinuation<[WorkspaceFolder], Error>?] = []
    static func machineIdentity() async throws -> Identity {
        identityCalls += 1; return try await withCheckedThrowingContinuation { identities.append($0) }
    }
    static func identity(_ i: Int) { let held = identities[i]; identities[i] = nil; held?.resume(returning: .init(key: "self", label: "Phone")) }
    static func peers() async throws -> [Peer] { [.init(key: "host")] }
    static func remoteWorkspaces(peer: Peer) async throws -> [WorkspaceFolder] {
        remoteCalls += 1; return try await withCheckedThrowingContinuation { folderWaiters.append($0) }
    }
    static func folders(_ i: Int, _ id: String) { let held = folderWaiters[i]; folderWaiters[i] = nil; held?.resume(returning: [.init(id: id)]) }
}
enum ClientRemote {
    static func ptyList(peer: String) async throws -> [PtySessionInfo] { [.init(id: "terminal")] }
    static func recentChats(peer: String) async throws -> [ChatRecentConversation] { [.init(id: "chat")] }
}
@MainActor final class Model {
    let ownerScope = WorkSessionContext.shared.scope
    var retired = false, refreshGeneration = UUID(), remoteLoadGeneration = UUID()
    var hosts: [ClientHost] = [] { didSet { hostWrites += 1 } }; var hostWrites = 0
    var thisDeviceName: String?
    var connectedKey: String?, isConnecting: String?, chosenPeer: String?, pendingPeer: String?
    var dialCount = 0
    func dial(_ host: ClientHost, recovering: Bool) async { dialCount += 1 }
    func disconnect() { remoteLoadGeneration = UUID(); connectedKey = nil }
    var folders: [WorkspaceFolder] = [] { didSet { folderWrites += 1 } }; var folderWrites = 0
    var sessions: [PtySessionInfo] = [], recentChats: [ChatRecentConversation] = []
    var remoteRefresh: (ticket: UUID, peer: String, generation: UUID, task: Task<Void, Never>)?
    func publishEcosystem(_ folders: [WorkspaceFolder], peer: String, host: String, lease: Int?) {}
''' + methods + r'''
}
@MainActor func until(_ predicate: () -> Bool) async {
    for _ in 0..<10000 { if predicate() { return }; await Task.yield() }
    precondition(predicate())
}
func account(_ name: String) -> Account { .init(machines: [.init(publicIdentity: "host", label: name, machineID: "computer")]) }
@main struct Check {
    @MainActor static func main() async {
        let m = Model()
        let first = Task { await m.refresh(account: account("old")) }
        await until { Bridge.identityCalls == 1 }
        let last = Task { await m.refresh(account: account("new")) }
        await until { Bridge.identityCalls == 2 }
        Bridge.identity(1); await last.value
        Bridge.identity(0); await first.value
        precondition(m.hosts.first?.name == "new" && m.hostWrites == 1)
        let equal = Task { await m.refresh(account: account("new")) }
        await until { Bridge.identityCalls == 3 }; Bridge.identity(2); await equal.value
        precondition(m.hostWrites == 1)
        let wrongOwner = Task { await m.refresh(account: account("wrong")) }
        await until { Bridge.identityCalls == 4 }; WorkSessionContext.shared.scope = "B"
        Bridge.identity(3); await wrongOwner.value
        await m.refresh(account: account("wrong"))
        precondition(Bridge.identityCalls == 4 && m.hosts.first?.name == "new")
        WorkSessionContext.shared.scope = "A"; m.connectedKey = "host"
        let reads = (0..<30).map { _ in Task { await m.reloadRemote(peerKey: "host") } }
        await until { Bridge.remoteCalls == 1 }
        for _ in 0..<100 { await Task.yield() }
        precondition(Bridge.remoteCalls == 1)
        Bridge.folders(0, "project"); for read in reads { await read.value }
        precondition(m.folders.first?.id == "project" && m.folderWrites == 1)
        let unchanged = Task { await m.reloadRemote(peerKey: "host") }
        await until { Bridge.remoteCalls == 2 }; Bridge.folders(1, "project"); await unchanged.value
        precondition(m.folderWrites == 1)
        let stale = Task { await m.reloadRemote(peerKey: "host") }
        await until { Bridge.remoteCalls == 3 }; m.remoteLoadGeneration = UUID()
        let successor = Task { await m.reloadRemote(peerKey: "host") }
        await until { Bridge.remoteCalls == 4 }
        Bridge.folders(2, "wrong"); await stale.value
        let joining = Task { await m.reloadRemote(peerKey: "host") }
        for _ in 0..<100 { await Task.yield() }
        precondition(Bridge.remoteCalls == 4, "Predecessor erased successor")
        Bridge.folders(3, "new"); await successor.value; await joining.value
        precondition(m.folders.first?.id == "new")
        let canceled = Task { await Task.yield(); await m.connect(.init(peerKey: "wrong", name: "Wrong", online: true, machineID: nil)) }
        canceled.cancel(); await canceled.value
        precondition(m.chosenPeer == nil && m.pendingPeer == nil && m.dialCount == 0)
        m.deactivate(); await m.refresh(account: account("wrong")); await m.reloadRemote(peerKey: "host")
        precondition(Bridge.identityCalls == 4 && Bridge.remoteCalls == 4)
        print("Actual workspace refresh: latest account snapshot, equality, 30 shared reads, scope/retirement and successor fences")
    }
}
'''
with tempfile.TemporaryDirectory() as directory:
    work = Path(directory)
    (work / 'Check.swift').write_text(swift)
    subprocess.run(['swiftc', '-parse-as-library', '-swift-version', '5', '-module-cache-path', str(work / 'ModuleCache'), str(work / 'Check.swift'), str(root / 'apps/mac/Sources/Design/L10n.swift'), '-o', str(work / 'check')], check=True)
    subprocess.run([str(work / 'check')], check=True)
client = (root / 'apps/mac/Sources/Client/ClientRootView.swift').read_text()
assert 'func deactivate() { workspaces.deactivate(); ssh.deactivate(); setup.deactivate() }' in client
assert client.count('current?.deactivate()') == 2
auth = (root / 'apps/mac/Sources/Client/ClientWebAuth.swift').read_text()
assert 'UIApplication.shared' not in auth and 'connectedScenes' not in auth
assert 'attempts.finish(ticket)' in auth and 'anchors.current == ticket' in auth
assert 'retireAnchor(ticket)' in auth and 'private let window: UIWindow' in auth
print('Workspace retirement and local auth ownership integration guards passed')
