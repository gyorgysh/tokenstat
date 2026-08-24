// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE.

import Observation
import SwiftUI

/// Everything the SSH library holds, and the one place that writes it.
///
/// Every editor used to save its own record and then mirror it into the vault
/// itself, which meant four copies of the same three lines and one of them
/// forgetting the vault. Saving goes through here now: the record store and the
/// encrypted vault move together or not at all.
///
/// Secrets are not in this model. A key record points at the platform vault
/// through `SSHSecretStore`, and the private bytes never enter `connections.json`.
@MainActor
@Observable
final class SSHLibraryModel {
    var hosts: [SSHHost] = []
    var folders: [SSHFolder] = []
    var keys: [SSHKeyRecord] = []
    var snippets: [SSHSnippet] = []
    var knownHosts: [SSHKnownHost] = []
    var error: String?
    var search = ""

    /// The tier that may write to the vault, or nil when this device can only
    /// read from it.
    private(set) var vaultTier: String?

    func load(vaultTier: String? = nil) async {
        self.vaultTier = vaultTier
        do {
            async let hosts = Bridge.sshHosts()
            async let folders = Bridge.sshFolders()
            async let keys = Bridge.sshKeys()
            async let snippets = Bridge.sshSnippets()
            self.hosts = try await hosts
            self.folders = try await folders
            self.keys = try await keys
            self.snippets = try await snippets
            error = nil
            if let vaultTier { await pullVault(tier: vaultTier) }
            knownHosts = (try? await Bridge.sshKnownHosts()) ?? []
        } catch { self.error = error.localizedDescription }
    }

    /// Re-read every list without touching which tier may write to the vault.
    /// `load(vaultTier:)` sets that, so calling it to refresh would quietly
    /// turn vault mirroring off for the rest of the session.
    func reload() async {
        hosts = (try? await Bridge.sshHosts()) ?? hosts
        folders = (try? await Bridge.sshFolders()) ?? folders
        keys = (try? await Bridge.sshKeys()) ?? keys
        snippets = (try? await Bridge.sshSnippets()) ?? snippets
        knownHosts = (try? await Bridge.sshKnownHosts()) ?? knownHosts
    }

    // MARK: - Writing

    func save(host: SSHHost) async -> SSHHost? {
        do {
            let saved = try await Bridge.saveSSHHost(host)
            try await mirror(id: "host:\(saved.id)", envelope: SSHVaultEnvelope(kind: "host", host: saved))
            await reload()
            return saved
        } catch {
            self.error = error.localizedDescription
            return nil
        }
    }

    func save(folder: SSHFolder) async -> SSHFolder? {
        do {
            let saved = try await Bridge.saveSSHFolder(folder)
            try await mirror(id: "folder:\(saved.id)", envelope: SSHVaultEnvelope(kind: "folder", folder: saved))
            await reload()
            return saved
        } catch {
            self.error = error.localizedDescription
            return nil
        }
    }

    func save(snippet: SSHSnippet) async -> SSHSnippet? {
        do {
            let saved = try await Bridge.saveSSHSnippet(snippet)
            try await mirror(id: "snippet:\(saved.id)", envelope: SSHVaultEnvelope(kind: "snippet", snippet: saved))
            await reload()
            return saved
        } catch {
            self.error = error.localizedDescription
            return nil
        }
    }

    /// Keys are the one record with two halves: the description here, and the
    /// private bytes in the platform vault. The encrypted vault carries both,
    /// because a key that syncs without its private half is a row, not a key.
    func save(key: SSHKeyRecord, privateKey: String?) async -> SSHKeyRecord? {
        do {
            let saved = try await Bridge.saveSSHKey(key)
            if vaultTier != nil {
                // An edit that carries no key material is still an edit the
                // other devices need. Renaming used to skip the vault, which
                // left them holding the old name and pushing it back over the
                // new one on the next pull. The private half is read back from
                // this device's vault for exactly this case.
                let material = privateKey ?? (try? SSHSecretStore.load(reference: saved.secretRef))
                if let material {
                    let synced = SSHVaultSyncedKey(
                        id: saved.id, label: saved.label, algorithm: saved.algorithm,
                        publicKey: saved.publicKey, privateKey: material,
                        hardwareBacked: saved.hardwareBacked
                    )
                    try await mirror(id: "key:\(saved.id)", envelope: SSHVaultEnvelope(kind: "key", key: synced))
                }
            }
            await reload()
            return saved
        } catch {
            self.error = error.localizedDescription
            return nil
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
        await remove(vaultID: "key:\(key.id)") {
            try await Bridge.deleteSSHKey(id: key.id)
            SSHSecretStore.delete(reference: key.secretRef)
        }
    }

    func move(host: SSHHost, to folderID: String?) async {
        do {
            let moved = try await Bridge.moveSSHHost(id: host.id, folderID: folderID, sort: host.sort)
            try await mirror(id: "host:\(moved.id)", envelope: SSHVaultEnvelope(kind: "host", host: moved))
            await reload()
        } catch { self.error = error.localizedDescription }
    }

    func forgetKnownHost(_ known: SSHKnownHost) async {
        do {
            _ = try await Bridge.forgetSSHKnownHost(id: known.hostID)
            await reload()
        } catch { self.error = error.localizedDescription }
    }

    /// Record that somebody actually used this host, so the list can lead with
    /// what they reach for. Never fails loudly: a bookkeeping write must not
    /// take a working connection away from anybody.
    func noteConnection(_ host: SSHHost) async {
        var updated = host
        updated.lastConnectedMs = Int64(Date().timeIntervalSince1970 * 1000)
        _ = try? await Bridge.saveSSHHost(updated)
        await reload()
    }

    private func remove(vaultID: String, _ work: () async throws -> Void) async {
        do {
            if vaultTier != nil { _ = try await Bridge.deleteSSHVaultRecord(id: vaultID) }
            try await work()
            await reload()
        } catch { self.error = error.localizedDescription }
    }

    private func mirror(id: String, envelope: SSHVaultEnvelope) async throws {
        guard let vaultTier else { return }
        let data = try JSONEncoder().encode(envelope)
        guard let plaintext = String(data: data, encoding: .utf8) else { return }
        _ = try await Bridge.putSSHVaultRecord(id: id, plaintext: plaintext, tier: vaultTier)
    }

    // MARK: - Reading the vault back

    private func pullVault(tier: String) async {
        guard let records = try? await Bridge.sshVaultRecords(recovery: "", tier: tier) else { return }
        var changed = false
        // Folders first, and shallow before deep. A host names the folder it
        // belongs to and the host refuses a folder it has never heard of, so a
        // pull that applied them in arrival order could drop a server for the
        // rest of the session. Sub-folders have the same rule about parents.
        for record in ordered(records) {
            if record.deleted == true {
                changed = await applyDeletion(record.id) || changed
                continue
            }
            guard let data = record.plaintext.data(using: .utf8),
                  let envelope = try? JSONDecoder().decode(SSHVaultEnvelope.self, from: data)
            else { continue }
            do {
                if let host = envelope.host {
                    _ = try await Bridge.saveSSHHost(host); changed = true
                } else if let folder = envelope.folder {
                    _ = try await Bridge.saveSSHFolder(folder); changed = true
                } else if let snippet = envelope.snippet {
                    _ = try await Bridge.saveSSHSnippet(snippet); changed = true
                } else if let key = envelope.key {
                    let reference = try SSHSecretStore.store(key.privateKey, id: key.id)
                    _ = try await Bridge.saveSSHKey(SSHKeyRecord(
                        id: key.id, label: key.label, algorithm: key.algorithm,
                        publicKey: key.publicKey, secretRef: reference,
                        hardwareBacked: key.hardwareBacked
                    ))
                    changed = true
                }
            } catch { self.error = error.localizedDescription }
        }
        if changed { await reload() }
    }

    /// Folder records first, each after its own parent, then the rest in the
    /// order they arrived.
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
        // Repeat until nothing else can be placed. A folder whose parent is
        // missing entirely still goes out, at the end: the host will reject it
        // and say so, which beats dropping it silently.
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
        do {
            if let rest = id.after("host:") {
                try await Bridge.deleteSSHHost(id: rest)
            } else if let rest = id.after("folder:") {
                try await Bridge.deleteSSHFolder(id: rest)
            } else if let rest = id.after("snippet:") {
                try await Bridge.deleteSSHSnippet(id: rest)
            } else if let rest = id.after("key:") {
                if let key = keys.first(where: { $0.id == rest }) {
                    SSHSecretStore.delete(reference: key.secretRef)
                }
                try await Bridge.deleteSSHKey(id: rest)
            } else {
                return false
            }
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }

    // MARK: - Reading

    /// Hosts in one folder, favourites first, then by position, then by name.
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

    /// The handful somebody actually returns to. Favourites first, then the
    /// most recently used, because a list of forty servers is a list nobody
    /// scans twice.
    var recentHosts: [SSHHost] {
        hosts
            .filter { $0.favorite || $0.lastConnectedMs != nil }
            .sorted { left, right in
                if left.favorite != right.favorite { return left.favorite }
                return (left.lastConnectedMs ?? 0) > (right.lastConnectedMs ?? 0)
            }
            .prefix(5)
            .map { $0 }
    }

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

/// One vault record's payload. Exactly one of the four is set.
struct SSHVaultEnvelope: Codable {
    var kind: String
    var host: SSHHost?
    var key: SSHVaultSyncedKey?
    var snippet: SSHSnippet?
    var folder: SSHFolder?
}

/// A key on its way through the vault, private half included. This shape exists
/// only inside an encrypted record and is never written to disk in the clear.
struct SSHVaultSyncedKey: Codable {
    var id: String
    var label: String
    var algorithm: String
    var publicKey: String
    var privateKey: String
    var hardwareBacked: Bool
}

private extension String {
    func after(_ prefix: String) -> String? {
        hasPrefix(prefix) ? String(dropFirst(prefix.count)) : nil
    }
}
