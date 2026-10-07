#!/usr/bin/env python3
# SPDX-License-Identifier: LicenseRef-tokenstat-source-available
"""Run actual SSH model, draft, cache and connection bodies with held mock IPC.

Observation annotations are removed for this standalone executable because
it does not render views. No network, Keychain, shell or simulator is used.
"""
from pathlib import Path
import re
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
sources = root / 'apps/mac/Sources'


def block(source, signature):
    start = source.index(signature)
    brace = source.index('{', start)
    end, depth = brace + 1, 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[start:end]


def plain(source):
    return re.sub(r'@Observable\b|@ObservationIgnored\s*|import SwiftUI\n|import Observation\n', '', source)


models = (sources / 'Bridge/Models.swift').read_text()
dtos = '\n'.join(block(models, 'struct ' + name + ':') for name in [
    'SSHProviderReference', 'SSHHost', 'SSHEnvPair', 'SSHFolder', 'SSHKeyRecord',
    'SSHSnippet', 'SSHKnownHost', 'SSHKnownHostForget', 'SSHConfigCandidate', 'SSHConfigImport',
    'SSHKeyMaterial', 'SSHSessionHandle', 'SSHHostImport', 'SSHVaultStatus', 'SSHVaultRecovery',
    'SSHVaultUnlock', 'SSHVaultPasswordChange', 'SSHVaultRecord', 'SSHVaultPut', 'SSHVaultDelete', 'SSHVaultRecords',
])
library = plain((sources / 'Features/Machines/SSHLibraryModel.swift').read_text())
drafts = plain((sources / 'Features/Machines/SSHLibraryDrafts.swift').read_text())
vault = plain(block((sources / 'Features/Machines/SSHVaultView.swift').read_text(), '@MainActor\n@Observable\nfinal class SSHVaultModel'))
setup_source = (sources / 'Client/ClientSetupModel.swift').read_text()
setup = plain(block(setup_source, '@MainActor\n@Observable\nfinal class ClientSetupModel')) + '\n' + block(setup_source, 'enum SetupCredential:')
setup_state = (sources / 'Client/ClientSetupState.swift').read_text()
setup_coordinator = plain((sources / 'Client/ClientSetupCoordinator.swift').read_text())
owner = (sources / 'Features/Machines/SSHOperationOwner.swift').read_text()
workbench = plain(block((sources / 'Client/ClientSSHWorkbench.swift').read_text(), '@MainActor @Observable\nfinal class ClientSSHWorkbench'))
project_links = plain((sources / 'Client/ClientSSHProjectLinks.swift').read_text())
setup_session = plain(block((sources / 'Client/ClientSetupSession.swift').read_text(), '@MainActor @Observable\nfinal class ClientSetupSession'))
cache = block((sources / 'Client/ClientRootView.swift').read_text(), '@MainActor\nfinal class ClientSessionModels')
connection = (sources / 'Features/Machines/SSHConnectionsView.swift').read_text()
form = block(connection, 'struct SSHConnectForm: View {')
form_methods = form[form.index('    private func start()'): -1].replace('private func ', 'func ')
wizard_change = block((sources / 'Client/ClientSetupWizard.swift').read_text(), '    private func accountDidChange(').replace('private func ', 'func ')

swift = r'''import Foundation
enum BridgeError: Error { case core(code: String, message: String); case decoding(method: String, underlying: String) }
enum ActionIcon { case search, security, token, pair, signIn, docs, refresh }
struct Machine { var label: String?; var isHost = true; var publicIdentity: String? }
struct Account {
    var signedIn: Bool; var host: String; var handle: String?; var accountId: String?
    var machines: [Machine] = []
}
@MainActor final class AccountModel { func load() async {} }
struct ProvisionStatus { var machineKey: String }
final class ClientSetupStore {
    private var draft: ClientSetupDraft?
    func load(scope: ClientSetupScope) throws -> ClientSetupDraft? { draft }
    func save(_ value: ClientSetupDraft) throws { draft = value }
    func remove(scope: ClientSetupScope) throws { draft = nil }
}
enum SSHKeyAlgorithm { case ed25519, ecdsaP256, ecdsaP256TouchID }
enum L10n { static func text(_ key: String, _ values: String...) -> String { key } }
@MainActor final class WorkSessionContext {
    static let shared = WorkSessionContext()
    var scope: WorkReference.Scope?
    var generation: UInt64 = 0
    func set(_ value: WorkReference.Scope?) { if value != scope { generation += 1; scope = value } }
}
@MainActor enum SSHSecretStore {
    static var stores = 0, deletions = 0, reads = 0
    static func requiresBiometrics(_ ref: String) -> Bool { ref.hasPrefix("biometric:") }
    static func load(reference: String) throws -> String { reads += 1; return "mock-private" }
    static func loadForUse(reference: String) async throws -> String { try await Bridge.gate("key.read"); return "mock-private" }
    static func contains(reference: String) -> Bool { false }
    static func store(_ value: String, id: String, biometric: Bool = false) throws -> String { stores += 1; return "mock:" + id }
    static func delete(reference: String) { deletions += 1 }
}
@MainActor enum SSHVaultBiometrics { static var name: String? { nil }; static var hasSavedPassword: Bool { false } }
enum ClientWorkspacesModelPlaceholder {}
@MainActor final class ClientWorkspacesModel { var retirements = 0; func deactivate() { retirements += 1 } }
@MainActor final class ClientChatSessions {}
@MainActor final class ClientProjectChats {}
@MainActor final class HomeModel {}
@MainActor final class ClientInsightsModel {}
@MainActor final class ClientDevicesModel {}
enum SSHLibraryView { enum Section { case hosts, keys, snippets } }
@MainActor final class SSHLiveTerminal {
    let id: String; let hostID: String?; var detaches = 0
    static var totalStops = 0
    var stops = 0, writes: [[UInt8]] = []
    init(handle: SSHSessionHandle, title: String, hostID: String?) { id = handle.id; self.hostID = hostID }
    func detachPoll() { detaches += 1 }
    func stop() { stops += 1; Self.totalStops += 1 }
    func sendBytes(_ value: [UInt8]) { writes.append(value) }
}
@MainActor final class SSHSessionsModel {
    init(isOwnerCurrent: @escaping @MainActor () -> Bool = { true }) {}
    var sessions: [SSHLiveTerminal] = []; var selected: SSHLiveTerminal? { sessions.last }
    var foreground = true; var retirements = 0
    func select(_ session: SSHLiveTerminal) {}
    func adopt(_ value: SSHLiveTerminal, startup: [SSHSnippet] = []) { sessions.append(value) }
    func setForeground(_ value: Bool) { foreground = value }
    func watch() async {}
    func deactivate() { retirements += 1; for session in sessions { session.detachPoll() } }
}
@MainActor enum Bridge {
    static var calls: [String] = [], envelopes: [WorkReference.Scope] = []
    static var hold: Set<String> = [], pending: [String: [CheckedContinuation<Void, Error>]] = [:]
    static var hostReply: [SSHHost] = [], records: [SSHVaultRecord] = []
    static var retired: [(WorkReference.Scope, String)] = []
    static var failStatus = false
    static var accountReply = Account(signedIn: true, host: "https://mock.example", handle: "alice", accountId: "mock-alice")
    struct Identity { let key: String }
    static func machineIdentity() async throws -> Identity { try await gate("setup.identity"); return .init(key: String(repeating: "a", count: 64)) }
    static func account() async throws -> Account { let reply = accountReply; try await gate("setup.account"); return reply }
    static func probeServerForSetup(_ host: SSHHost, auth: [String: Any]) async throws -> ServerCheck {
        try await gate("setup.check"); return .init(distro: "Mock Linux", ready: true)
    }
    static func mintPairingCode() async throws -> PairingCode { try await gate("setup.mint"); return .init(code: "mock-code", expiresIn: 60) }
    static func stagePairingCode(_ host: SSHHost, code: String, auth: [String: Any]) async throws -> String { try await gate("setup.stage"); return "mock-stage-receipt" }
    static func clearPairingCode(_ host: SSHHost, stageID: String, auth: [String: Any]) async throws { precondition(stageID == "mock-stage-receipt"); try await gate("setup.clear") }
    static func installLine(allow: String?, name: String?, agents: [String], printInvite: Bool, codeFile: Bool) async throws -> InstallLine {
        try await gate("setup.line"); return .init(oneLine: "mock-install", annotated: "mock-install")
    }
    static func setupServerIdentity(_ host: SSHHost, auth: [String: Any]) async throws -> String { try await gate("setup.remoteIdentity"); return String(repeating: "b", count: 64) }
    static func pair(key: String, label: String, address: String) async throws { try await gate("setup.pair") }
    static func workspaceAccessAllowed(peer: String) async throws -> Bool { try await gate("setup.allowed"); return true }
    static func provisionStatus(peer: String) async throws -> ProvisionStatus { try await gate("setup.provision"); return .init(machineKey: peer) }
    static func gate(_ name: String) async throws {
        calls.append(name)
        if hold.contains(name) { try await withCheckedThrowingContinuation { pending[name, default: []].append($0) } }
    }
    static func finish(_ name: String, fail: Bool = false, definite: Bool = false, transportCode: String? = nil) {
        let values = pending.removeValue(forKey: name) ?? []; hold.remove(name)
        for value in values {
            if let transportCode { value.resume(throwing: BridgeError.core(code: transportCode, message: "mock")) }
            else if definite { value.resume(throwing: BridgeError.core(code: "call_failed", message: "mock")) }
            else if fail { value.resume(throwing: CocoaError(.fileReadUnknown)) }
            else { value.resume() }
        }
    }
    static func sshHosts() async throws -> [SSHHost] { let value = hostReply; try await gate("hosts"); return value }
    static func sshFolders() async throws -> [SSHFolder] { try await gate("folders"); return [] }
    static func sshKeys() async throws -> [SSHKeyRecord] { try await gate("keys"); return [] }
    static func sshSnippets() async throws -> [SSHSnippet] { try await gate("snippets"); return [] }
    static func sshKnownHosts() async throws -> [SSHKnownHost] { try await gate("known"); return [] }
    static func saveSSHHost(_ value: SSHHost) async throws -> SSHHost { try await gate("save.host"); return value }
    static func saveSSHFolder(_ value: SSHFolder) async throws -> SSHFolder { try await gate("save.folder"); return value }
    static func saveSSHSnippet(_ value: SSHSnippet) async throws -> SSHSnippet { try await gate("save.snippet"); return value }
    static func saveSSHKey(_ value: SSHKeyRecord) async throws -> SSHKeyRecord { try await gate("save.key"); return value }
    static func applySSHHost(_ value: SSHHost) async throws -> SSHHost { try await gate("apply.host"); return value }
    static func applySSHFolder(_ value: SSHFolder) async throws -> SSHFolder { try await gate("apply.folder"); return value }
    static func applySSHSnippet(_ value: SSHSnippet) async throws -> SSHSnippet { try await gate("apply.snippet"); return value }
    static func applySSHKey(_ value: SSHKeyRecord) async throws -> SSHKeyRecord { try await gate("apply.key"); return value }
    static func deleteSSHHost(id: String) async throws { try await gate("delete.host") }
    static func deleteSSHFolder(id: String) async throws { try await gate("delete.folder") }
    static func deleteSSHSnippet(id: String) async throws { try await gate("delete.snippet") }
    static func deleteSSHKey(id: String) async throws { try await gate("delete.key") }
    static func moveSSHHost(id: String, folderID: String?, sort: Int) async throws -> SSHHost { try await gate("move"); return fixture(id) }
    static func forgetSSHKnownHost(id: String) async throws -> SSHKnownHostForget { try await gate("forget"); return .init(forgotten: true) }
    static func trustSSHHost(expected: SSHHost, fingerprint: String, expectedJump: SSHHost? = nil) async throws -> SSHHost {
        try await gate("trust"); var value = expected; value.hostKeys = [fingerprint]; return value
    }
    static func noteSSHConnection(expected: SSHHost) async throws -> SSHHost { try await gate("note"); return expected }
    static func sshVaultRecords(recovery: String, tier: String, expectedScope: WorkReference.Scope?, expectedGeneration: UInt64? = nil) async throws -> [SSHVaultRecord] {
        let value = records; envelopes.append(expectedScope!); try await gate("vault.records"); return value
    }
    static func putSSHVaultRecord(id: String, plaintext: String, tier: String, expectedScope: WorkReference.Scope?, expectedGeneration: UInt64? = nil) async throws -> SSHVaultPut {
        envelopes.append(expectedScope!); try await gate("vault.put"); return .init(id: id, version: 1)
    }
    static func deleteSSHVaultRecord(id: String, expectedScope: WorkReference.Scope?, expectedGeneration: UInt64? = nil) async throws -> SSHVaultDelete {
        envelopes.append(expectedScope!); try await gate("vault.delete"); return .init(id: id, version: 1, deleted: true)
    }
    static func sshVaultStatus(expectedScope: WorkReference.Scope?, expectedGeneration: UInt64? = nil) async throws -> SSHVaultStatus {
        let scope = expectedScope!; let fail = failStatus; envelopes.append(scope); try await gate("vault.status")
        if fail { throw CocoaError(.fileReadUnknown) }
        return .init(vaultSession: scope.identity, created: true, recordCount: 3, enrolled: true, locked: false)
    }
    static func rotateSSHVaultRecovery(password: String, expectedScope: WorkReference.Scope?, expectedGeneration: UInt64? = nil) async throws -> SSHVaultRecovery {
        envelopes.append(expectedScope!); try await gate("vault.rotate"); return .init(recovery: "mock-code")
    }
    static func lockSSHVault(expectedScope: WorkReference.Scope?, expectedGeneration: UInt64? = nil) async throws { envelopes.append(expectedScope!); try await gate("vault.lock") }
    static func resetSSHVault(expectedScope: WorkReference.Scope?, expectedGeneration: UInt64? = nil) async throws { envelopes.append(expectedScope!); try await gate("vault.reset") }
    static func setSSHVaultPassword(current: String, newPassword: String, expectedScope: WorkReference.Scope?, expectedGeneration: UInt64? = nil) async throws -> SSHVaultPasswordChange {
        envelopes.append(expectedScope!); try await gate("vault.password"); return .init(changed: true, recovery: "mock-next")
    }
    static func retireSSHVault(scope: WorkReference.Scope, sessionID: String) async { retired.append((scope, sessionID)) }
    struct Probe { let fingerprint: String }
    static func probeSSHHost(_ host: SSHHost, jump: [String: Any]? = nil) async throws -> Probe { try await gate("probe"); return .init(fingerprint: "mock-fingerprint") }
    static func sshJumpPayload(_ host: SSHHost, key: SSHKeyRecord?) async throws -> [String: Any] { try await gate("jump"); return [:] }
    static func openSSHWithResolvedAuth(_ host: SSHHost, auth: [String: Any], rows: Int, cols: Int, jump: [String: Any]? = nil) async throws -> SSHSessionHandle {
        precondition(auth["password"] as? String == "mock-password" || auth["kind"] as? String == "privateKey")
        try await gate("open"); return .init(id: "mock-session")
    }
}
func fixture(_ id: String = "host") -> SSHHost {
    SSHHost(id: id, label: id, hostname: "mock.example", port: 22, username: "mock", tags: [], provider: nil, hostKeys: ["mock-fingerprint"])
}
''' + dtos + '\n' + '\n'.join(block(models, 'struct ' + name + ':') for name in ['ServerCheck', 'InstallLine', 'PairingCode']) + '\n' + block((sources / 'Features/Machines/SSHLibraryView.swift').read_text(), 'enum SSHLibraryRoute:') + '\n' + owner + drafts + library + vault + '\n' + project_links + '\n' + workbench + '\n' + setup_session + '\n' + cache + '\n' + setup_state + '\n' + setup_coordinator + '\n' + setup + r'''
@MainActor final class ConnectHarness {
    var host: SSHHost; let model: SSHLibraryModel
    var password = "mock-password", selectedKeyID = ""
    var offeredFingerprint: String?, error: String?, working = false
    var verifiedTarget: SSHHost?, verifiedJump: SSHHost?
    var inFlight: Task<Void, Never>?, attempt: UUID?
    var connectedCount = 0, dismissals = 0
    init(host: SSHHost, model: SSHLibraryModel) { self.host = host; self.model = model }
    func connected(_ session: SSHLiveTerminal) { connectedCount += 1 }
    func dismiss() { dismissals += 1 }
''' + form_methods + r'''
}
@MainActor final class WizardHarness {
    let session = ClientSetupSession(scope: WorkSessionContext.shared.scope)
    var model: ClientSetupModel { session.model }
    var library: SSHLibraryModel { get { session.library } set { session.library = newValue } }
    var path: [SetupStep] { get { session.path } set { session.path = newValue } }
    var entryAttempted: Bool { get { session.entryAttempted } set { session.entryAttempted = newValue } }
''' + wizard_change + r'''
}
@MainActor func until(_ condition: () -> Bool) async {
    for _ in 0..<20000 { if condition() { return }; await Task.yield() }; precondition(condition(), "held mock call never arrived")
}
@MainActor func clean() {
    precondition(Bridge.pending.isEmpty)
    Bridge.calls = []; Bridge.envelopes = []; Bridge.hold = []; Bridge.records = []; Bridge.hostReply = []; Bridge.failStatus = false
}
@main struct Check {
    @MainActor static func main() async {
        let a = WorkReference.Scope.account(origin: "https://mock.example", handle: "alice")!
        let b = WorkReference.Scope.account(origin: "https://mock.example", handle: "bob")!
        let context = WorkSessionContext.shared
        context.set(a)
        // Thirty folding callers share one producer. Canceling a waiter keeps it.
        let library = SSHLibraryModel(ownerScope: a)
        Bridge.hold = ["hosts"]
        let readers = (0..<30).map { _ in Task { await library.ensureLoaded(vaultTier: nil) } }
        await until { Bridge.pending["hosts"] != nil }
        for _ in 0..<100 { await Task.yield() }
        readers[0].cancel()
        precondition(Bridge.calls.filter { $0 == "hosts" }.count == 1)
        Bridge.finish("hosts")
        for reader in readers { await reader.value }
        precondition(library.loaded)
        let before = Bridge.calls.count
        await library.ensureLoaded(vaultTier: "supporter")
        precondition(Bridge.calls.count > before && library.vaultTier == "supporter" && Bridge.calls.contains("vault.records"))
        let synced = Bridge.calls.count
        await library.ensureLoaded(vaultTier: "supporter")
        precondition(Bridge.calls.count == synced)
        clean()
        // Local save succeeds/fails after account B appears: no B mirror or UI error.
        for fail in [false, true] {
            context.set(a); let old = SSHLibraryModel(ownerScope: a)
            await old.ensureLoaded(vaultTier: "supporter"); clean()
            Bridge.hold = ["save.host"]
            let save = Task { await old.save(host: fixture()) }
            await until { Bridge.pending["save.host"] != nil }
            context.set(b); Bridge.finish("save.host", fail: fail)
            let result = await save.value
            precondition(result == nil && old.error == nil && !Bridge.calls.contains("vault.put"))
            clean()
        }
        // A-B-A keeps the same public scope but creates a fresh owner generation.
        context.set(a); let owner = SSHOperationOwner(scope: a); let ticket = owner.claim()!
        context.set(b); context.set(a)
        precondition(!owner.permits(ticket) && owner.claim() == nil)
        let cache = ClientSessionModels(); let first = cache.models(for: a)
        first.ssh.section = .snippets; first.ssh.expanded = ["folder"]
        first.ssh.route = .newKey
        let draft = first.ssh.library.drafts.draft(for: .newKey, make: SSHKeyDraft.init)
        draft.pem = "mock-private-input"; draft.passphrase = "mock-passphrase"
        for _ in 0..<30 { precondition(cache.models(for: a) === first) }
        let again = first.ssh.library.drafts.draft(for: .newKey, make: SSHKeyDraft.init)
        precondition(again === draft && again.pem == "mock-private-input")
        first.ssh.setForeground(false); first.ssh.setForeground(true)
        precondition(draft.pem == "mock-private-input" && first.ssh.route == .newKey)
        context.set(b); context.set(a)
        let replacement = cache.models(for: a)
        precondition(replacement !== first && first.workspaces.retirements == 1 && first.ssh.sessions.retirements == 1)
        precondition(!draft.active && draft.pem.isEmpty && draft.passphrase.isEmpty)
        clean()
        // Held vault keys never enter the secret store after retirement.
        let puller = SSHLibraryModel(ownerScope: a)
        let key = SSHVaultSyncedKey(id: "key", label: "Mock", algorithm: "mock", publicKey: "mock-public", privateKey: "mock-private", hardwareBacked: false)
        let envelope = SSHVaultEnvelope(kind: "key", key: key)
        Bridge.records = [.init(id: "key:key", version: 1, plaintext: String(data: try! JSONEncoder().encode(envelope), encoding: .utf8)!, deleted: false)]
        Bridge.hold = ["vault.records"]; let stores = SSHSecretStore.stores
        let pull = Task { await puller.syncVault(tier: "supporter", asked: true) }
        await until { Bridge.pending["vault.records"] != nil }
        context.set(b); puller.deactivate(); Bridge.finish("vault.records"); await pull.value
        precondition(SSHSecretStore.stores == stores && !Bridge.calls.contains("apply.key") && !puller.vaultSyncing)
        precondition(Bridge.envelopes == [a]); clean()
        // A failed local save retires exactly its newly owned secret even if
        // the editor/account retired; committed and ambiguous writes keep it.
        for mode in 0..<5 {
            context.set(a); let saving = SSHLibraryModel(ownerScope: a)
            let key = SSHKeyRecord(id: "new", label: "Mock", algorithm: "mock", publicKey: "mock-public", secretRef: "mock:new", hardwareBacked: false)
            var cleanups = 0
            Bridge.hold = ["save.key"]
            let save = Task { await saving.save(key: key, privateKey: "mock-private", onLocalFailure: { cleanups += 1 }) }
            await until { Bridge.pending["save.key"] != nil }
            context.set(b); saving.deactivate()
            Bridge.finish("save.key", fail: mode == 2, definite: mode == 0,
                transportCode: mode == 3 ? "host_timeout" : mode == 4 ? "delivery_unknown" : nil)
            _ = await save.value
            precondition(cleanups == (mode == 0 ? 1 : 0)); clean()
        }
        // Newer reload publishes first; old snapshots cannot roll it back.
        context.set(a); let reload = SSHLibraryModel(ownerScope: a)
        Bridge.hostReply = [fixture("old")]; Bridge.hold = ["hosts"]
        let oldRead = Task { await reload.reload() }
        await until { Bridge.pending["hosts"] != nil }
        Bridge.hold = []; Bridge.hostReply = [fixture("new")]
        await reload.reload(); Bridge.finish("hosts"); await oldRead.value
        precondition(reload.hosts.map(\.id) == ["new"]); clean()
        // Mutation success remains success when metadata is offline.
        let vault = SSHVaultModel(ownerScope: a); await vault.refresh()
        Bridge.failStatus = true; await vault.lock()
        precondition(vault.locked && vault.error == nil)
        let changed = await vault.changePassword(current: "mock-old", to: "mock-new")
        precondition(changed)
        precondition(vault.recovery == "mock-next" && vault.error == nil)
        await vault.reset(); precondition(!vault.created && vault.recovery == nil && vault.error == nil)
        Bridge.failStatus = false; await vault.refresh()
        context.set(b); vault.deactivate()
        await until { Bridge.retired.last?.1 == a.identity }
        precondition(Bridge.retired.last?.0 == a && vault.status == nil); clean()
        // Late vault metadata and recovery codes never publish for another owner.
        context.set(a); let staleVault = SSHVaultModel(ownerScope: a)
        Bridge.hold = ["vault.status"]; let status = Task { await staleVault.refresh() }
        await until { Bridge.pending["vault.status"] != nil }
        context.set(b); Bridge.finish("vault.status"); await status.value
        precondition(staleVault.status == nil); clean()
        context.set(a); let rotateVault = SSHVaultModel(ownerScope: a)
        Bridge.hold = ["vault.rotate"]; let rotate = Task { await rotateVault.rotateRecovery(password: "mock") }
        await until { Bridge.pending["vault.rotate"] != nil }
        context.set(b); Bridge.finish("vault.rotate"); await rotate.value
        precondition(rotateVault.recovery == nil && rotateVault.error == nil); clean()
        // Actual connection body captures password before start/cancel cleanup.
        context.set(a); let connector = SSHLibraryModel(ownerScope: a); connector.hosts = [fixture()]
        let form = ConnectHarness(host: fixture(), model: connector); form.start()
        await until { form.dismissals == 1 }
        precondition(form.connectedCount == 1 && form.password.isEmpty)
        await until { Bridge.calls.contains("note") }
        for _ in 0..<100 { await Task.yield() }; clean()
        // Cancel, account retirement and retargeting reject held connection replies.
        for mode in 0..<3 {
            context.set(a); let model = SSHLibraryModel(ownerScope: a); model.hosts = [fixture()]
            let form = ConnectHarness(host: fixture(), model: model)
            Bridge.hold = ["open"]; form.start()
            await until { Bridge.pending["open"] != nil }
            let task = form.inFlight!
            if mode == 0 { form.cancelAndClose() }
            if mode == 1 { context.set(b); model.deactivate() }
            if mode == 2 { model.hosts[0].hostname = "other.mock.example" }
            Bridge.finish("open"); await task.value
            precondition(form.connectedCount == 0 && !Bridge.calls.contains("note")); clean()
        }
        // A key prompt held while the target changes must never open a socket.
        context.set(a); let keyModel = SSHLibraryModel(ownerScope: a); keyModel.hosts = [fixture()]
        keyModel.keys = [.init(id: "key", label: "Mock", algorithm: "mock", publicKey: "mock-public", secretRef: "mock:key", hardwareBacked: false)]
        let keyForm = ConnectHarness(host: fixture(), model: keyModel); keyForm.selectedKeyID = "key"
        Bridge.hold = ["key.read"]; keyForm.start()
        await until { Bridge.pending["key.read"] != nil }; let keyTask = keyForm.inFlight!
        keyModel.hosts[0].port = 2222; Bridge.finish("key.read"); await keyTask.value
        precondition(!Bridge.calls.contains("open")); clean()
        // Actual setup model rejects retired preparations and credential reads.
        context.set(a); let setupLibrary = SSHLibraryModel(ownerScope: a)
        let setup = ClientSetupModel()
        let prepared = await setup.prepare(library: setupLibrary)
        precondition(prepared == true)
        let setupTerminal = SSHLiveTerminal(handle: .init(id: "setup-owned"), title: "Mock", hostID: "host")
        setup.terminal = setupTerminal; setup.password = "mock-password"; setup.credential = .password
        context.set(b); context.set(a)
        let accountChanged = setup.accountChanged(Bridge.accountReply)
        precondition(accountChanged && setupTerminal.detaches == 1 && setupTerminal.stops == 0 && setup.password.isEmpty)
        clean()
        // An old preparation cannot publish after coalesced A-B-A transitions.
        let preparing = ClientSetupModel(); Bridge.hold = ["setup.identity"]
        let preparation = Task { await preparing.prepare(library: setupLibrary) }
        await until { Bridge.pending["setup.identity"] != nil }
        context.set(b); context.set(a); Bridge.finish("setup.identity")
        let latePreparation = await preparation.value
        precondition(latePreparation == nil && !preparing.prepared && !Bridge.calls.contains("setup.account")); clean()
        // A held stage, command or socket reply cannot clean a successor's
        // pairing file, emit installer input, or close a remote shell.
        for hold in ["setup.stage", "setup.line", "open"] {
            let library = SSHLibraryModel(ownerScope: a), model = ClientSetupModel()
            let prepared = await model.prepare(library: library)
            precondition(prepared == true)
            model.host = fixture(); model.credential = .password; model.password = "mock-password"
            Bridge.hold = [hold]
            let stops = SSHLiveTerminal.totalStops
            let install = Task { await model.install(library: library) }
            await until { Bridge.pending[hold] != nil }
            model.cancelWork()
            // New operation changes the coordinator's exact ticket even on A.
            await model.inspect(library: library)
            Bridge.finish(hold); await install.value
            precondition(!Bridge.calls.contains("setup.clear") && SSHLiveTerminal.totalStops == stops && model.terminal == nil)
            clean()
        }
        // Root setup presentation survives thirty remounts with a single
        // preparation and exact dismissal; retirement wipes held secrets.
        context.set(a); Bridge.accountReply.handle = "alice"
        let setupCache = ClientSessionModels()
        let setupRoot = setupCache.models(for: a).setup
        setupRoot.open(); let presentationID = setupRoot.presentation!.id
        setupRoot.path = [.where]; setupRoot.model.host.hostname = "draft.mock.example"
        setupRoot.model.password = "mock-unsent"
        Bridge.hold = ["setup.identity"]
        let setupWaiters = (0..<30).map { _ in Task { await setupRoot.prepare() } }
        await until { Bridge.pending["setup.identity"] != nil }
        setupWaiters[0].cancel()
        for _ in 0..<100 { await Task.yield() }
        precondition(Bridge.calls.filter { $0 == "setup.identity" }.count == 1)
        for _ in 0..<30 {
            precondition(setupCache.models(for: a).setup === setupRoot)
            precondition(setupRoot.path == [.where] && setupRoot.model.password == "mock-unsent")
        }
        Bridge.finish("setup.identity"); for waiter in setupWaiters { await waiter.value }
        precondition(setupRoot.model.prepared)
        setupRoot.close(presentationID); precondition(setupRoot.model.password.isEmpty)
        setupRoot.open(); let successor = setupRoot.presentation!.id
        setupRoot.close(presentationID); precondition(setupRoot.presentation?.id == successor)
        let heldModel = setupRoot.model; heldModel.password = "mock-successor"
        context.set(b); _ = setupCache.models(for: b)
        precondition(heldModel.password.isEmpty && setupRoot.presentation == nil)
        clean()
        // Both actual wizard callbacks delegate here. Their order and a held
        // preparation must not leave B with A's library or restart B twice.
        for firstCallback in ["account", "generation"] {
            context.set(a); Bridge.accountReply.handle = "alice"
            let wizard = WizardHarness()
            let oldPreparation = await wizard.model.prepare(library: wizard.library)
            precondition(oldPreparation == true)
            let oldLibrary = wizard.library
            context.set(b); Bridge.accountReply.handle = "bob"
            Bridge.hold = ["setup.identity"]
            let before = Bridge.calls.filter { $0 == "setup.identity" }.count
            wizard.accountDidChange(Bridge.accountReply)
            await until { Bridge.pending["setup.identity"] != nil }
            wizard.accountDidChange(Bridge.accountReply)
            for _ in 0..<100 { await Task.yield() }
            precondition(Bridge.calls.filter { $0 == "setup.identity" }.count == before + 1, firstCallback)
            precondition(wizard.library !== oldLibrary && wizard.library.ownership.captured?.scope == b)
            Bridge.finish("setup.identity")
            await until { wizard.model.prepared }
            precondition(wizard.model.activeScope?.account == "bob")
            clean()
        }
        print("SSH workbench: focused scenarios passed (actual models, retained drafts/cache, immutable login lifetimes, held connections/keys/vault replies, offline success)")
    }
}
'''

with tempfile.TemporaryDirectory() as directory:
    work = Path(directory)
    (work / 'Check.swift').write_text(swift)
    subprocess.run(['swiftc', '-parse-as-library', '-swift-version', '5', '-module-cache-path', str(work / 'ModuleCache'),
                    str(work / 'Check.swift'), str(sources / 'Features/Work/WorkReference.swift'), '-o', str(work / 'check')], check=True)
    subprocess.run([str(work / 'check')], check=True, timeout=45)

    # Exercise the complete actual session model with its existing tests,
    # including the new owner-change-before-root-rerender case.
    session_model = plain((sources / 'Features/Machines/SSHSessionsModel.swift').read_text())
    (work / 'SSHSessionsModel.swift').write_text(session_model)
    subprocess.run(['swiftc', '-parse-as-library', '-swift-version', '5', '-module-cache-path', str(work / 'ModuleCache'),
                    str(root / 'scripts/tests/SSHSessionsModelTests.swift'), str(work / 'SSHSessionsModel.swift'),
                    str(sources / 'Features/Terminals/TerminalPaneSelection.swift'),
                    str(sources / 'Features/Workspaces/Chat/Singleflight.swift'), str(sources / 'Design/L10n.swift'),
                    '-o', str(work / 'sessions')], check=True)
    subprocess.run([str(work / 'sessions')], check=True, timeout=45)

# Integration checks cover the iOS/macOS wiring excluded from this executable.
client = (sources / 'Client/ClientRootView.swift').read_text()
assert '.task(id: WorkSessionContext.shared.generation)' in client
assert '.modifier(ClientSSHPresentations(' in client
assert client.rfind('.environment(sessionModels.models(for: WorkSessionContext.shared.scope).ssh)') > client.index('.modifier(ClientSSHPresentations(')
assert '.task { await sessions.watch() }' not in (sources / 'Features/Machines/SSHLibraryView.swift').read_text()
assert 'probeServerForSetup(probeHost' not in form
wizard_source = (sources / 'Client/ClientSetupWizard.swift').read_text()
assert '.onChange(of: account.account) { _, now in accountDidChange(now) }' in wizard_source
assert '.onChange(of: WorkSessionContext.shared.generation) { _, _ in accountDidChange(account.account) }' in wizard_source
print('SSH workbench root lifetime, presentation environment, watcher and credential cleanup integration guards passed')

setup_wizard = (sources / 'Client/ClientSetupWizard.swift').read_text()
assert '.onDisappear { model.cancelWork() }' not in setup_wizard
assert '@Bindable var session: ClientSetupSession' in setup_wizard
assert '.modifier(ClientSetupPresentation(' in client
assert client.rfind('.environment(sessionModels.models(for: WorkSessionContext.shared.scope).setup)') > client.index('.modifier(ClientSetupPresentation(')
for entry in ['ClientGettingStarted.swift', 'ClientDevicesView.swift', 'ClientWorkspacesView.swift']:
    text = (sources / 'Client' / entry).read_text()
    assert '@Environment(ClientSetupSession.self)' in text and 'setup.open()' in text
    assert 'ClientSetupWizard()' not in text
print('Setup root presentation, immutable dismissals and adaptive ownership integration guards passed')
