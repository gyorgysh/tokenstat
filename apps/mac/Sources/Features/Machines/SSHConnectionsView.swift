// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

import Observation
import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

@MainActor
@Observable
final class SSHConnectionsModel {
    var hosts: [SSHHost] = []
    var keys: [SSHKeyRecord] = []
    var snippets: [SSHSnippet] = []
    var error: String?

    func load(vaultTier: String? = nil) async {
        do {
            async let hosts = Bridge.sshHosts()
            async let keys = Bridge.sshKeys()
            async let snippets = Bridge.sshSnippets()
            self.hosts = try await hosts
            self.keys = try await keys
            self.snippets = try await snippets
            error = nil
            if let vaultTier { await pullVault(tier: vaultTier) }
        } catch { self.error = error.localizedDescription }
    }

    private func pullVault(tier: String) async {
        guard let records = try? await Bridge.sshVaultRecords(recovery: "", tier: tier) else { return }
        var changed = false
        for record in records {
            if record.deleted == true {
                do {
                    if record.id.hasPrefix("host:") {
                        try await Bridge.deleteSSHHost(id: String(record.id.dropFirst("host:".count)))
                    } else if record.id.hasPrefix("snippet:") {
                        try await Bridge.deleteSSHSnippet(id: String(record.id.dropFirst("snippet:".count)))
                    } else if record.id.hasPrefix("key:") {
                        let id = String(record.id.dropFirst("key:".count))
                        if let key = keys.first(where: { $0.id == id }) { SSHSecretStore.delete(reference: key.secretRef) }
                        try await Bridge.deleteSSHKey(id: id)
                    }
                    changed = true
                } catch { self.error = error.localizedDescription }
                continue
            }
            guard let data = record.plaintext.data(using: .utf8),
                  let envelope = try? JSONDecoder().decode(SSHVaultEnvelope.self, from: data)
            else { continue }
            do {
                if let host = envelope.host {
                    _ = try await Bridge.saveSSHHost(host); changed = true
                } else if let snippet = envelope.snippet {
                    _ = try await Bridge.saveSSHSnippet(snippet); changed = true
                } else if let key = envelope.key {
                    let reference = try SSHSecretStore.store(key.privateKey, id: key.id)
                    _ = try await Bridge.saveSSHKey(SSHKeyRecord(id: key.id, label: key.label, algorithm: key.algorithm, publicKey: key.publicKey, secretRef: reference, hardwareBacked: key.hardwareBacked))
                    changed = true
                }
            } catch { self.error = error.localizedDescription }
        }
        if changed {
            hosts = (try? await Bridge.sshHosts()) ?? hosts
            keys = (try? await Bridge.sshKeys()) ?? keys
            snippets = (try? await Bridge.sshSnippets()) ?? snippets
        }
    }
}

private struct SSHVaultEnvelope: Codable {
    var kind: String
    var host: SSHHost?
    var key: SSHVaultSyncedKey?
    var snippet: SSHSnippet?
}

private struct SSHVaultSyncedKey: Codable {
    var id: String
    var label: String
    var algorithm: String
    var publicKey: String
    var privateKey: String
    var hardwareBacked: Bool
}

struct SSHConnectionsView: View {
    var vaultTier: String?
    var onClose: (() -> Void)? = nil
    private enum Section: String, CaseIterable { case hosts = "Hosts", keys = "Keys", snippets = "Snippets" }
    #if !os(macOS)
    @Environment(ClientStore.self) private var store
    #endif
    @State private var model = SSHConnectionsModel()
    @State private var section = Section.hosts
    @State private var addingHost = false
    @State private var addingKey = false
    @State private var addingSnippet = false
    @State private var connecting: SSHHost?
    @State private var terminal: SSHLiveTerminal?
    @State private var vaultRecovery: String?
    @State private var vaultStatus: SSHVaultStatus?
    @State private var importingDigitalOcean = false
    private var paidVaultTier: String? {
        guard let tier = vaultTier?.lowercased(), ["supporter", "patron", "legend"].contains(tier) else { return nil }
        return tier
    }

    private var signedInUnpaid: Bool { vaultTier != nil && paidVaultTier == nil }

    @ViewBuilder
    private var vaultUpgrade: some View {
        #if os(macOS)
        EmptyState(
            symbol: "lock.shield",
            title: "Sync SSH between your devices",
            message: "An encrypted vault keeps hosts and keys on every computer and phone signed in to this account. Supporter and above."
        ) {
            Link("See plans", destination: URL(string: "https://tokenstat.ai/pricing")!)
                .buttonStyle(AccentButtonStyle())
        }
        .padding(Theme.Space.m)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: Theme.cardRadius))
        .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius).strokeBorder(Theme.border))
        .padding(.horizontal)
        .padding(.top, Theme.Space.s)
        #else
        ClientEmptyState(
            kind: .needsAccount,
            title: "Sync SSH between your devices",
            message: "An encrypted vault keeps hosts and keys on every computer and phone signed in to this account. Supporter and above.",
            actionTitle: "See plans",
            actionIcon: .plans,
            action: { store.showPaywall = true },
            art: .vault
        )
        .padding(.horizontal, Theme.Space.m)
        .padding(.top, Theme.Space.s)
        #endif
    }

    var body: some View {
        VStack(spacing: 0) {
            if signedInUnpaid {
                vaultUpgrade
            } else if let vaultTier {
                SSHVaultBanner(tier: vaultTier, canWrite: paidVaultTier != nil, status: $vaultStatus, recovery: $vaultRecovery)
            }
            Picker("SSH library", selection: $section) {
                ForEach(Section.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding()
            if let error = model.error { Text(error).foregroundStyle(Theme.danger).padding(.horizontal) }
            if isCurrentSectionEmpty {
                if signedInUnpaid {
                    Spacer(minLength: 0)
                } else {
                    EmptyState(symbol: emptySymbol, title: emptyTitle, message: emptyMessage) {
                        Button(emptyActionTitle, .create) { presentAddSheet() }
                            .buttonStyle(AccentButtonStyle())
                    }
                }
            } else {
                List {
                    switch section {
                case .hosts:
                    ForEach(model.hosts) { host in
                        Button { connecting = host } label: {
                            Label {
                                VStack(alignment: .leading) {
                                    Text(host.label)
                                    Text("\(host.username)@\(host.hostname):\(host.port)")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            } icon: { Image(systemName: "server.rack") }
                        }.buttonStyle(.plain)
                    }.onDelete { offsets in deleteHosts(offsets) }
                case .keys:
                    ForEach(model.keys) { key in
                        Label {
                            VStack(alignment: .leading) { Text(key.label); Text(key.publicKey).font(.caption).lineLimit(1) }
                        } icon: { Image(systemName: key.hardwareBacked ? "key.radiowaves.forward" : "key.fill") }
                    }.onDelete { offsets in deleteKeys(offsets) }
                case .snippets:
                    ForEach(model.snippets) { snippet in
                        VStack(alignment: .leading) { Text(snippet.title); Text(snippet.command).font(.system(.caption, design: .monospaced)) }
                    }.onDelete { offsets in deleteSnippets(offsets) }
                    }
                }
            }
        }
        .navigationTitle("SSH")
        .toolbar {
            if let onClose {
                ToolbarItem(placement: .cancellationAction) {
                    InspectorCloseButton(action: onClose, help: "Close", label: "Close SSH library")
                }
            }
            ToolbarItem(placement: .primaryAction) {
                ToolbarIconButton(systemImage: "plus", help: "Add \(section.rawValue.lowercased())") {
                    presentAddSheet()
                }
            }
            ToolbarItem(placement: .primaryAction) {
                ToolbarIconButton(systemImage: "cloud", help: "Import cloud servers") { importingDigitalOcean = true }
            }
        }
        .task { await model.load(vaultTier: paidVaultTier) }
        .task { vaultStatus = try? await Bridge.sshVaultStatus() }
        .sheet(isPresented: $addingHost) { SSHHostForm(model: model, vaultTier: paidVaultTier) }
        .sheet(isPresented: $addingKey) { SSHKeyForm(model: model, vaultTier: paidVaultTier) }
        .sheet(isPresented: $addingSnippet) { SSHSnippetForm(model: model, vaultTier: paidVaultTier) }
        .sheet(isPresented: $importingDigitalOcean) { CloudImportForm(model: model, vaultTier: paidVaultTier) }
        .sheet(item: $connecting) { host in SSHConnectForm(host: host, model: model) { terminal = $0 } }
        #if os(macOS)
        .sheet(item: $terminal) { SSHLiveTerminalScreen(session: $0).frame(minWidth: 720, minHeight: 480) }
        #else
        .fullScreenCover(item: $terminal) { SSHLiveTerminalScreen(session: $0) }
        #endif
    }

    private func deleteHosts(_ offsets: IndexSet) { for i in offsets { let id = model.hosts[i].id; Task { do { if paidVaultTier != nil { _ = try await Bridge.deleteSSHVaultRecord(id: "host:\(id)") }; try await Bridge.deleteSSHHost(id: id); await model.load(vaultTier: paidVaultTier) } catch { model.error = error.localizedDescription } } } }
    private func deleteKeys(_ offsets: IndexSet) { for i in offsets { let key = model.keys[i]; Task { do { if paidVaultTier != nil { _ = try await Bridge.deleteSSHVaultRecord(id: "key:\(key.id)") }; try await Bridge.deleteSSHKey(id: key.id); SSHSecretStore.delete(reference: key.secretRef); await model.load(vaultTier: paidVaultTier) } catch { model.error = error.localizedDescription } } } }
    private func deleteSnippets(_ offsets: IndexSet) { for i in offsets { let id = model.snippets[i].id; Task { do { if paidVaultTier != nil { _ = try await Bridge.deleteSSHVaultRecord(id: "snippet:\(id)") }; try await Bridge.deleteSSHSnippet(id: id); await model.load(vaultTier: paidVaultTier) } catch { model.error = error.localizedDescription } } } }
    private var isCurrentSectionEmpty: Bool { switch section { case .hosts: model.hosts.isEmpty; case .keys: model.keys.isEmpty; case .snippets: model.snippets.isEmpty } }
    private var emptySymbol: String { switch section { case .hosts: "server.rack"; case .keys: "key"; case .snippets: "text.badge.plus" } }
    private var emptyTitle: String { "No \(section.rawValue.lowercased()) yet" }
    private var emptyMessage: String { switch section {
        case .hosts: "Add a server once, then connect without retyping its address and username."
        case .keys: "Generate or import an SSH key to authenticate without a password."
        case .snippets: "Save commands you use often and run them from a terminal."
    } }
    private var emptyActionTitle: String { switch section { case .hosts: "Add host"; case .keys: "Add key"; case .snippets: "Add snippet" } }
    private func presentAddSheet() { switch section { case .hosts: addingHost = true; case .keys: addingKey = true; case .snippets: addingSnippet = true } }
}

private struct CloudImportForm: View {
    private enum Provider: String, CaseIterable { case digitalOcean = "DigitalOcean", aws = "AWS" }
    @Environment(\.dismiss) private var dismiss
    let model: SSHConnectionsModel
    let vaultTier: String?
    @State private var token = ""
    @State private var username = "root"
    @State private var provider = Provider.digitalOcean
    @State private var profile = "default"
    @State private var region = ""
    @State private var error: String?
    @State private var importing = false
    @State private var importedCount: Int?
    var body: some View {
        NavigationStack {
            Form {
                Picker("Provider", selection: $provider) { ForEach(Provider.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                if provider == .digitalOcean { SecureField("Read-only API token", text: $token) }
                else { TextField("AWS CLI profile", text: $profile); TextField("Region (optional)", text: $region) }
                TextField("SSH username", text: $username)
                Text(provider == .digitalOcean ? "Only the Droplets list is read. The token is used once and is not saved." : "Uses your existing AWS CLI profile and only calls describe-instances. AWS keys never enter tokenstat.").font(.caption).foregroundStyle(.secondary)
                if let importedCount {
                    Label(importedCount == 1 ? "Imported 1 host" : "Imported \(importedCount) hosts", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(Theme.success)
                }
                if importing { ProgressView("Reading server list…") }
                if let error { Text(error).foregroundStyle(Theme.danger) }
            }
            .navigationTitle("Import cloud servers")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { InspectorCloseButton(action: { dismiss() }, help: "Close", label: "Close cloud import") }
                ToolbarItem(placement: .confirmationAction) {
                    if importedCount != nil {
                        Button("Done") { dismiss() }.buttonStyle(AccentButtonStyle(small: true))
                    } else {
                        Button("Import", .download) { Task { await run() } }
                            .buttonStyle(AccentButtonStyle(small: true))
                            .disabled(importing || (provider == .digitalOcean && token.isEmpty) || username.isEmpty)
                    }
                }
            }
        }.sshSheetFrame(width: 520, height: 380)
    }
    private func run() async {
        importing = true
        error = nil
        do {
            let result: SSHHostImport
            if provider == .digitalOcean { result = try await Bridge.importDigitalOcean(token: token, username: username) }
            else { result = try await Bridge.importAWS(profile: profile.isEmpty ? nil : profile, region: region.isEmpty ? nil : region, username: username) }
            if let vaultTier {
                for host in result.hosts {
                    let plaintext = try vaultJSON(SSHVaultEnvelope(kind: "host", host: host, key: nil, snippet: nil))
                    _ = try await Bridge.putSSHVaultRecord(id: "host:\(host.id)", plaintext: plaintext, tier: vaultTier)
                }
            }
            token = ""
            importedCount = result.imported
            await model.load(vaultTier: vaultTier)
        }
        catch { self.error = error.localizedDescription }
        importing = false
    }
}

private struct SSHVaultBanner: View {
    let tier: String
    let canWrite: Bool
    @Binding var status: SSHVaultStatus?
    @Binding var recovery: String?
    @State private var error: String?
    @State private var showingSetup = false
    @State private var showingRecovery = false
    @State private var confirmingRotation = false
    @State private var confirmingReset = false
    @State private var enrollmentRequests: [SSHVaultEnrollment] = []
    var body: some View {
        GroupBox {
            if recovery != nil {
                HStack {
                    Label("Recovery words have not been confirmed", systemImage: "exclamationmark.shield.fill")
                    Spacer()
                    Button("Show words", .reveal) { showingRecovery = true }.buttonStyle(AccentButtonStyle(small: true))
                    Button("Discard vault", .delete) { confirmingReset = true }.buttonStyle(SecondaryButtonStyle(small: true))
                }
            } else if status?.created == true {
                HStack {
                    Label("Encrypted vault ready · \(status?.recordCount ?? 0) records", systemImage: "lock.shield.fill")
                    Spacer()
                    if status?.enrolled == false { Button("Enroll this device", .device) { showingSetup = true }.buttonStyle(SecondaryButtonStyle(small: true)) }
                    else if canWrite { Button("New recovery words", .refresh) { confirmingRotation = true }.buttonStyle(SecondaryButtonStyle(small: true)) }
                    else { Text("Read-only after downgrade").font(.caption).foregroundStyle(.secondary) }
                    if canWrite { Button("Delete vault", .delete) { confirmingReset = true }.buttonStyle(SecondaryButtonStyle(small: true)) }
                }
            } else {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Sync encrypted SSH secrets across your devices.")
                        Text("Only your devices and 24 recovery words can decrypt it.").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if canWrite {
                        Button("Set up vault", .security) { showingSetup = true }
                            .buttonStyle(AccentButtonStyle(small: true))
                    } else {
                        Text("Supporter required to create a vault")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            if let error { Text(error).foregroundStyle(Theme.danger) }
            ForEach(enrollmentRequests) { request in
                HStack {
                    Label("A device is waiting to join", systemImage: "iphone.and.arrow.forward")
                    Text(String(request.publicIdentity.prefix(12)) + "…").font(Theme.mono(11)).foregroundStyle(.secondary)
                    Spacer()
                    Button("Approve", .approve) { Task { await approve(request) } }.buttonStyle(AccentButtonStyle(small: true))
                }
            }
        }
        .padding(.horizontal)
        .sheet(isPresented: $showingSetup) {
            SSHVaultSetupSheet(tier: tier, status: $status, recovery: $recovery)
        }
        .sheet(isPresented: $showingRecovery) {
            if let recovery {
                SSHRecoveryWordsSheet(recovery: recovery, onConfirmed: { self.recovery = nil }, onDiscard: { Task { await resetVault() } })
            }
        }
        .onChange(of: recovery) { _, value in if value != nil { showingRecovery = true } }
        .confirmationDialog("Replace the current recovery words?", isPresented: $confirmingRotation, titleVisibility: .visible) {
            Button("Generate new recovery words", role: .destructive) { Task { await rotateRecovery() } }
            Button("Cancel", role: .cancel) {}
        } message: { Text("The current words will stop working as soon as the encrypted update succeeds.") }
        .confirmationDialog("Delete this vault?", isPresented: $confirmingReset, titleVisibility: .visible) {
            Button("Delete vault", role: .destructive) { Task { await resetVault() } }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Every encrypted SSH secret in the vault is permanently lost. Other devices will need to set up a new vault. This cannot be undone.") }
        .task(id: status?.enrolled) {
            guard status?.enrolled == true else { return }
            enrollmentRequests = (try? await Bridge.sshVaultEnrollmentRequests()) ?? []
        }
    }
    private func rotateRecovery() async {
        do { recovery = try await Bridge.rotateSSHVaultRecovery().recovery; status = try await Bridge.sshVaultStatus() }
        catch { self.error = error.localizedDescription }
    }
    private func resetVault() async {
        do {
            try await Bridge.resetSSHVault()
            recovery = nil
            showingRecovery = false
            showingSetup = false
            enrollmentRequests = []
            status = try await Bridge.sshVaultStatus()
        } catch { self.error = error.localizedDescription }
    }
    private func approve(_ request: SSHVaultEnrollment) async {
        do { _ = try await Bridge.approveSSHVaultEnrollment(request); enrollmentRequests.removeAll { $0.id == request.id } }
        catch { self.error = error.localizedDescription }
    }
}

private struct SSHRecoveryWordsSheet: View {
    @Environment(\.dismiss) private var dismiss
    let recovery: String
    let onConfirmed: () -> Void
    let onDiscard: () -> Void
    @State private var storedSafely = false
    @State private var confirmingDiscard = false
    @State private var confirmation3 = ""
    @State private var confirmation11 = ""
    @State private var confirmation20 = ""
    @State private var copied = false
    private var words: [String] { recovery.split(whereSeparator: \.isWhitespace).map(String.init) }
    private var wordsMatch: Bool {
        words.count == 24
            && confirmation3.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == words[2]
            && confirmation11.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == words[10]
            && confirmation20.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == words[19]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Save your recovery words").font(.title3.weight(.semibold))
                    Text("This is the only recovery method if every enrolled device is lost.").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                InspectorCloseButton(action: { dismiss() }, help: "Close", label: "Close recovery words")
            }
            Divider()
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .leading), count: 3), spacing: 10) {
                ForEach(Array(words.enumerated()), id: \.offset) { index, word in
                    HStack(spacing: 8) {
                        Text("\(index + 1)").font(Theme.mono(10)).foregroundStyle(.tertiary).frame(width: 18, alignment: .trailing)
                        Text(word).font(.system(.body, design: .monospaced).weight(.medium))
                    }
                    .padding(.horizontal, 10).padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.panel, in: RoundedRectangle(cornerRadius: 8))
                }
            }
            Text("Store these offline in a password manager or on paper. Do not rely on this screen or a screenshot.")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                Button(action: copyWords) {
                    Label(copied ? "Copied" : "Copy all words", systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                    .buttonStyle(SecondaryButtonStyle(small: true))
                Text("The clipboard may be visible to other apps; clear it after saving.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Toggle("I stored all 24 words in a safe place", isOn: $storedSafely)
            if storedSafely {
                VStack(alignment: .leading, spacing: Theme.Space.s) {
                    Text("Confirm three words").font(.callout.weight(.semibold))
                    HStack {
                        TextField("Word 3", text: $confirmation3).textFieldStyle(.roundedBorder)
                        TextField("Word 11", text: $confirmation11).textFieldStyle(.roundedBorder)
                        TextField("Word 20", text: $confirmation20).textFieldStyle(.roundedBorder)
                    }
                    if !confirmation3.isEmpty || !confirmation11.isEmpty || !confirmation20.isEmpty {
                        Text(wordsMatch ? "Recovery words match." : "Enter words 3, 11, and 20 exactly as shown.")
                            .font(.caption).foregroundStyle(wordsMatch ? Theme.success : Theme.danger)
                    }
                }
            }
            HStack {
                Button("Discard this vault", .delete) { confirmingDiscard = true }
                    .buttonStyle(.borderless)
                    .foregroundStyle(Theme.danger)
                Spacer()
                Button("Done", .done) { onConfirmed(); dismiss() }
                    .buttonStyle(AccentButtonStyle()).disabled(!storedSafely || !wordsMatch)
            }
            Text("Close without confirming to look at the words later. Discard deletes the vault so you can create a new one.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(Theme.Space.l)
        .sshSheetFrame(width: 680, height: 670)
        .confirmationDialog("Delete this vault?", isPresented: $confirmingDiscard, titleVisibility: .visible) {
            Button("Delete vault", role: .destructive) { onDiscard(); dismiss() }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Every encrypted SSH secret in the vault is permanently lost. This cannot be undone.") }
    }

    private func copyWords() {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(recovery, forType: .string)
        #else
        UIPasteboard.general.string = recovery
        #endif
        copied = true
    }
}

private struct SSHVaultSetupSheet: View {
    private enum Choice: String, CaseIterable { case create = "Create new", restore = "Recovery words", request = "Ask a device" }
    @Environment(\.dismiss) private var dismiss
    let tier: String
    @Binding var status: SSHVaultStatus?
    @Binding var recovery: String?
    @State private var choice = Choice.create
    @State private var enteredRecovery = ""
    @State private var working = false
    @State private var error: String?
    @State private var requestSent = false
    @State private var confirmingReset = false

    private var choices: [Choice] {
        if status?.created == true && status?.enrolled == false { return [.restore, .request] }
        return [.create, .restore]
    }

    private var confirmTitle: String {
        switch choice {
        case .create: return "Create vault"
        case .request: return "Request approval"
        case .restore: return "Restore vault"
        }
    }

    private var confirmIcon: ActionIcon {
        switch choice {
        case .create: return .create
        case .request: return .pair
        case .restore: return .restore
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Set up encrypted vault").font(.title3.weight(.semibold))
                    Text("tokenstat cannot recover the secrets if the words and every device are lost").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                InspectorCloseButton(action: { dismiss() }, help: "Close", label: "Close vault setup")
            }
            Divider()
            Picker("Vault action", selection: $choice) { ForEach(choices, id: \.self) { Text($0.rawValue).tag($0) } }
                .pickerStyle(.segmented)
                .onAppear { if !choices.contains(choice) { choice = choices[0] } }
                .onChange(of: status?.created) { _, _ in if !choices.contains(choice) { choice = choices[0] } }
            if choice == .request {
                Label(requestSent ? "Request sent. Keep this screen open while an enrolled device approves it." : "An enrolled device will see a content-free approval request for 15 minutes.", systemImage: requestSent ? "checkmark.circle.fill" : "iphone.and.arrow.forward")
                    .foregroundStyle(requestSent ? Theme.success : Color.gray)
            } else if choice == .restore {
                Text("Enter all 24 recovery words in order. Words are checked locally and are never sent to tokenstat.ai.")
                    .font(.callout).foregroundStyle(.secondary)
                TextEditor(text: $enteredRecovery)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 130)
                    .padding(8)
                    .background(Theme.panel, in: RoundedRectangle(cornerRadius: 10))
            } else {
                Label("A random vault key is created on this device.", systemImage: "key.horizontal")
                Label("You will confirm and store 24 standard recovery words.", systemImage: "text.book.closed")
                Label("Losing every enrolled device and the words permanently loses the vault.", systemImage: "exclamationmark.shield")
            }
            if status?.created == true {
                Text("If you no longer have the recovery words and cannot ask a device, drop this vault and create a new one. Stored secrets are lost.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            if let error { Text(error).font(.caption).foregroundStyle(Theme.danger) }
            Spacer()
            HStack {
                Button("Cancel", .dismiss) { dismiss() }.buttonStyle(.borderless)
                if status?.created == true {
                    Button("Drop vault", .delete) { confirmingReset = true }
                        .buttonStyle(.borderless)
                        .foregroundStyle(Theme.danger)
                        .disabled(working)
                }
                Spacer()
                Button(action: { Task { await run() } }) {
                    confirmIcon.label(confirmTitle)
                }
                .buttonStyle(AccentButtonStyle())
                .disabled(working || requestSent || (choice == .restore && enteredRecovery.split(whereSeparator: \.isWhitespace).count != 24) || (choice == .create && status?.created == true))
            }
        }
        .padding(Theme.Space.l)
        .sshSheetFrame(width: 560, height: 460)
        .confirmationDialog("Delete this vault?", isPresented: $confirmingReset, titleVisibility: .visible) {
            Button("Delete vault", role: .destructive) { Task { await resetVault() } }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Every encrypted SSH secret in the vault is permanently lost. Other devices will need to set up a new vault. This cannot be undone.") }
    }

    private func run() async {
        working = true; error = nil
        do {
            if choice == .create {
                recovery = try await Bridge.createSSHVault(tier: tier).recovery
            } else if choice == .request {
                _ = try await Bridge.requestSSHVaultEnrollment()
                requestSent = true
                working = false
                return
            } else {
                _ = try await Bridge.unlockSSHVault(recovery: enteredRecovery, tier: tier)
            }
            status = try await Bridge.sshVaultStatus()
            dismiss()
        } catch { self.error = error.localizedDescription }
        working = false
    }

    private func resetVault() async {
        working = true
        error = nil
        do {
            try await Bridge.resetSSHVault()
            recovery = nil
            requestSent = false
            status = try await Bridge.sshVaultStatus()
            choice = .create
        } catch { self.error = error.localizedDescription }
        working = false
    }
}

private struct SSHHostForm: View {
    @Environment(\.dismiss) private var dismiss
    let model: SSHConnectionsModel
    let vaultTier: String?
    @State private var label = ""
    @State private var hostname = ""
    @State private var username = "root"
    @State private var port = 22
    @State private var initialDirectory = "~"
    @State private var credentialID = ""
    @State private var error: String?
    var body: some View { NavigationStack { Form { Section("Connection") { TextField("Name", text: $label); TextField("Address", text: $hostname); TextField("Username", text: $username); TextField("Port", value: $port, format: .number); TextField("Starting directory", text: $initialDirectory, prompt: Text("~")) }; Section("Authentication") { Picker("Use", selection: $credentialID) { Text("Ask when connecting").tag(""); ForEach(model.keys) { Text($0.label).tag($0.id) } }; Text("Passwords are requested only when you connect and are never saved. Add a key first if you want this host to select it automatically.").font(.caption).foregroundStyle(.secondary) }; if let error { Text(error).foregroundStyle(Theme.danger) } }.navigationTitle("Add SSH host").toolbar { ToolbarItem(placement: .cancellationAction) { InspectorCloseButton(action: { dismiss() }, help: "Close", label: "Close add host") }; ToolbarItem(placement: .confirmationAction) { Button("Save", .save) { Task { await save() } }.buttonStyle(AccentButtonStyle(small: true)).disabled(label.isEmpty || hostname.isEmpty || username.isEmpty) } } }.sshSheetFrame(width: 500, height: 430) }
    private func save() async { do { let host = try await Bridge.saveSSHHost(SSHHost(id: "", label: label, hostname: hostname, port: port, username: username, initialDirectory: initialDirectory.isEmpty ? "~" : initialDirectory, credentialID: credentialID.isEmpty ? nil : credentialID, jumpHostID: nil, tags: [], provider: nil, hostKeys: [])); if let vaultTier { let plaintext = try vaultJSON(SSHVaultEnvelope(kind: "host", host: host, key: nil, snippet: nil)); _ = try await Bridge.putSSHVaultRecord(id: "host:\(host.id)", plaintext: plaintext, tier: vaultTier) }; await model.load(); dismiss() } catch { self.error = error.localizedDescription } }
}

private struct SSHKeyForm: View {
    @Environment(\.dismiss) private var dismiss
    let model: SSHConnectionsModel
    let vaultTier: String?
    @State private var label = "My SSH key"
    @State private var pem = ""
    @State private var passphrase = ""
    @State private var error: String?
    var body: some View { NavigationStack { Form { TextField("Name", text: $label); TextEditor(text: $pem).font(.system(.caption, design: .monospaced)); SecureField("Private-key passphrase (if required)", text: $passphrase); if let error { Text(error).foregroundStyle(Theme.danger) } }.navigationTitle("Add key").toolbar { ToolbarItem(placement: .cancellationAction) { InspectorCloseButton(action: { dismiss() }, help: "Close", label: "Close add key") }; ToolbarItemGroup(placement: .confirmationAction) { Button("Generate", .create) { Task { do { await keep(try await Bridge.generateSSHKey()) } catch { self.error = error.localizedDescription } } }.buttonStyle(SecondaryButtonStyle(small: true)); Button("Import", .upload) { Task { do { await keep(try await Bridge.inspectSSHKey(pem: pem, passphrase: passphrase.isEmpty ? nil : passphrase)) } catch { self.error = error.localizedDescription } } }.buttonStyle(AccentButtonStyle(small: true)).disabled(pem.isEmpty) } } }.sshSheetFrame(width: 540, height: 460) }
    private func keep(_ material: SSHKeyMaterial) async { do { let id = "key_\(UUID().uuidString)"; let ref = try SSHSecretStore.store(material.privateKey, id: id); let key = try await Bridge.saveSSHKey(SSHKeyRecord(id: id, label: label, algorithm: material.algorithm, publicKey: material.publicKey, secretRef: ref, hardwareBacked: false)); if let vaultTier { let synced = SSHVaultSyncedKey(id: key.id, label: key.label, algorithm: key.algorithm, publicKey: key.publicKey, privateKey: material.privateKey, hardwareBacked: key.hardwareBacked); let plaintext = try vaultJSON(SSHVaultEnvelope(kind: "key", host: nil, key: synced, snippet: nil)); _ = try await Bridge.putSSHVaultRecord(id: "key:\(key.id)", plaintext: plaintext, tier: vaultTier) }; await model.load(); dismiss() } catch { self.error = error.localizedDescription } }
}

private struct SSHSnippetForm: View {
    @Environment(\.dismiss) private var dismiss
    let model: SSHConnectionsModel
    let vaultTier: String?
    @State private var title = ""
    @State private var command = ""
    @State private var error: String?
    var body: some View { NavigationStack { Form { TextField("Name", text: $title); TextEditor(text: $command).font(.system(.body, design: .monospaced)); if let error { Text(error).foregroundStyle(Theme.danger) } }.navigationTitle("Add snippet").toolbar { ToolbarItem(placement: .cancellationAction) { InspectorCloseButton(action: { dismiss() }, help: "Close", label: "Close add snippet") }; ToolbarItem(placement: .confirmationAction) { Button("Save", .save) { Task { await save() } }.buttonStyle(AccentButtonStyle(small: true)).disabled(title.isEmpty || command.isEmpty) } } }.sshSheetFrame(width: 500, height: 380) }
    private func save() async { do { let snippet = try await Bridge.saveSSHSnippet(SSHSnippet(id: "", title: title, command: command, tags: [], hostIDs: [])); if let vaultTier { let plaintext = try vaultJSON(SSHVaultEnvelope(kind: "snippet", host: nil, key: nil, snippet: snippet)); _ = try await Bridge.putSSHVaultRecord(id: "snippet:\(snippet.id)", plaintext: plaintext, tier: vaultTier) }; await model.load(); dismiss() } catch { self.error = error.localizedDescription } }
}

private func vaultJSON<T: Encodable>(_ value: T) throws -> String {
    let data = try JSONEncoder().encode(value)
    guard let text = String(data: data, encoding: .utf8) else {
        throw NSError(domain: "SSHVault", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not encode vault record"])
    }
    return text
}

private struct SSHConnectForm: View {
    @Environment(\.dismiss) private var dismiss
    @State var host: SSHHost
    let model: SSHConnectionsModel
    let connected: (SSHLiveTerminal) -> Void
    @State private var password = ""
    @State private var selectedKeyID = ""
    @State private var offeredFingerprint: String?
    @State private var error: String?
    var body: some View {
        NavigationStack {
            Form {
                if host.hostKeys.isEmpty {
                    Text("Verify the server identity before sending credentials.")
                    Button("Show fingerprint", .security) { Task { await probe() } }
                    if let offeredFingerprint {
                        Text(offeredFingerprint).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                        Button("Trust this fingerprint", .approve) { Task { await trust(offeredFingerprint) } }
                    }
                } else {
                    Picker("Authentication", selection: $selectedKeyID) {
                        Text("Password").tag("")
                        ForEach(model.keys) { Text($0.label).tag($0.id) }
                    }
                    if selectedKeyID.isEmpty { SecureField("Password", text: $password) }
                    Button("Connect", .connect) { Task { await connect() } }
                        .disabled(selectedKeyID.isEmpty && password.isEmpty)
                }
                if let error { Text(error).foregroundStyle(Theme.danger) }
            }
            .navigationTitle(host.label)
            .toolbar { ToolbarItem(placement: .cancellationAction) { InspectorCloseButton(action: { dismiss() }, help: "Close", label: "Close connection") } }
        }
        .sshSheetFrame(width: 500, height: 360)
        .onAppear { selectedKeyID = host.credentialID ?? "" }
    }
    private func probe() async {
        do { offeredFingerprint = try await Bridge.probeSSHHost(host).fingerprint }
        catch { self.error = error.localizedDescription }
    }
    private func trust(_ fingerprint: String) async {
        do {
            host.hostKeys = [fingerprint]
            _ = try await Bridge.saveSSHHost(host)
            offeredFingerprint = nil
            await model.load()
        } catch { self.error = error.localizedDescription }
    }
    private func connect() async {
        do {
            let handle: SSHSessionHandle
            if let key = model.keys.first(where: { $0.id == selectedKeyID }) {
                if key.secretRef.hasPrefix("agent:") {
                    handle = try await Bridge.openSSHWithAgent(host, fingerprint: String(key.secretRef.dropFirst("agent:".count)), rows: 24, cols: 80)
                } else {
                    let pem = try SSHSecretStore.load(reference: key.secretRef)
                    handle = try await Bridge.openSSHWithKey(host, pem: pem, passphrase: nil, rows: 24, cols: 80)
                }
            } else {
                handle = try await Bridge.openSSHWithPassword(host, password: password, rows: 24, cols: 80)
            }
            connected(SSHLiveTerminal(handle: handle, title: host.label))
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}

private extension View {
    @ViewBuilder
    func sshSheetFrame(width: CGFloat, height: CGFloat) -> some View {
        #if os(macOS)
        frame(width: width, height: height)
        #else
        frame(maxWidth: .infinity, maxHeight: .infinity)
        #endif
    }
}
