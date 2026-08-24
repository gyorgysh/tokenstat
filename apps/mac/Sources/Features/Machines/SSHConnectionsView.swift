// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

import Observation
import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Read a cloud provider's server list and save what it finds.
///
/// A screen in the library rather than a sheet, so the result is a list a
/// person can read rather than a line at the bottom of a small box.
struct CloudImportForm: View {
    private enum Provider: String, CaseIterable { case digitalOcean = "DigitalOcean", aws = "AWS" }
    let model: SSHLibraryModel
    let onDone: () -> Void
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
        }
        .safeAreaInset(edge: .bottom) {
            SSHEditorFooter(
                saveTitle: importedCount == nil ? "Import" : "Done",
                canSave: importedCount != nil
                    || (!(provider == .digitalOcean && token.isEmpty) && !username.isEmpty),
                working: importing,
                onSave: {
                    if importedCount == nil { Task { await run() } } else { onDone() }
                },
                onCancel: onDone,
                onDelete: nil
            )
        }
    }
    private func run() async {
        importing = true
        error = nil
        do {
            let result: SSHHostImport
            if provider == .digitalOcean { result = try await Bridge.importDigitalOcean(token: token, username: username) }
            else { result = try await Bridge.importAWS(profile: profile.isEmpty ? nil : profile, region: region.isEmpty ? nil : region, username: username) }
            // Saving each one through the model is what puts it in the
            // encrypted vault as well, so an import reaches the phone the same
            // way a hand-typed host does.
            for host in result.hosts { _ = await model.save(host: host) }
            token = ""
            importedCount = result.imported
        }
        catch { self.error = error.localizedDescription }
        importing = false
    }
}

/// The 24 words, then the three that prove they were written down.
///
/// Two steps, because one surface is not a confirmation. The old screen showed
/// the grid, a "I stored all 24 words" toggle, and then three fields asking for
/// words 3, 11 and 20 with the grid still on screen: an answer you can read off
/// is a typing exercise, not a check.
///
/// Going back is allowed and re-showing the words is a deliberate action, so
/// nobody is trapped and nobody confirms by reading.
struct SSHRecoveryWordsSheet: View {
    @Environment(\.dismiss) private var dismiss
    let recovery: String
    let onConfirmed: () -> Void
    let onDiscard: () -> Void

    private enum Step { case read, confirm }

    @State private var step = Step.read
    @State private var confirmingDiscard = false
    @State private var confirmation3 = ""
    @State private var confirmation11 = ""
    @State private var confirmation20 = ""
    @State private var copied = false

    private var words: [String] { recovery.split(whereSeparator: \.isWhitespace).map(String.init) }
    private var typedAnything: Bool {
        !confirmation3.isEmpty || !confirmation11.isEmpty || !confirmation20.isEmpty
    }

    private var wordsMatch: Bool {
        words.count == 24
            && confirmation3.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == words[2]
            && confirmation11.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == words[10]
            && confirmation20.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == words[19]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            header
            Divider()
            switch step {
            case .read: readStep
            case .confirm: confirmStep
            }
            Spacer(minLength: 0)
            footer
        }
        .padding(Theme.Space.l)
        .sshSheetFrame(width: 680, height: 670)
        .confirmationDialog("Delete this vault?", isPresented: $confirmingDiscard, titleVisibility: .visible) {
            Button("Delete vault", role: .destructive) { onDiscard(); dismiss() }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Every encrypted SSH secret in the vault is permanently lost. This cannot be undone.") }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(step == .read ? "Save your recovery words" : "Confirm three words")
                    .font(.title3.weight(.semibold))
                Text(step == .read
                    ? "This is the only recovery method if every enrolled device is lost."
                    : "The words are off screen on purpose. Type them from where you saved them.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            InspectorCloseButton(action: { dismiss() }, help: "Close", label: "Close recovery words")
        }
    }

    // MARK: - Step one: read them

    private var readStep: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
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
        }
    }

    // MARK: - Step two: prove it

    private var confirmStep: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            Text("Enter words 3, 11 and 20 exactly as they were written.")
                .font(.callout)
            HStack {
                field("Word 3", text: $confirmation3)
                field("Word 11", text: $confirmation11)
                field("Word 20", text: $confirmation20)
            }
            if typedAnything {
                Text(wordsMatch ? "Recovery words match." : "That is not what was generated.")
                    .font(.caption).foregroundStyle(wordsMatch ? Theme.success : Theme.danger)
            }
            Button("Show the words again", .reveal) {
                step = .read
                confirmation3 = ""
                confirmation11 = ""
                confirmation20 = ""
            }
            .buttonStyle(SecondaryButtonStyle(small: true))
            Text("Going back is fine. It clears what was typed, so the words still have to be read from where you saved them.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func field(_ prompt: String, text: Binding<String>) -> some View {
        TextField(prompt, text: text)
            .textFieldStyle(.roundedBorder)
            #if !os(macOS)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            #endif
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            HStack {
                Button("Discard this vault", .delete) { confirmingDiscard = true }
                    .buttonStyle(DestructiveButtonStyle())
                Spacer()
                if step == .read {
                    Button("I have saved these", .next) { step = .confirm }
                        .buttonStyle(AccentButtonStyle())
                        .frame(minWidth: Theme.Control.pairedWidth)
                } else {
                    Button("Done", .done) { onConfirmed(); dismiss() }
                        .buttonStyle(AccentButtonStyle())
                        .frame(minWidth: Theme.Control.pairedWidth)
                        .disabled(!wordsMatch)
                }
            }
            Text("Close without confirming to look at the words later. Discard deletes the vault so you can create a new one.")
                .font(.caption).foregroundStyle(.secondary)
        }
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

struct SSHVaultSetupSheet: View {
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
                Button("Cancel", .dismiss) { dismiss() }
                    .buttonStyle(SecondaryButtonStyle())
                    .frame(minWidth: Theme.Control.pairedWidth)
                if status?.created == true {
                    Button("Drop vault", .delete) { confirmingReset = true }
                        .buttonStyle(DestructiveButtonStyle())
                        .disabled(working)
                }
                Spacer()
                Button(action: { Task { await run() } }) {
                    confirmIcon.label(confirmTitle)
                }
                .buttonStyle(AccentButtonStyle())
                .frame(minWidth: Theme.Control.pairedWidth)
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

struct SSHConnectForm: View {
    @Environment(\.dismiss) private var dismiss
    @State var host: SSHHost
    let model: SSHLibraryModel
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
            _ = await model.save(host: host)
            offeredFingerprint = nil
        } catch { self.error = error.localizedDescription }
    }
    private func connect() async {
        do {
            // Resolved here rather than in the host, because the private key
            // lives in this device's vault and nowhere else.
            var jump: [String: Any]?
            if let jumpID = host.jumpHostID,
               let jumpHost = model.hosts.first(where: { $0.id == jumpID })
            {
                jump = try Bridge.sshJumpPayload(jumpHost, key: model.key(jumpHost.credentialID))
            }
            let handle: SSHSessionHandle
            if let key = model.keys.first(where: { $0.id == selectedKeyID }) {
                if key.secretRef.hasPrefix("agent:") {
                    handle = try await Bridge.openSSHWithAgent(host, fingerprint: String(key.secretRef.dropFirst("agent:".count)), rows: 24, cols: 80, jump: jump)
                } else {
                    let pem = try SSHSecretStore.load(reference: key.secretRef)
                    handle = try await Bridge.openSSHWithKey(host, pem: pem, passphrase: nil, rows: 24, cols: 80, jump: jump)
                }
            } else {
                handle = try await Bridge.openSSHWithPassword(host, password: password, rows: 24, cols: 80, jump: jump)
            }
            connected(SSHLiveTerminal(handle: handle, title: host.label))
            await model.noteConnection(host)
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}

extension View {
    /// A sheet in the SSH path: a fixed size on the Mac, the whole screen on
    /// a phone.
    @ViewBuilder
    func sshSheetFrame(width: CGFloat, height: CGFloat) -> some View {
        #if os(macOS)
        frame(width: width, height: height)
        #else
        frame(maxWidth: .infinity, maxHeight: .infinity)
        #endif
    }
}
