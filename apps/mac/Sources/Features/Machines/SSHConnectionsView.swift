// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

import Foundation
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
            VStack(spacing: 0) {
                SSHEditorBody(working: importing) {
                    if let error {
                        InlineBanner(text: error, kind: .danger) { self.error = nil }
                    }
                    SSHEditorSection(title: "Provider") {
                        SSHEditorField(label: "Import from") {
                            Picker("Provider", selection: $provider) {
                                ForEach(Provider.allCases, id: \.self) {
                                    Text($0.rawValue).tag($0)
                                }
                            }
                        }
                        if provider == .digitalOcean {
                            SSHEditorField(label: "Read-only API token") {
                                SecureField("Read-only API token", text: $token)
                                    .themedFieldBox()
                            }
                        } else {
                            SSHEditorField(label: "AWS CLI profile") {
                                TextField("AWS CLI profile", text: $profile)
                                    .textFieldStyle(.themed)
                            }
                            SSHEditorField(label: "Region") {
                                TextField("Region (optional)", text: $region)
                                    .textFieldStyle(.themed)
                            }
                        }
                        SSHEditorField(label: "SSH username") {
                            TextField("SSH username", text: $username)
                                .textFieldStyle(.themed)
                        }
                        SSHEditorNote(
                            text: provider == .digitalOcean
                                ? "Only the Droplets list is read. The token is used once and is not saved."
                                : "Uses your existing AWS CLI profile and only calls describe-instances. AWS keys never enter tokenstat."
                        )
                    }
                    if let importedCount {
                        SSHEditorSection(title: "Imported") {
                            Label(
                                importedCount == 1 ? "Imported 1 server" : "Imported \(importedCount) servers",
                                systemImage: "checkmark.circle.fill"
                            )
                            .foregroundStyle(Theme.success)
                        }
                    } else if importing {
                        HStack(spacing: Theme.Space.s) {
                            ProgressView().controlSize(.small)
                            Text("Reading server list…")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                SSHEditorFooter(
                    saveTitle: importedCount == nil ? "Import" : "Done",
                    saveIcon: importedCount == nil ? .download : .done,
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
            .navigationTitle("Import cloud servers")
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

/// The recovery code, then the same line typed back.
///
/// Two steps, because one surface is not a confirmation. The code is on
/// screen to be written down, then off screen while it is typed, so confirming
/// cannot be done by reading. Going back is allowed and re-showing the code is
/// a deliberate action, so nobody is trapped.
///
/// This used to be 24 words and a three-word quiz. The host now issues one
/// Crockford line, and the quiz has to ask for that line or Done never enables.
struct SSHRecoveryWordsSheet: View {
    @Environment(\.dismiss) private var dismiss
    let recovery: String
    let onConfirmed: () -> Void
    let onDiscard: () -> Void

    private enum Step { case read, confirm }

    @State private var step = Step.read
    @State private var confirmingDiscard = false
    @State private var typed = ""
    @State private var copied = false

    private var typedAnything: Bool { !typed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// The same normalisation the host uses: case, dashes, and O/0 I,L/1.
    private var codesMatch: Bool {
        let expected = Self.normalized(recovery)
        return !expected.isEmpty && expected == Self.normalized(typed)
    }

    static func normalized(_ value: String) -> String {
        var out = ""
        for ch in value.uppercased() {
            guard ch.isASCII, ch.isLetter || ch.isNumber else { continue }
            switch ch {
            case "O": out.append("0")
            case "I", "L": out.append("1")
            default: out.append(ch)
            }
        }
        return out
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
        .sshSheetFrame(width: 560, height: 460)
        .confirmationDialog("Delete this vault?", isPresented: $confirmingDiscard, titleVisibility: .visible) {
            Button("Delete vault", role: .destructive) { onDiscard(); dismiss() }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Every encrypted SSH secret in the vault is permanently lost. This cannot be undone.") }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(step == .read ? "Save your recovery code" : "Type the recovery code")
                    .font(.title3.weight(.semibold))
                Text(step == .read
                    ? "This is the only way back if the password is forgotten and every device is lost."
                    : "The code is off screen on purpose. Type it from where you saved it.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            InspectorCloseButton(action: { dismiss() }, help: "Close", label: "Close recovery code")
        }
    }

    /// The code's ten groups, which is how it is written and how it is read
    /// back off paper.
    private var groups: [String] {
        recovery.split(separator: "-").map(String.init)
    }

    private var readStep: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            // Grouped rather than one long line. Fifty characters of monospace
            // does not fit across a phone, and the version that wrapped
            // wherever it ran out of room broke groups across lines, which is
            // the one thing a code being copied onto paper must not do.
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 66), spacing: 8, alignment: .leading)],
                alignment: .leading,
                spacing: 8
            ) {
                ForEach(Array(groups.enumerated()), id: \.offset) { _, group in
                    Text(group)
                        .font(Theme.mono(16, weight: .medium))
                        .textSelection(.enabled)
                        .padding(.vertical, 6)
                        .frame(maxWidth: .infinity)
                        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 6))
                }
            }
            .padding(Theme.Space.s)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.panel.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Recovery code \(groups.joined(separator: ", "))")
            Text("Store this offline in a password manager or on paper. Do not rely on this screen or a screenshot.")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                Button(copied ? "Copied" : "Copy", .copy) { copyCode() }
                    .buttonStyle(SecondaryButtonStyle(small: true))
                Text("The clipboard may be visible to other apps; clear it after saving.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var confirmStep: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            Text("Enter the recovery code exactly as it was written.")
                .font(.callout)
            TextField("Recovery code", text: $typed)
                .textFieldStyle(.themedMono(14))
                #if !os(macOS)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                #endif
            if typedAnything {
                Text(codesMatch ? "Recovery code matches." : "That is not what was generated.")
                    .font(.caption).foregroundStyle(codesMatch ? Theme.success : Theme.danger)
            }
            Button("Show the code again", .reveal) {
                step = .read
                typed = ""
            }
            .buttonStyle(SecondaryButtonStyle(small: true))
            Text("Going back is fine. It clears what was typed, so the code still has to be read from where you saved it.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            HStack {
                Button("Discard this vault", .delete) { confirmingDiscard = true }
                    .buttonStyle(DestructiveButtonStyle())
                Spacer()
                if step == .read {
                    Button("I have saved this", .next) { step = .confirm }
                        .buttonStyle(AccentButtonStyle())
                        .frame(minWidth: Theme.Control.pairedWidth)
                } else {
                    Button("Done", .done) { onConfirmed(); dismiss() }
                        .buttonStyle(AccentButtonStyle())
                        .frame(minWidth: Theme.Control.pairedWidth)
                        .disabled(!codesMatch)
                }
            }
            Text("Close without confirming to look at the code later. Discard deletes the vault so you can create a new one.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func copyCode() {
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
    /// Bumped when the button was pressed with something still missing. The
    /// fields watch it and shake.
    @State private var refusals = 0
    @FocusState private var focus: Field?

    private enum Field: Hashable { case password, confirmPassword, recovery }

    /// The vault exists, so this is an unlock rather than a creation.
    private var exists: Bool { status?.created == true }
    /// Made before password unlock existed and cannot be opened by this build.
    private var stale: Bool { status?.needsRecreate == true }

    private var problems: [String] { VaultPassword.problems(password) }
    private var matches: Bool { password == confirmPassword }

    /// What is stopping the button, as a sentence and a field to point at.
    ///
    /// The button stays pressable so this can be said at all. Disabling it
    /// made the screen silent at exactly the moment somebody was asking it a
    /// question.
    private var blocker: (message: String, field: Field)? {
        if stale { return nil }
        if exists && !forgot {
            if password.isEmpty { return ("Enter your vault password.", .password) }
            return nil
        }
        if exists, forgot, enteredRecovery.trimmingCharacters(in: .whitespaces).isEmpty {
            return ("Enter the recovery code you saved.", .recovery)
        }
        if password.isEmpty { return ("Choose a password for the vault.", .password) }
        if let problem = problems.first { return (problem, .password) }
        if confirmPassword.isEmpty { return ("Type the password again to confirm it.", .confirmPassword) }
        if !matches { return ("The two passwords do not match.", .confirmPassword) }
        return nil
    }

    /// Press it and find out. `blocker` is what comes back when it cannot run.
    private func attempt() {
        if let blocker {
            error = blocker.message
            focus = blocker.field
            refusals += 1
            return
        }
        Task { await run() }
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
        } message: { Text("The vault is removed from the account and every device is asked to set up a new one. Anything in it that this device never received is gone for good. Your saved servers, folders and snippets stay on this device.") }
    }

    // MARK: - The three states

    private var createBody: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            SecureField("Vault password", text: $password)
                .themedFieldBox()
                .focused($focus, equals: .password)
                .shake(on: refusals)
            SecureField("Type it again", text: $confirmPassword)
                .themedFieldBox()
                .focused($focus, equals: .confirmPassword)
                .shake(on: refusals)
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
                Text("Enter your recovery code and choose a new password. The code is the line you were given when the vault was created.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                TextField("Recovery code", text: $enteredRecovery)
                    .textFieldStyle(.themedMono(12))
                    .focused($focus, equals: .recovery)
                    .shake(on: refusals)
                SecureField("New password", text: $password)
                    .themedFieldBox()
                    .focused($focus, equals: .password)
                    .shake(on: refusals)
                SecureField("Type it again", text: $confirmPassword)
                    .themedFieldBox()
                    .focused($focus, equals: .confirmPassword)
                    .shake(on: refusals)
                VaultPasswordRules(password: password)
                if !confirmPassword.isEmpty, !matches {
                    Text("The two do not match.").font(.caption).foregroundStyle(Theme.danger)
                }
                Text("The code is spent once this works, and you are given a fresh one.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Use the password instead", .back) { forgot = false }
                    .buttonStyle(SecondaryButtonStyle(small: true))
            } else {
                SecureField("Vault password", text: $password)
                    .themedFieldBox()
                    .focused($focus, equals: .password)
                    .shake(on: refusals)
                    .onSubmit { attempt() }
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
                // The way out when the password is gone and no other device
                // can open it. Deleting needs neither, so it is offered here
                // rather than only after a successful unlock.
                Button("Delete vault", .delete) { confirmingReset = true }
                    .buttonStyle(DestructiveButtonStyle())
                    .disabled(working)
            }
            Spacer()
            // Written out rather than one button with two ternaries. The two
            // do different things and read differently, and a glyph chosen by
            // an expression is a glyph nobody can grep for.
            if exists {
                Button("Unlock", .signIn) { attempt() }
                    .buttonStyle(AccentButtonStyle())
                    .frame(minWidth: Theme.Control.pairedWidth)
                    .disabled(working)
            } else if !stale {
                Button("Create vault", .create) { attempt() }
                    .buttonStyle(AccentButtonStyle())
                    .frame(minWidth: Theme.Control.pairedWidth)
                    .disabled(working)
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
                    // A recovery unlock is a password reset. The code proves
                    // who you are and buys one new password: unlocking on the
                    // code alone would leave every other device asking for the
                    // password nobody knows. The answer carries the fresh code
                    // that replaces the one just spent.
                    let result = try await Bridge.setSSHVaultPassword(
                        recovery: enteredRecovery,
                        newPassword: password
                    )
                    recovery = result.recovery
                } else {
                    _ = try await Bridge.unlockSSHVault(password: password, tier: tier)
                }
            } else {
                recovery = try await Bridge.createSSHVault(password: password, tier: tier).recovery
            }
            status = try await Bridge.sshVaultStatus()
            dismiss()
        } catch {
            self.error = error.localizedDescription
            // "A vault already exists" means this screen was showing the wrong
            // half of itself: something made one elsewhere while this was open.
            // Re-reading the status flips it to unlock, so the next thing
            // typed is the password rather than a second attempt at a create
            // that cannot succeed.
            if error.localizedDescription.lowercased().contains("vault already exists"),
               let fresh = try? await Bridge.sshVaultStatus() {
                status = fresh
                password = ""
                confirmPassword = ""
                self.error = "That account already has a vault. Enter its password to open it here."
            }
        }
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

    /// The same test the host runs, scalar for scalar.
    ///
    /// Measured over unicode scalars and with an ASCII-only digit test,
    /// because `tokenstat_core::passphrase` does both. Swift's `isNumber`
    /// matches Eastern Arabic digits and Rust's `is_ascii_digit` does not, so
    /// the friendlier-looking predicate is the one that enables the button
    /// over a password the host then refuses.
    static func problems(_ password: String) -> [String] {
        let scalars = password.unicodeScalars
        var out: [String] = []
        if scalars.count < minLength { out.append("At least \(minLength) characters") }
        if !scalars.contains(where: { Character($0).isUppercase }) {
            out.append("An uppercase letter")
        }
        if !scalars.contains(where: { $0.isASCII && Character($0).isNumber }) {
            out.append("A number")
        }
        if !scalars.contains(where: { !CharacterSet.alphanumerics.contains($0) && !CharacterSet.whitespacesAndNewlines.contains($0) }) {
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
    @State private var working = false
    /// The probe or connect in flight, so Cancel has something to stop.
    ///
    /// A TCP connect to a host that is not answering sits there until the
    /// socket times out, which is around a minute, and for that whole minute
    /// this sheet was a screen with nothing on it that did anything. Holding
    /// the task means leaving is leaving.
    @State private var inFlight: Task<Void, Never>?
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                SSHEditorBody(working: working) {
                    if let error {
                        InlineBanner(text: error, kind: .danger) { self.error = nil }
                    }
                    if host.hostKeys.isEmpty {
                        SSHEditorSection(title: "Server identity") {
                            SSHEditorNote(text: "Verify the server identity before sending credentials.")
                            if let offeredFingerprint {
                                SSHEditorField(label: "Fingerprint") {
                                    Text(offeredFingerprint)
                                        .font(Theme.mono(11))
                                        .textSelection(.enabled)
                                }
                            }
                        }
                    } else {
                        SSHEditorSection(title: "Authentication") {
                            SSHEditorField(label: "Use") {
                                Picker("Authentication", selection: $selectedKeyID) {
                                    Text("Password").tag("")
                                    ForEach(model.keys) { Text($0.label).tag($0.id) }
                                }
                            }
                            if selectedKeyID.isEmpty {
                                SSHEditorField(label: "Password") {
                                    SecureField("Password", text: $password)
                                        .themedFieldBox()
                                }
                            }
                            SSHEditorNote(text: "Passwords are used for this connection and are never saved.")
                        }
                    }
                }
                SSHEditorFooter(
                    saveTitle: connectActionTitle,
                    saveIcon: connectActionIcon,
                    canSave: canContinue,
                    working: working,
                    onSave: { start() },
                    onCancel: { cancelAndClose() },
                    onDelete: nil
                )
            }
            .navigationTitle(host.label)
        }
        .sshSheetFrame(width: 500, height: 360)
        .onAppear {
            if let credentialID = host.credentialID,
               model.keys.contains(where: { $0.id == credentialID })
            {
                selectedKeyID = credentialID
            } else {
                selectedKeyID = ""
            }
        }
    }

    private var connectActionTitle: String {
        if !host.hostKeys.isEmpty { return "Connect" }
        return offeredFingerprint == nil ? "Show fingerprint" : "Trust fingerprint"
    }

    private var connectActionIcon: ActionIcon {
        if !host.hostKeys.isEmpty { return .connect }
        return offeredFingerprint == nil ? .security : .approve
    }

    private var canContinue: Bool {
        if host.hostKeys.isEmpty { return true }
        if selectedKeyID.isEmpty { return !password.isEmpty }
        return model.keys.contains { $0.id == selectedKeyID }
    }

    /// Begin, keeping hold of the work so it can be abandoned.
    private func start() {
        inFlight?.cancel()
        inFlight = Task { await continueConnection() }
    }

    /// Leave, whether or not something is still running.
    ///
    /// The underlying call may well keep going until the host answers or the
    /// socket gives up: the cancel that matters to a person is the one that
    /// gets them off this screen, and nothing here is waiting on the result
    /// any more once the sheet is gone.
    private func cancelAndClose() {
        inFlight?.cancel()
        inFlight = nil
        working = false
        dismiss()
    }

    private func continueConnection() async {
        working = true
        defer { working = false }
        if host.hostKeys.isEmpty {
            if let offeredFingerprint {
                await trust(offeredFingerprint)
            } else {
                await probe()
            }
        } else {
            await connect()
        }
    }
    private func probe() async {
        do {
            var jump: [String: Any]?
            if let jumpID = host.jumpHostID,
               let jumpHost = model.hosts.first(where: { $0.id == jumpID })
            {
                jump = try Bridge.sshJumpPayload(jumpHost, key: model.key(jumpHost.credentialID))
            }
            let probed = try await Bridge.probeSSHHost(host, jump: jump).fingerprint
            // The call carries on after a cancel, so its answer can arrive
            // for a sheet somebody has already left. Say nothing then.
            guard !Task.isCancelled else { return }
            offeredFingerprint = probed
        }
        catch {
            guard !Task.isCancelled else { return }
            self.error = error.localizedDescription
        }
    }
    private func trust(_ fingerprint: String) async {
        // Same reason as the connect path: a save that lands after Cancel
        // would write a trusted fingerprint the person backed out of, and
        // report its failure onto a view that is gone.
        guard !Task.isCancelled else { return }
        host.hostKeys = [fingerprint]
        let saved = await model.save(host: host) != nil
        guard !Task.isCancelled else { return }
        if saved {
            offeredFingerprint = nil
        } else {
            // The editor follows `host.hostKeys`. Leave it in verification
            // mode when persistence failed, or the trust action disappears
            // and Connect can proceed with a fingerprint that was never kept.
            host.hostKeys = []
            error = model.error ?? "The trusted fingerprint could not be saved."
        }
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
            // Cancelling does not reach the call that is already in flight, so
            // a connection can land for a sheet somebody has left. Handing
            // that session to the model would adopt a shell and push the
            // terminal screen in front of a person who pressed Cancel to
            // avoid exactly that. The shell is real and stays running: the
            // bookkeeping poll finds it, and the session list is where it
            // belongs rather than in front of them.
            guard !Task.isCancelled else { return }
            connected(SSHLiveTerminal(handle: handle, title: host.label, hostID: host.id))
            await model.noteConnection(host)
            dismiss()
        } catch {
            guard !Task.isCancelled else { return }
            self.error = error.localizedDescription
        }
    }
}

extension View {
    /// A sheet in the SSH path: a fixed size on the Mac, the whole screen on
    /// a phone, on the app's own background either way.
    ///
    /// The background is part of the frame rather than left to each sheet,
    /// because leaving it to each sheet is what happened: none of them set
    /// one, so every SSH sheet resolved to the system's window grey and was
    /// the only surface in the app that did not look like the app. A sheet is
    /// a small window, and `presentationBackground` is what paints the window
    /// rather than the view inside it, so both are set: the fill for the
    /// content, the presentation for the corners around it.
    @ViewBuilder
    func sshSheetFrame(width: CGFloat, height: CGFloat) -> some View {
        #if os(macOS)
        frame(width: width, height: height)
            .background(Theme.background)
            .presentationBackground(Theme.background)
        #else
        frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.background)
            .presentationBackground(Theme.background)
        #endif
    }
}
