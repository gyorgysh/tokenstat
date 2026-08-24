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

/// Create the account's one vault, or open it on this device.
///
/// One password, and the recovery code is only the way back if it is
/// forgotten. The old version of this screen offered "Create new", "Recovery
/// words" and "Ask a device", which is three ways to say "which of the several
/// vaults did you mean", and the answer is that an account has one.
struct SSHVaultSetupSheet: View {
    @Environment(\.dismiss) private var dismiss
    let tier: String
    @Binding var status: SSHVaultStatus?
    @Binding var recovery: String?

    @State private var password = ""
    @State private var confirmPassword = ""
    @State private var enteredRecovery = ""
    @State private var forgot = false
    @State private var working = false
    @State private var error: String?
    @State private var confirmingReset = false

    /// The vault exists, so this is an unlock rather than a creation.
    private var exists: Bool { status?.created == true }
    /// Made before password unlock existed and cannot be opened by this build.
    private var stale: Bool { status?.needsRecreate == true }

    private var problems: [String] { VaultPassword.problems(password) }
    private var matches: Bool { password == confirmPassword }

    private var canConfirm: Bool {
        if working { return false }
        if stale { return false }
        if exists {
            return forgot ? !enteredRecovery.trimmingCharacters(in: .whitespaces).isEmpty
                          : !password.isEmpty
        }
        return problems.isEmpty && matches
    }

    private var title: String {
        if stale { return "This vault has to be recreated" }
        return exists ? "Unlock your vault" : "Create your vault"
    }

    private var subtitle: String {
        if stale {
            return "It was made before password unlock and cannot be opened by this version."
        }
        return exists
            ? "One vault for the account, on every device you sign in to."
            : "One password protects every saved server and key, on all your devices."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.title3.weight(.semibold))
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                InspectorCloseButton(action: { dismiss() }, help: "Close", label: "Close vault setup")
            }
            Divider()
            if stale {
                staleBody
            } else if exists {
                unlockBody
            } else {
                createBody
            }
            if let error {
                Text(FriendlyError.from(error).message).font(.caption).foregroundStyle(Theme.danger)
            }
            Spacer(minLength: 0)
            footer
        }
        .padding(Theme.Space.l)
        .sshSheetFrame(width: 560, height: 460)
        .confirmationDialog("Delete this vault?", isPresented: $confirmingReset, titleVisibility: .visible) {
            Button("Delete vault", role: .destructive) { Task { await resetVault() } }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Every encrypted SSH secret in the vault is permanently lost. Other devices will need to set up a new vault. This cannot be undone.") }
    }

    // MARK: - The three states

    private var createBody: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            SecureField("Vault password", text: $password)
                .textFieldStyle(.roundedBorder)
            SecureField("Type it again", text: $confirmPassword)
                .textFieldStyle(.roundedBorder)
            VaultPasswordRules(password: password)
            if !confirmPassword.isEmpty, !matches {
                Text("The two do not match.").font(.caption).foregroundStyle(Theme.danger)
            }
            Text("tokenstat never sees this password. It is what decrypts the vault, so nobody here can reset it or read what it protects.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var unlockBody: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            if forgot {
                Text("Enter your recovery code. It is the line you were given when the vault was created.")
                    .font(.callout).foregroundStyle(.secondary)
                TextField("Recovery code", text: $enteredRecovery)
                    .textFieldStyle(.roundedBorder)
                    .font(Theme.mono(12))
                Button("Use the password instead", .back) { forgot = false }
                    .buttonStyle(SecondaryButtonStyle(small: true))
            } else {
                SecureField("Vault password", text: $password)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { if canConfirm { Task { await run() } } }
                Button("I forgot the password", .help) { forgot = true }
                    .buttonStyle(SecondaryButtonStyle(small: true))
            }
            Text("Checked on this device. The password never leaves it.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var staleBody: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Text("Earlier vaults were opened with 24 recovery words. This one is opened with a password you choose, so the old vault cannot be carried across.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("Deleting it loses whatever it holds. Anything saved on this Mac stays where it is.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var footer: some View {
        HStack {
            Button("Cancel", .dismiss) { dismiss() }
                .buttonStyle(SecondaryButtonStyle())
                .frame(minWidth: Theme.Control.pairedWidth)
            if exists {
                Button("Delete vault", .delete) { confirmingReset = true }
                    .buttonStyle(DestructiveButtonStyle())
                    .disabled(working)
            }
            Spacer()
            // Written out rather than one button with two ternaries. The two
            // do different things and read differently, and a glyph chosen by
            // an expression is a glyph nobody can grep for.
            if exists {
                Button("Unlock", .signIn) { Task { await run() } }
                    .buttonStyle(AccentButtonStyle())
                    .frame(minWidth: Theme.Control.pairedWidth)
                    .disabled(!canConfirm)
            } else if !stale {
                Button("Create vault", .create) { Task { await run() } }
                    .buttonStyle(AccentButtonStyle())
                    .frame(minWidth: Theme.Control.pairedWidth)
                    .disabled(!canConfirm)
            }
        }
    }

    // MARK: - Doing it

    private func run() async {
        working = true
        error = nil
        do {
            if exists {
                if forgot {
                    // A recovery unlock is a password reset: the code proves
                    // who you are, and leaving without setting a password would
                    // mean the next device still cannot get in.
                    _ = try await Bridge.unlockSSHVault(recovery: enteredRecovery, tier: tier)
                } else {
                    _ = try await Bridge.unlockSSHVault(password: password, tier: tier)
                }
            } else {
                recovery = try await Bridge.createSSHVault(password: password, tier: tier).recovery
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
            password = ""
            confirmPassword = ""
            status = try await Bridge.sshVaultStatus()
        } catch { self.error = error.localizedDescription }
        working = false
    }
}

/// The password rule, said the same way everywhere it is shown.
///
/// The authority is `tokenstat_core::passphrase`, which the host enforces
/// before it wraps a key. This is the same list written for a person to read
/// while they type, so nobody meets a rule for the first time in a rejection.
enum VaultPassword {
    static let minLength = 12

    static func problems(_ password: String) -> [String] {
        var out: [String] = []
        if password.count < minLength { out.append("At least \(minLength) characters") }
        if !password.contains(where: { $0.isUppercase }) { out.append("An uppercase letter") }
        if !password.contains(where: { $0.isNumber }) { out.append("A number") }
        if !password.contains(where: { !$0.isLetter && !$0.isNumber && !$0.isWhitespace }) {
            out.append("A special character")
        }
        return out
    }

    static let all = [
        "At least \(minLength) characters",
        "An uppercase letter",
        "A number",
        "A special character",
    ]
}

/// Every rule, with the ones already met ticked off as you type.
///
/// All four are on screen from the start. A rule revealed one rejection at a
/// time is three rejections for one password.
struct VaultPasswordRules: View {
    let password: String

    var body: some View {
        let outstanding = Set(VaultPassword.problems(password))
        return VStack(alignment: .leading, spacing: 2) {
            ForEach(VaultPassword.all, id: \.self) { rule in
                let met = !outstanding.contains(rule)
                HStack(spacing: Theme.Space.xs) {
                    Image(systemName: met ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 10))
                        .foregroundStyle(met ? Theme.success : Color.secondary)
                    Text(rule)
                        .font(.caption)
                        .foregroundStyle(met ? Color.secondary : Color.primary)
                }
            }
        }
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
