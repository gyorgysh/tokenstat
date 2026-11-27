// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available, not open source. See LICENSE for permissions and restrictions.

import Observation
import SwiftUI

@MainActor
@Observable
final class SSHLibraryModel {
    @ObservationIgnored let ownership: SSHOperationOwner
    @ObservationIgnored let drafts = SSHLibraryDraftStore()
    @ObservationIgnored let vault: SSHVaultModel
    @ObservationIgnored private var connectionNotes: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var loadTicket: UUID?
    @ObservationIgnored private var syncTicket: UUID?
    @ObservationIgnored private var reconciledTier: String?

    init(ownerScope: WorkReference.Scope? = nil) {
        ownership = SSHOperationOwner(scope: ownerScope)
        vault = SSHVaultModel(ownerScope: ownerScope)
    }

    func ensureLoaded(vaultTier: String?) async {
        guard let owner = ownership.claim() else { return }
        self.vaultTier = vaultTier
        if vaultTier == nil { reconciledTier = nil }
        if let loadTask { await loadTask.value }
        else if !loaded {
            let token = UUID()
            loadTicket = token
            let task = Task { [weak self] in
                guard let self else { return }
                await self.load(updateTier: false)
                if self.loadTicket == token {
                    self.loadTask = nil
                    self.loadTicket = nil
                }
            }
            loadTask = task
            await task.value
        }
        guard ownership.permits(owner), loaded, let tier = self.vaultTier,
              reconciledTier != tier, !vaultSyncing else { return }
        reconciledTier = tier
        await syncVault(tier: tier)
    }

    func deactivate() {
        ownership.retire()
        vault.deactivate()
        drafts.retireAll()
        for task in connectionNotes.values { task.cancel() }
        connectionNotes.removeAll()
        loadGeneration &+= 1
        loadTask?.cancel()
        loadTask = nil
        loadTicket = nil
        syncTicket = nil
        vaultSyncing = false
        connectRequest = nil
    }

    var hosts: [SSHHost] = []
    var folders: [SSHFolder] = []
    var keys: [SSHKeyRecord] = []
    var snippets: [SSHSnippet] = []
    var knownHosts: [SSHKnownHost] = []
    var error: String?
    var vaultError: String?
    private(set) var vaultSyncing = false
    private(set) var vaultSyncedAt: Date?
    var search = ""

    var selection: SSHLibraryRoute? {
        didSet {
            if oldValue != selection, let oldValue { drafts.remove(oldValue) }
        }
    }

    var connectRequest: SSHHost?

    private(set) var vaultTier: String?

    static func paidTier(for tier: String?) -> String? {
        guard let tier = tier?.lowercased(),
              ["supporter", "patron", "legend"].contains(tier) else { return nil }
        return tier
    }

    private(set) var loaded = false

    private var loadGeneration: UInt64 = 0

    func load(vaultTier: String? = nil, updateTier: Bool = true) async {
        guard let owner = ownership.claim() else { return }
        loadGeneration &+= 1
        let generation = loadGeneration
        if updateTier { self.vaultTier = vaultTier }
        do {
            async let hosts = Bridge.sshHosts()
            async let folders = Bridge.sshFolders()
            async let keys = Bridge.sshKeys()
            async let snippets = Bridge.sshSnippets()
            let (freshHosts, freshFolders, freshKeys, freshSnippets) = try await (hosts, folders, keys, snippets)
            guard ownership.permits(owner), generation == loadGeneration else { return }
            self.hosts = freshHosts
            self.folders = freshFolders
            self.keys = freshKeys
            self.snippets = freshSnippets
            error = nil
            loaded = true
            if updateTier, let vaultTier { await syncVault(tier: vaultTier) }
            if let fresh = try? await Bridge.sshKnownHosts(), ownership.permits(owner), generation == loadGeneration {
                knownHosts = fresh
            }
        } catch {
            guard ownership.permits(owner), generation == loadGeneration else { return }
            self.error = error.localizedDescription
        }
    }

    func reload() async {
        guard let owner = ownership.claim() else { return }
        loadGeneration &+= 1
        let generation = loadGeneration
        async let freshHosts = try? Bridge.sshHosts()
        async let freshFolders = try? Bridge.sshFolders()
        async let freshKeys = try? Bridge.sshKeys()
        async let freshSnippets = try? Bridge.sshSnippets()
        async let freshKnown = try? Bridge.sshKnownHosts()
        let fresh = await (freshHosts, freshFolders, freshKeys, freshSnippets, freshKnown)
        guard ownership.permits(owner), generation == loadGeneration else { return }
        if let value = fresh.0 { hosts = value }
        if let value = fresh.1 { folders = value }
        if let value = fresh.2 { keys = value }
        if let value = fresh.3 { snippets = value }
        if let value = fresh.4 { knownHosts = value }
        dropMissingSelection()
    }

    private func dropMissingSelection() {
        let stillThere: Bool
        switch selection {
        case let .host(id): stillThere = hosts.contains { $0.id == id }
        case let .key(id): stillThere = keys.contains { $0.id == id }
        case let .snippet(id): stillThere = snippets.contains { $0.id == id }
        case let .folder(id): stillThere = folders.contains { $0.id == id }
        case let .knownHost(id): stillThere = knownHosts.contains { $0.id == id }
        case .newHost, .newKey, .newSnippet, .newFolder, .knownHosts,
             .importConfig, .importCloud, nil:
            return
        }
        if !stillThere { selection = nil }
    }


    func save(host: SSHHost) async -> SSHHost? {
        guard let owner = ownership.claim() else { return nil }
        do {
            let saved = try await Bridge.saveSSHHost(host)
            guard ownership.permits(owner) else { return nil }
            await mirror(id: "host:\(saved.id)", envelope: SSHVaultEnvelope(kind: "host", host: saved))
            guard ownership.permits(owner) else { return nil }
            await reload()
            guard ownership.permits(owner) else { return nil }
            return saved
        } catch {
            guard ownership.permits(owner) else { return nil }
            self.error = error.localizedDescription
            return nil
        }
    }

    func save(folder: SSHFolder) async -> SSHFolder? {
        guard let owner = ownership.claim() else { return nil }
        do {
            let saved = try await Bridge.saveSSHFolder(folder)
            guard ownership.permits(owner) else { return nil }
            await mirror(id: "folder:\(saved.id)", envelope: SSHVaultEnvelope(kind: "folder", folder: saved))
            guard ownership.permits(owner) else { return nil }
            await reload()
            guard ownership.permits(owner) else { return nil }
            return saved
        } catch {
            guard ownership.permits(owner) else { return nil }
            self.error = error.localizedDescription
            return nil
        }
    }

    func save(snippet: SSHSnippet) async -> SSHSnippet? {
        guard let owner = ownership.claim() else { return nil }
        do {
            let saved = try await Bridge.saveSSHSnippet(snippet)
            guard ownership.permits(owner) else { return nil }
            await mirror(id: "snippet:\(saved.id)", envelope: SSHVaultEnvelope(kind: "snippet", snippet: saved))
            guard ownership.permits(owner) else { return nil }
            await reload()
            guard ownership.permits(owner) else { return nil }
            return saved
        } catch {
            guard ownership.permits(owner) else { return nil }
            self.error = error.localizedDescription
            return nil
        }
    }

    func save(key: SSHKeyRecord, privateKey: String?, onLocalFailure: () -> Void = {}) async -> SSHKeyRecord? {
        guard let owner = ownership.claim() else { onLocalFailure(); return nil }
        do {
            let saved = try await Bridge.saveSSHKey(key)
            guard ownership.permits(owner) else { return nil }
            if vaultTier != nil && !SSHSecretStore.requiresBiometrics(saved.secretRef) {
                let material = privateKey ?? (try? SSHSecretStore.load(reference: saved.secretRef))
                if let material {
                    let synced = SSHVaultSyncedKey(
                        id: saved.id, label: saved.label, algorithm: saved.algorithm,
                        publicKey: saved.publicKey, privateKey: material,
                        hardwareBacked: saved.hardwareBacked, updatedMs: saved.updatedMs
                    )
                    await mirror(id: "key:\(saved.id)", envelope: SSHVaultEnvelope(kind: "key", key: synced))
                    guard ownership.permits(owner) else { return nil }
                }
            }
            await reload()
            guard ownership.permits(owner) else { return nil }
            return saved
        } catch {
            if case let BridgeError.core(code, _) = error,
               ["call_failed", "invalid_params", "method_not_found"].contains(code) { onLocalFailure() }
            guard ownership.permits(owner) else { return nil }
            self.error = error.localizedDescription
            return nil
        }
    }

    func seedVaultFromThisDevice(tier: String) async {
        guard let owner = ownership.claim() else { return }
        vaultTier = tier
        vaultError = nil
        await pushMissing(to: tier, alreadyInVault: [])
        guard ownership.permits(owner) else { return }
        vaultSyncedAt = Date()
    }

    var keysOnlyInTheVault: [SSHKeyRecord] {
        keys.filter {
            !$0.secretRef.hasPrefix("agent:") && !SSHSecretStore.requiresBiometrics($0.secretRef)
                && !SSHSecretStore.contains(reference: $0.secretRef)
        }
    }

    func delete(host: SSHHost) async {
        await remove(vaultID: "host:\(host.id)") { try await Bridge.deleteSSHHost(id: host.id) }
    }

    func delete(folder: SSHFolder) async {
        await remove(vaultID: "folder:\(folder.id)") { try await Bridge.deleteSSHFolder(id: folder.id) }
    }

    func delete(snippet: SSHSnippet) async {
        await remove(vaultID: "snippet:\(snippet.id)") { try await Bridge.deleteSSHSnippet(id: snippet.id) }
    }

    func delete(key: SSHKeyRecord) async {
        guard let owner = ownership.claim() else { return }
        if SSHSecretStore.requiresBiometrics(key.secretRef) {
            do {
                try await Bridge.deleteSSHKey(id: key.id)
                guard ownership.permits(owner) else { return }
                SSHSecretStore.delete(reference: key.secretRef)
                await reload()
                guard ownership.permits(owner) else { return }
            } catch { if ownership.permits(owner) { self.error = error.localizedDescription } }
            return
        }
        await remove(vaultID: "key:\(key.id)") {
            try await Bridge.deleteSSHKey(id: key.id)
            guard ownership.permits(owner) else { return }
            SSHSecretStore.delete(reference: key.secretRef)
        }
    }

    func move(host: SSHHost, to folderID: String?) async {
        guard let owner = ownership.claim() else { return }
        do {
            let moved = try await Bridge.moveSSHHost(id: host.id, folderID: folderID, sort: host.sort)
            guard ownership.permits(owner) else { return }
            await mirror(id: "host:\(moved.id)", envelope: SSHVaultEnvelope(kind: "host", host: moved))
            guard ownership.permits(owner) else { return }
            await reload()
            guard ownership.permits(owner) else { return }
        } catch { if ownership.permits(owner) { self.error = error.localizedDescription } }
    }

    func forgetKnownHost(_ known: SSHKnownHost) async {
        guard let owner = ownership.claim() else { return }
        do {
            _ = try await Bridge.forgetSSHKnownHost(id: known.hostID)
            guard ownership.permits(owner) else { return }
            await reload()
            guard ownership.permits(owner) else { return }
        } catch { if ownership.permits(owner) { self.error = error.localizedDescription } }
    }

    func trust(host: SSHHost, fingerprint: String, expectedJump: SSHHost? = nil) async -> SSHHost? {
        guard let owner = ownership.claim() else { return nil }
        do {
            let saved = try await Bridge.trustSSHHost(expected: host, fingerprint: fingerprint, expectedJump: expectedJump)
            guard ownership.permits(owner) else { return nil }
            await mirror(id: "host:\(saved.id)", envelope: SSHVaultEnvelope(kind: "host", host: saved))
            guard ownership.permits(owner) else { return nil }
            await reload()
            guard ownership.permits(owner) else { return nil }
            return saved
        } catch {
            if ownership.permits(owner) { self.error = error.localizedDescription }
            return nil
        }
    }

    func noteConnection(_ host: SSHHost) async {
        guard let owner = ownership.claim() else { return }
        _ = try? await Bridge.noteSSHConnection(expected: host)
        guard ownership.permits(owner) else { return }
        await reload()
        guard ownership.permits(owner) else { return }
    }

    func recordConnection(_ host: SSHHost) {
        guard let owner = ownership.claim() else { return }
        let token = UUID()
        connectionNotes[token] = Task { [weak self] in
            guard let self, self.ownership.permits(owner) else { return }
            await self.noteConnection(host)
            self.connectionNotes.removeValue(forKey: token)
        }
    }

    private func remove(vaultID: String, _ work: () async throws -> Void) async {
        guard let owner = ownership.claim() else { return }
        do {
            try await work()
            guard ownership.permits(owner) else { return }
        } catch {
            guard ownership.permits(owner) else { return }
            self.error = error.localizedDescription
            return
        }
        if vaultTier != nil {
            do { _ = try await Bridge.deleteSSHVaultRecord(id: vaultID, expectedScope: owner.scope, expectedGeneration: owner.generation) } catch {
                guard ownership.permits(owner) else { return }
                vaultError = error.localizedDescription
            }
        }
        await reload()
        guard ownership.permits(owner) else { return }
    }

    private func mirror(id: String, envelope: SSHVaultEnvelope) async {
        guard let owner = ownership.claim() else { return }
        guard owner.scope.kind == .account, let vaultTier else { return }
        guard let data = try? JSONEncoder().encode(envelope),
              let plaintext = String(data: data, encoding: .utf8)
        else {
            vaultError = L10n.text("apple.sshlibrarymodel.this_record_could_not_be_prepared_for_the.1bf4a7df")
            return
        }
        do {
            _ = try await Bridge.putSSHVaultRecord(id: id, plaintext: plaintext, tier: vaultTier, expectedScope: owner.scope, expectedGeneration: owner.generation)
            guard ownership.permits(owner) else { return }
        } catch {
            guard ownership.permits(owner) else { return }
            vaultError = error.localizedDescription
        }
    }


    func syncVault(tier: String, asked: Bool = false) async {
        guard let owner = ownership.claim() else { return }
        guard owner.scope.kind == .account, !vaultSyncing else { return }
        let token = UUID()
        syncTicket = token
        vaultSyncing = true
        defer { if syncTicket == token { syncTicket = nil; vaultSyncing = false } }
        vaultTier = tier
        vaultError = nil
        guard let known = await pullVault(tier: tier, reporting: asked), ownership.permits(owner) else { return }
        await pushMissing(to: tier, alreadyInVault: known)
        guard ownership.permits(owner) else { return }
        vaultSyncedAt = Date()
        await reload()
        guard ownership.permits(owner) else { return }
    }

    func syncNow() async {
        guard let vaultTier else { return }
        await syncVault(tier: vaultTier, asked: true)
    }

    private func pushMissing(to tier: String, alreadyInVault known: Set<String>) async {
        guard let owner = ownership.claim() else { return }
        for folder in folders where !known.contains("folder:\(folder.id)") {
            guard ownership.permits(owner) else { return }
            await mirror(id: "folder:\(folder.id)", envelope: SSHVaultEnvelope(kind: "folder", folder: folder))
            guard ownership.permits(owner) else { return }
        }
        for host in hosts where !known.contains("host:\(host.id)") {
            guard ownership.permits(owner) else { return }
            await mirror(id: "host:\(host.id)", envelope: SSHVaultEnvelope(kind: "host", host: host))
            guard ownership.permits(owner) else { return }
        }
        for snippet in snippets where !known.contains("snippet:\(snippet.id)") {
            guard ownership.permits(owner) else { return }
            await mirror(id: "snippet:\(snippet.id)", envelope: SSHVaultEnvelope(kind: "snippet", snippet: snippet))
            guard ownership.permits(owner) else { return }
        }
        for key in keys where !known.contains("key:\(key.id)") {
            guard ownership.permits(owner) else { return }
            guard !SSHSecretStore.requiresBiometrics(key.secretRef) else { continue }
            guard let material = try? SSHSecretStore.load(reference: key.secretRef) else { continue }
            await mirror(id: "key:\(key.id)", envelope: SSHVaultEnvelope(
                kind: "key",
                key: SSHVaultSyncedKey(
                    id: key.id, label: key.label, algorithm: key.algorithm,
                    publicKey: key.publicKey, privateKey: material,
                    hardwareBacked: key.hardwareBacked, updatedMs: key.updatedMs
                )
            ))
        }
    }


    private func pullVault(tier: String, reporting: Bool = false) async -> Set<String>? {
        guard let owner = ownership.claim() else { return nil }
        let records: [SSHVaultRecord]
        do {
            records = try await Bridge.sshVaultRecords(recovery: "", tier: tier, expectedScope: owner.scope, expectedGeneration: owner.generation)
            guard ownership.permits(owner) else { return nil }
        } catch {
            guard ownership.permits(owner) else { return nil }
            if reporting { vaultError = error.localizedDescription }
            return nil
        }
        let known = Set(records.map(\.id))
        var changed = false
        for record in ordered(records) {
            guard ownership.permits(owner) else { return nil }
            if record.deleted == true {
                changed = await applyDeletion(record.id) || changed
                guard ownership.permits(owner) else { return nil }
                continue
            }
            guard let data = record.plaintext.data(using: .utf8),
                  let envelope = try? JSONDecoder().decode(SSHVaultEnvelope.self, from: data)
            else { continue }
            do {
                if let host = envelope.host {
                    switch verdict(remote: host.updatedMs, local: hosts.first { $0.id == host.id }?.updatedMs) {
                    case .takeRemote:
                        _ = try await Bridge.applySSHHost(host)
                        guard ownership.permits(owner) else { return nil }
                        changed = true
                    case .pushLocal:
                        if let mine = hosts.first(where: { $0.id == host.id }) {
                            await mirror(id: "host:\(mine.id)", envelope: SSHVaultEnvelope(kind: "host", host: mine))
                            guard ownership.permits(owner) else { return nil }
                        }
                    case .same:
                        break
                    }
                } else if let folder = envelope.folder {
                    switch verdict(remote: folder.updatedMs, local: folders.first { $0.id == folder.id }?.updatedMs) {
                    case .takeRemote:
                        _ = try await Bridge.applySSHFolder(folder)
                        guard ownership.permits(owner) else { return nil }
                        changed = true
                    case .pushLocal:
                        if let mine = folders.first(where: { $0.id == folder.id }) {
                            await mirror(id: "folder:\(mine.id)", envelope: SSHVaultEnvelope(kind: "folder", folder: mine))
                            guard ownership.permits(owner) else { return nil }
                        }
                    case .same:
                        break
                    }
                } else if let snippet = envelope.snippet {
                    switch verdict(remote: snippet.updatedMs, local: snippets.first { $0.id == snippet.id }?.updatedMs) {
                    case .takeRemote:
                        _ = try await Bridge.applySSHSnippet(snippet)
                        guard ownership.permits(owner) else { return nil }
                        changed = true
                    case .pushLocal:
                        if let mine = snippets.first(where: { $0.id == snippet.id }) {
                            await mirror(id: "snippet:\(mine.id)", envelope: SSHVaultEnvelope(kind: "snippet", snippet: mine))
                            guard ownership.permits(owner) else { return nil }
                        }
                    case .same:
                        break
                    }
                } else if let key = envelope.key {
                    changed = await applyKey(key) || changed
                    guard ownership.permits(owner) else { return nil }
                }
            } catch { if ownership.permits(owner) { self.error = error.localizedDescription } }
        }
        if changed { await reload() }
        guard ownership.permits(owner) else { return nil }
        return known
    }

    private func applyKey(_ key: SSHVaultSyncedKey) async -> Bool {
        guard let owner = ownership.claim() else { return false }
        let local = keys.first { $0.id == key.id }
        if let local, SSHSecretStore.requiresBiometrics(local.secretRef) { return false }
        let havePrivate = local.map { (try? SSHSecretStore.load(reference: $0.secretRef)) != nil } ?? false
        let take = verdict(remote: key.updatedMs, local: local?.updatedMs)
        if take == .takeRemote || (take == .same && !havePrivate) {
            do {
                let reference = try SSHSecretStore.store(key.privateKey, id: "vault_\(key.id)_\(UUID().uuidString)")
                _ = try await Bridge.applySSHKey(SSHKeyRecord(
                    id: key.id, label: key.label, algorithm: key.algorithm,
                    publicKey: key.publicKey, secretRef: reference,
                    hardwareBacked: key.hardwareBacked, updatedMs: key.updatedMs
                ))
                guard ownership.permits(owner) else { return false }
                if let local, local.secretRef != reference {
                    SSHSecretStore.delete(reference: local.secretRef)
                }
                return true
            } catch {
                guard ownership.permits(owner) else { return false }
                self.error = error.localizedDescription
                return false
            }
        }
        if take == .pushLocal, let mine = local,
           let material = try? SSHSecretStore.load(reference: mine.secretRef) {
            await mirror(id: "key:\(mine.id)", envelope: SSHVaultEnvelope(
                kind: "key",
                key: SSHVaultSyncedKey(
                    id: mine.id, label: mine.label, algorithm: mine.algorithm,
                    publicKey: mine.publicKey, privateKey: material,
                    hardwareBacked: mine.hardwareBacked, updatedMs: mine.updatedMs
                )
            ))
        }
        return false
    }

    enum MergeVerdict {
        case takeRemote
        case pushLocal
        case same
    }

    func verdict(remote: Int64, local: Int64?) -> MergeVerdict {
        guard let local else { return .takeRemote }
        if remote > local { return .takeRemote }
        if local > remote { return .pushLocal }
        return .same
    }

    private func ordered(_ records: [SSHVaultRecord]) -> [SSHVaultRecord] {
        var folders: [(SSHVaultRecord, SSHFolder)] = []
        var rest: [SSHVaultRecord] = []
        for record in records {
            guard record.deleted != true,
                  let data = record.plaintext.data(using: .utf8),
                  let envelope = try? JSONDecoder().decode(SSHVaultEnvelope.self, from: data),
                  let folder = envelope.folder
            else {
                rest.append(record)
                continue
            }
            folders.append((record, folder))
        }
        var placed: Set<String> = Set(self.folders.map(\.id))
        var sorted: [SSHVaultRecord] = []
        var remaining = folders
        while !remaining.isEmpty {
            let ready = remaining.filter { $0.1.parentID == nil || placed.contains($0.1.parentID ?? "") }
            guard !ready.isEmpty else { break }
            for item in ready {
                sorted.append(item.0)
                placed.insert(item.1.id)
            }
            let readyIDs = Set(ready.map(\.1.id))
            remaining.removeAll { readyIDs.contains($0.1.id) }
        }
        sorted.append(contentsOf: remaining.map(\.0))
        return sorted + rest
    }

    private func applyDeletion(_ id: String) async -> Bool {
        guard let owner = ownership.claim() else { return false }
        do {
            if let rest = id.after("host:") {
                try await Bridge.deleteSSHHost(id: rest)
                guard ownership.permits(owner) else { return false }
            } else if let rest = id.after("folder:") {
                try await Bridge.deleteSSHFolder(id: rest)
                guard ownership.permits(owner) else { return false }
            } else if let rest = id.after("snippet:") {
                try await Bridge.deleteSSHSnippet(id: rest)
                guard ownership.permits(owner) else { return false }
            } else if let rest = id.after("key:") {
                let key = keys.first(where: { $0.id == rest })
                try await Bridge.deleteSSHKey(id: rest)
                guard ownership.permits(owner) else { return false }
                if let key { SSHSecretStore.delete(reference: key.secretRef) }
            } else {
                return false
            }
            return true
        } catch {
            guard ownership.permits(owner) else { return false }
            self.error = error.localizedDescription
            return false
        }
    }


    func hosts(in folder: String?) -> [SSHHost] {
        matching(hosts) { host in
            [host.label, host.hostname, host.username] + host.tags
        }
        .filter { searching ? true : $0.folderID == folder }
        .sorted { left, right in
            if left.favorite != right.favorite { return left.favorite }
            if left.sort != right.sort { return left.sort < right.sort }
            return left.label.localizedCaseInsensitiveCompare(right.label) == .orderedAscending
        }
    }

    func folders(in parent: String?) -> [SSHFolder] {
        guard !searching else { return [] }
        return folders
            .filter { $0.parentID == parent }
            .sorted { left, right in
                if left.sort != right.sort { return left.sort < right.sort }
                return left.name.localizedCaseInsensitiveCompare(right.name) == .orderedAscending
            }
    }

    var visibleKeys: [SSHKeyRecord] {
        matching(keys) { [$0.label, $0.algorithm, $0.fingerprint] }
    }

    var visibleSnippets: [SSHSnippet] {
        matching(snippets) { [$0.title, $0.command] + $0.tags }
    }

    func snippets(for hostID: String) -> [SSHSnippet] {
        let ordered = snippets.sorted {
            $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
        }
        return ordered.filter { $0.hostIDs.contains(hostID) }
            + ordered.filter { $0.hostIDs.isEmpty }
    }

    func startupSnippets(for hostID: String) -> [SSHSnippet] {
        snippets(for: hostID).filter { $0.runOnConnect && $0.hostIDs.contains(hostID) }
    }

    var recentHosts: [SSHHost] {
        guard hosts.count > Self.recentShortcutThreshold else { return [] }
        return hosts
            .filter { $0.favorite || $0.lastConnectedMs != nil }
            .sorted { left, right in
                if left.favorite != right.favorite { return left.favorite }
                return (left.lastConnectedMs ?? 0) > (right.lastConnectedMs ?? 0)
            }
            .prefix(5)
            .map { $0 }
    }

    static let recentShortcutThreshold = 8

    var searching: Bool { !search.trimmingCharacters(in: .whitespaces).isEmpty }

    func folderName(_ id: String?) -> String? {
        guard let id else { return nil }
        return folders.first { $0.id == id }?.name
    }

    func key(_ id: String?) -> SSHKeyRecord? {
        guard let id else { return nil }
        return keys.first { $0.id == id }
    }

    private func matching<T>(_ items: [T], _ fields: (T) -> [String]) -> [T] {
        let needle = search.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return items }
        return items.filter { item in
            fields(item).contains { $0.localizedCaseInsensitiveContains(needle) }
        }
    }
}

struct SSHVaultEnvelope: Codable {
    var kind: String
    var host: SSHHost?
    var key: SSHVaultSyncedKey?
    var snippet: SSHSnippet?
    var folder: SSHFolder?
}

private extension String {
    func after(_ prefix: String) -> String? {
        hasPrefix(prefix) ? String(dropFirst(prefix.count)) : nil
    }
}
