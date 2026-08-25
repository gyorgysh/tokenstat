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
    /// A write that landed locally but could not be mirrored to the vault.
    ///
    /// Separate from `error` on purpose. The local record store is the source
    /// of truth on this machine and the vault is a copy of it for other
    /// devices, so a vault that is unreachable is a sync problem and not a
    /// save that did not happen. Reporting it as `error` is what made adding
    /// and deleting look broken while both were actually working.
    var vaultError: String?
    var search = ""

    /// What the inspector column is showing, on the Mac shell where the list
    /// and the editor are two columns rather than one pushed screen.
    ///
    /// On the model rather than in a view, because the two columns are drawn
    /// by different views and a selection that lives in one of them is a
    /// selection the other has to be handed.
    var selection: SSHLibraryRoute?

    /// The tier that may write to the vault, or nil when this device can only
    /// read from it.
    private(set) var vaultTier: String?

    /// The account's tier, filtered down to the ones that may write the vault.
    ///
    /// One place rather than one per caller: the sidebar and the library screen
    /// both have to decide it, and two copies of a plan list is a copy that
    /// disagrees the first time a plan is renamed.
    static func paidTier(for tier: String?) -> String? {
        guard let tier = tier?.lowercased(),
              ["supporter", "patron", "legend"].contains(tier) else { return nil }
        return tier
    }

    /// True once a load has finished, however empty the result was.
    ///
    /// "No hosts" and "not loaded yet" look identical from the outside, and
    /// telling somebody with forty saved servers that they have none is worse
    /// than showing them nothing at all.
    private(set) var loaded = false

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
            loaded = true
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
        dropMissingSelection()
    }

    /// Let go of a selection whose record is gone.
    ///
    /// Deleting the selected server left the inspector rendering an editor for
    /// a record that no longer exists, with the deleted name still in the
    /// chrome bar and a Save button that would put it back.
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

    // MARK: - Writing

    func save(host: SSHHost) async -> SSHHost? {
        do {
            let saved = try await Bridge.saveSSHHost(host)
            await mirror(id: "host:\(saved.id)", envelope: SSHVaultEnvelope(kind: "host", host: saved))
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
            await mirror(id: "folder:\(saved.id)", envelope: SSHVaultEnvelope(kind: "folder", folder: saved))
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
            await mirror(id: "snippet:\(saved.id)", envelope: SSHVaultEnvelope(kind: "snippet", snippet: saved))
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
                        hardwareBacked: saved.hardwareBacked, updatedMs: saved.updatedMs
                    )
                    await mirror(id: "key:\(saved.id)", envelope: SSHVaultEnvelope(kind: "key", key: synced))
                }
            }
            await reload()
            return saved
        } catch {
            self.error = error.localizedDescription
            return nil
        }
    }

    /// Put everything on this device into a vault that has just been made.
    ///
    /// The other half of deleting a vault nobody can open. Deleting used to be
    /// the end of the road: the account lost its vault and the person was left
    /// on a screen offering to create an empty one, with their forty saved
    /// servers sitting in `connections.json` a foot away. Those records are
    /// not secrets, they are still here, and this is what carries them across.
    ///
    /// Keys come too when this device still holds the private half. One that
    /// only ever existed in the deleted vault cannot be recovered by anybody,
    /// which is said before the delete rather than discovered after it.
    func seedVaultFromThisDevice(tier: String) async {
        vaultTier = tier
        vaultError = nil
        // Folders before the hosts that name them, for the same reason the
        // pull orders them: a client reading this back rejects a host whose
        // folder it has not seen.
        for folder in folders {
            await mirror(id: "folder:\(folder.id)", envelope: SSHVaultEnvelope(kind: "folder", folder: folder))
        }
        for host in hosts {
            await mirror(id: "host:\(host.id)", envelope: SSHVaultEnvelope(kind: "host", host: host))
        }
        for snippet in snippets {
            await mirror(id: "snippet:\(snippet.id)", envelope: SSHVaultEnvelope(kind: "snippet", snippet: snippet))
        }
        for key in keys {
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

    /// Keys whose private half is not on this device.
    ///
    /// Named before a vault is deleted, because these are the ones nothing can
    /// bring back: the row is here, the material was only in the vault.
    var keysOnlyInTheVault: [SSHKeyRecord] {
        keys.filter { (try? SSHSecretStore.load(reference: $0.secretRef)) == nil }
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
            await mirror(id: "host:\(moved.id)", envelope: SSHVaultEnvelope(kind: "host", host: moved))
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
    ///
    /// Written without moving the merge stamp, and not mirrored. Connecting is
    /// not an edit to the record: stamping it would make this device the
    /// newest writer of a host somebody had just renamed elsewhere, and the
    /// rename would lose to a connection nobody thinks of as a change. Which
    /// server you reached for last is local recency and stays local.
    func noteConnection(_ host: SSHHost) async {
        var updated = host
        updated.lastConnectedMs = Int64(Date().timeIntervalSince1970 * 1000)
        _ = try? await Bridge.applySSHHost(updated)
        await reload()
    }

    /// Delete locally, then forget it in the vault.
    ///
    /// This order is the whole point. The vault delete used to run first,
    /// under the same `try`, so a vault that answered with an error stopped
    /// the local delete from ever running: the record stayed, the screen
    /// showed a server sentence, and deleting appeared to be broken while
    /// nothing had been attempted.
    private func remove(vaultID: String, _ work: () async throws -> Void) async {
        do {
            try await work()
        } catch {
            self.error = error.localizedDescription
            return
        }
        if vaultTier != nil {
            do { _ = try await Bridge.deleteSSHVaultRecord(id: vaultID) } catch {
                vaultError = error.localizedDescription
            }
        }
        await reload()
    }

    /// Copy a record into the encrypted vault for the other devices.
    ///
    /// Cannot throw, deliberately. Every caller has already written the record
    /// locally by the time this runs, so a failure here has to be reported as
    /// what it is rather than turning a save that worked into a save that
    /// looks like it did not.
    private func mirror(id: String, envelope: SSHVaultEnvelope) async {
        guard let vaultTier else { return }
        guard let data = try? JSONEncoder().encode(envelope),
              let plaintext = String(data: data, encoding: .utf8)
        else {
            vaultError = "This record could not be prepared for the vault."
            return
        }
        do {
            _ = try await Bridge.putSSHVaultRecord(id: id, plaintext: plaintext, tier: vaultTier)
        } catch {
            vaultError = error.localizedDescription
        }
    }

    // MARK: - Reading the vault back

    /// Merge the vault into what is on this device.
    ///
    /// A merge and not an overwrite. This used to write every arriving record
    /// straight over the local one, which meant the oldest copy on the account
    /// won: a device that had not been opened in a week put every host back in
    /// the top level, forgot its colour and forgot which key it used, on every
    /// launch. Worse, a save whose mirror had failed was reverted by the very
    /// next load, so the edit looked like it had never been made.
    ///
    /// `updatedMs` decides it now. Newer wins, and a local record that is
    /// newer is pushed back, so the account converges instead of disagreeing
    /// quietly.
    private func pullVault(tier: String) async {
        guard let records = try? await Bridge.sshVaultRecords(recovery: "", tier: tier) else { return }
        var changed = false
        // Folders first, and shallow before deep. A host names the folder it
        // belongs to and the host refuses a folder it has never heard of, so a
        // pull that applied them in arrival order could drop a server for the
        // rest of the session. Sub-folders have the same rule about parents.
        for record in ordered(records) {
            if record.deleted == true {
                // A tombstone carries no timestamp, so there is nothing to
                // compare it against. Deleting is explicit and re-creating is
                // cheap, where ignoring a delete would leave a host somebody
                // removed on their phone alive on every other device forever.
                changed = await applyDeletion(record.id) || changed
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
                        changed = true
                    case .pushLocal:
                        if let mine = hosts.first(where: { $0.id == host.id }) {
                            await mirror(id: "host:\(mine.id)", envelope: SSHVaultEnvelope(kind: "host", host: mine))
                        }
                    case .same:
                        break
                    }
                } else if let folder = envelope.folder {
                    switch verdict(remote: folder.updatedMs, local: folders.first { $0.id == folder.id }?.updatedMs) {
                    case .takeRemote:
                        _ = try await Bridge.applySSHFolder(folder)
                        changed = true
                    case .pushLocal:
                        if let mine = folders.first(where: { $0.id == folder.id }) {
                            await mirror(id: "folder:\(mine.id)", envelope: SSHVaultEnvelope(kind: "folder", folder: mine))
                        }
                    case .same:
                        break
                    }
                } else if let snippet = envelope.snippet {
                    switch verdict(remote: snippet.updatedMs, local: snippets.first { $0.id == snippet.id }?.updatedMs) {
                    case .takeRemote:
                        _ = try await Bridge.applySSHSnippet(snippet)
                        changed = true
                    case .pushLocal:
                        if let mine = snippets.first(where: { $0.id == snippet.id }) {
                            await mirror(id: "snippet:\(mine.id)", envelope: SSHVaultEnvelope(kind: "snippet", snippet: mine))
                        }
                    case .same:
                        break
                    }
                } else if let key = envelope.key {
                    changed = await applyKey(key) || changed
                }
            } catch { self.error = error.localizedDescription }
        }
        if changed { await reload() }
    }

    /// A key is the one record where an equal stamp still means work: the row
    /// can be here while the private half is not, which is what a freshly
    /// enrolled device looks like.
    private func applyKey(_ key: SSHVaultSyncedKey) async -> Bool {
        let local = keys.first { $0.id == key.id }
        let havePrivate = local.map { (try? SSHSecretStore.load(reference: $0.secretRef)) != nil } ?? false
        let take = verdict(remote: key.updatedMs, local: local?.updatedMs)
        if take == .takeRemote || (take == .same && !havePrivate) {
            do {
                let reference = try SSHSecretStore.store(key.privateKey, id: key.id)
                _ = try await Bridge.applySSHKey(SSHKeyRecord(
                    id: key.id, label: key.label, algorithm: key.algorithm,
                    publicKey: key.publicKey, secretRef: reference,
                    hardwareBacked: key.hardwareBacked, updatedMs: key.updatedMs
                ))
                return true
            } catch {
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

    /// What to do with one arriving record.
    enum MergeVerdict {
        /// The vault's copy is newer, or this device has never seen the record.
        case takeRemote
        /// This device's copy is newer, so the vault is the one that is behind.
        case pushLocal
        /// The same revision on both sides.
        case same
    }

    /// Newer wins. A record this device does not have is always taken, and a
    /// record written by a build from before stamps existed reads as 0, which
    /// loses to anything stamped and ties with anything else that never was.
    func verdict(remote: Int64, local: Int64?) -> MergeVerdict {
        guard let local else { return .takeRemote }
        if remote > local { return .takeRemote }
        if local > remote { return .pushLocal }
        return .same
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
    /// Missing on records written by a build without merge stamps, which reads
    /// as 0 and loses to anything stamped.
    var updatedMs: Int64 = 0
}

private extension String {
    func after(_ prefix: String) -> String? {
        hasPrefix(prefix) ? String(dropFirst(prefix.count)) : nil
    }
}
