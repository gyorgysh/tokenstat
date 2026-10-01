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
    /// AWS import shells out to the AWS CLI, which only exists on the Mac.
    /// On the phone there is no CLI and no key to paste, so DigitalOcean
    /// stands alone there instead of offering a door that cannot open.
    #if os(macOS)
    private var providers: [Provider] { Provider.allCases }
    #else
    private var providers: [Provider] { [.digitalOcean] }
    #endif
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
                    SSHEditorSection(title: L10n.text("apple.sshconnectionsview.provider.472590ae")) {
                        SSHEditorField(label: L10n.text("apple.sshconnectionsview.import_from.f9e4378d")) {
                            Picker(L10n.text("apple.sshconnectionsview.provider.472590ae"), selection: $provider) {
                                ForEach(providers, id: \.self) {
                                    Text($0.rawValue).tag($0)
                                }
                            }
                        }
                        if provider == .digitalOcean {
                            SSHEditorField(label: L10n.text("apple.sshconnectionsview.read_only_api_token.8a4f07c1")) {
                                SecureField(L10n.text("apple.sshconnectionsview.read_only_api_token.8a4f07c1"), text: $token)
                                    .themedFieldBox()
                            }
                            if let tokens = URL(string: "https://cloud.digitalocean.com/account/api/tokens") {
                                Link(L10n.text("apple.sshconnectionsview.where_to_find_the_token.625cfc6d"), destination: tokens)
                                    .font(Theme.caption)
                            }
                        } else {
                            SSHEditorField(label: L10n.text("apple.sshconnectionsview.aws_cli_profile.d16d28fb")) {
                                TextField(L10n.text("apple.sshconnectionsview.aws_cli_profile.d16d28fb"), text: $profile)
                                    .textFieldStyle(.themed)
                            }
                            SSHEditorField(label: L10n.text("apple.sshconnectionsview.region.d3a008ef")) {
                                TextField(L10n.text("apple.sshconnectionsview.region_optional.c59b0326"), text: $region)
                                    .textFieldStyle(.themed)
                            }
                        }
                        SSHEditorField(label: L10n.text("apple.sshconnectionsview.ssh_username.04940ab1")) {
                            TextField(L10n.text("apple.sshconnectionsview.ssh_username.04940ab1"), text: $username)
                                .textFieldStyle(.themed)
                        }
                        SSHEditorNote(
                            text: provider == .digitalOcean
                                ? L10n.text("apple.sshconnectionsview.only_the_droplets_list_is_read_the_token_i.1d8d25ff")
                                : L10n.text("apple.sshconnectionsview.uses_your_existing_aws_cli_profile_and_onl.a7164176")
                        )
                    }
                    if let importedCount {
                        SSHEditorSection(title: L10n.text("apple.sshconnectionsview.imported.321f179c")) {
                            Label(
                                importedCount == 1 ? L10n.text("apple.sshconnectionsview.imported_1_server.4d9265c1") : L10n.text("apple.sshconnectionsview.imported_0_servers.16ce8b58", "\(importedCount)"),
                                systemImage: "checkmark.circle.fill"
                            )
                            .foregroundStyle(Theme.success)
                        }
                    } else if importing {
                        HStack(spacing: Theme.Space.s) {
                            ProgressView().controlSize(.small)
                            Text(L10n.text("apple.sshconnectionsview.reading_server_list.1f5b0d80"))
                                .font(Theme.callout)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                SSHEditorFooter(
                    saveTitle: importedCount == nil ? L10n.text("apple.sshconnectionsview.import.2cff9baa") : L10n.text("common.done"),
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
            .navigationTitle(L10n.text("apple.sshconnectionsview.import_cloud_servers.34d6891a"))
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
        ThemedSheet(
            title: step == .read ? L10n.text("apple.sshconnectionsview.save_your_recovery_code.1060e6a8") : L10n.text("apple.sshconnectionsview.type_the_recovery_code.4bf47928"),
            subtitle: step == .read
                ? L10n.text("apple.sshconnectionsview.this_is_the_only_way_back_if_the_password.a17a92ac")
                : L10n.text("apple.sshconnectionsview.the_code_is_off_screen_on_purpose_type_it.348fd90a"),
            icon: .security,
            onClose: { dismiss() }
        ) {
            VStack(alignment: .leading, spacing: Theme.Space.l) {
                switch step {
                case .read: readStep
                case .confirm: confirmStep
                }
                Text(L10n.text("apple.sshconnectionsview.close_without_confirming_to_look_at_the_co.2bb960f3"))
                    .font(Theme.caption)
                    .foregroundStyle(Theme.controlGlyph)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } actions: {
            Button(L10n.text("apple.sshconnectionsview.discard_this_vault.0b59b7f2"), .delete) { confirmingDiscard = true }
                .buttonStyle(DestructiveButtonStyle())
            Spacer()
            if step == .read {
                Button(L10n.text("apple.sshconnectionsview.i_have_saved_this.81674b57"), .next) { step = .confirm }
                    .buttonStyle(AccentButtonStyle())
            } else {
                Button(L10n.text("common.done"), .done) { onConfirmed(); dismiss() }
                    .buttonStyle(AccentButtonStyle())
                    .disabled(!codesMatch)
            }
        }
        .modalFrame(width: 580, height: 520)
        .confirmationDialog(L10n.text("apple.sshconnectionsview.delete_this_vault.f09b8aad"), isPresented: $confirmingDiscard, titleVisibility: .visible) {
            Button(L10n.text("apple.sshconnectionsview.delete_vault.9fd7de76"), role: .destructive) { onDiscard(); dismiss() }
            Button(L10n.text("common.cancel"), role: .cancel) {}
        } message: { Text(L10n.text("apple.sshconnectionsview.every_encrypted_ssh_secret_in_the_vault_is.d87ca6a9")) }
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
            .accessibilityLabel(L10n.text("apple.sshconnectionsview.recovery_code_0.50509e6e", "\(groups.joined(separator: ", "))"))
            Text(L10n.text("apple.sshconnectionsview.store_this_offline_in_a_password_manager_o.d8bc24cf"))
                .font(Theme.callout).foregroundStyle(.secondary)
            HStack {
                Button(copied ? L10n.text("apple.sshconnectionsview.copied.8d525e5f") : L10n.text("common.copy"), .copy) { copyCode() }
                    .buttonStyle(SecondaryButtonStyle(small: true))
                Text(L10n.text("apple.sshconnectionsview.the_clipboard_may_be_visible_to_other_apps.271cf95f"))
                    .font(Theme.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var confirmStep: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            Text(L10n.text("apple.sshconnectionsview.enter_the_recovery_code_exactly_as_it_was.c76633d2"))
                .font(Theme.callout)
            TextField(L10n.text("apple.sshconnectionsview.recovery_code.5bda8302"), text: $typed)
                .textFieldStyle(.themedMono(14))
                #if !os(macOS)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                #endif
            if typedAnything {
                Text(codesMatch ? L10n.text("apple.sshconnectionsview.recovery_code_matches.b974b57c") : L10n.text("apple.sshconnectionsview.that_is_not_what_was_generated.cd8d7d81"))
                    .font(Theme.caption).foregroundStyle(codesMatch ? Theme.success : Theme.danger)
            }
            Button(L10n.text("apple.sshconnectionsview.show_the_code_again.2e6e5f4c"), .reveal) {
                step = .read
                typed = ""
            }
            .buttonStyle(SecondaryButtonStyle(small: true))
            Text(L10n.text("apple.sshconnectionsview.going_back_is_fine_it_clears_what_was_type.14ac8de0"))
                .font(Theme.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
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
    @State private var biometricAccount: String?
    // Both answered by the device, not the host, so the first frame is already
    // the right shape. Asking the host which account is signed in takes a round
    // trip, and the sheet used to spend it showing the password form and then
    // swapping to Face ID under somebody who had started typing.
    @State private var biometricName: String? = SSHVaultBiometrics.name
    @State private var biometricSaved = SSHVaultBiometrics.hasSavedPassword
    @State private var usePassword = false
    @State private var enableBiometrics = false
    @State private var passwordAccepted = false
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

    private var biometricUnlock: Bool {
        exists && !stale && !forgot && !usePassword && biometricSaved && biometricName != nil
    }

    private var sheetHeight: CGFloat {
        if passwordAccepted { return 320 }
        if stale || forgot || !exists { return 580 }
        return biometricUnlock ? 380 : 460
    }

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
            if password.isEmpty { return (L10n.text("apple.sshconnectionsview.enter_your_vault_password.dfbd4b8d"), .password) }
            return nil
        }
        if exists, forgot, enteredRecovery.trimmingCharacters(in: .whitespaces).isEmpty {
            return (L10n.text("apple.sshconnectionsview.enter_the_recovery_code_you_saved.c0574998"), .recovery)
        }
        if password.isEmpty { return (L10n.text("apple.sshconnectionsview.choose_a_password_for_the_vault.5033a4fd"), .password) }
        if let problem = problems.first { return (problem, .password) }
        if confirmPassword.isEmpty { return (L10n.text("apple.sshconnectionsview.type_the_password_again_to_confirm_it.bea821f3"), .confirmPassword) }
        if !matches { return (L10n.text("apple.sshconnectionsview.the_two_passwords_do_not_match.e140908a"), .confirmPassword) }
        return nil
    }

    /// Press it and find out. `blocker` is what comes back when it cannot run.
    private func attempt() {
        guard !working && !passwordAccepted else { return }
        if let blocker {
            error = blocker.message
            focus = blocker.field
            refusals += 1
            return
        }
        Task { await run() }
    }

    private var title: String {
        if passwordAccepted { return L10n.text("apple.sshconnectionsview.vault_unlocked.47d615a3") }
        if stale { return L10n.text("apple.sshconnectionsview.this_vault_has_to_be_recreated.e5a4662d") }
        return exists ? L10n.text("apple.sshconnectionsview.unlock_your_vault.67a7b04b") : L10n.text("apple.sshconnectionsview.create_your_vault.de203ed0")
    }

    private var subtitle: String {
        if stale {
            return L10n.text("apple.sshconnectionsview.it_was_made_before_password_unlock_and_can.7595435d")
        }
        return exists
            ? L10n.text("apple.sshconnectionsview.your_saved_servers_and_keys_securely_on_th.4d9ca3a8")
            : L10n.text("apple.sshconnectionsview.one_password_protects_every_saved_server_a.8bb557dc")
    }

    var body: some View {
        ThemedSheet(
            title: title,
            subtitle: subtitle,
            icon: .security,
            onClose: { dismiss() }
        ) {
            VStack(alignment: .leading, spacing: Theme.Space.l) {
                if passwordAccepted {
                    Text(L10n.text("apple.sshconnectionsview.your_vault_is_unlocked.d11c3267"))
                } else if stale {
                    staleBody
                } else if exists {
                    unlockBody
                } else {
                    createBody
                }
                if !stale && !passwordAccepted && !biometricUnlock, let biometricName, biometricAccount != nil {
                    biometricPreference(name: biometricName)
                }
                if let error {
                    Text(FriendlyError.from(error).message)
                        .font(Theme.caption)
                        .foregroundStyle(Theme.danger)
                }
            }
        } actions: {
            footer
        }
        .modalFrame(width: 520, height: sheetHeight)
        .task {
            biometricName = SSHVaultBiometrics.name
            biometricAccount = try? await SSHVaultBiometrics.accountKey()
            // Now the exact one. The opening guess was "this device has a saved
            // password"; this is "for the account signed in right now".
            biometricSaved = biometricAccount.map(SSHVaultBiometrics.contains) ?? false
            enableBiometrics = biometricSaved
        }
        .confirmationDialog(L10n.text("apple.sshconnectionsview.delete_this_vault.f09b8aad"), isPresented: $confirmingReset, titleVisibility: .visible) {
            Button(L10n.text("apple.sshconnectionsview.delete_vault.9fd7de76"), role: .destructive) { Task { await resetVault() } }
            Button(L10n.text("common.cancel"), role: .cancel) {}
        } message: { Text(L10n.text("apple.sshconnectionsview.the_vault_is_removed_from_the_account_and.0c2c6b7a")) }
    }

    // MARK: - The three states

    private var createBody: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            SecureField(L10n.text("apple.sshconnectionsview.vault_password.1853752f"), text: $password)
                .themedFieldBox()
                .focused($focus, equals: .password)
                .shake(on: refusals)
            SecureField(L10n.text("apple.sshconnectionsview.type_it_again.3b2acc21"), text: $confirmPassword)
                .themedFieldBox()
                .focused($focus, equals: .confirmPassword)
                .shake(on: refusals)
            VaultPasswordRules(password: password)
            if !confirmPassword.isEmpty, !matches {
                Text(L10n.text("apple.sshconnectionsview.the_two_do_not_match.184006b7")).font(Theme.caption).foregroundStyle(Theme.danger)
            }
            Text(L10n.text("apple.sshconnectionsview.tokenstat_never_sees_this_password_it_is_w.ba584970"))
                .font(Theme.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var unlockBody: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            if biometricUnlock, let biometricName {
                VStack(spacing: Theme.Space.m) {
                    Image(systemName: biometricName == "Face ID" ? "faceid" : "touchid")
                        .font(Theme.largeTitle)
                        .foregroundStyle(Theme.accent)
                        .frame(width: 64, height: 64)
                        .background(Theme.accent.opacity(0.10), in: RoundedRectangle(cornerRadius: Theme.cardRadius))
                        .accessibilityHidden(true)
                    Text(L10n.text("apple.sshconnectionsview.unlock_with_0.20a41ad2", "\(biometricName)"))
                        .font(Theme.headline)
                    Text(L10n.text("apple.sshconnectionsview.confirm_it_s_you_to_open_your_vault.f5a7fe62"))
                        .font(Theme.callout)
                        .foregroundStyle(.secondary)
                    Button(L10n.text("apple.sshconnectionsview.use_password_instead.e354ddfe"), .signIn) {
                        usePassword = true
                        error = nil
                        focus = .password
                    }
                    .buttonStyle(SecondaryButtonStyle())
                    .disabled(working)
                }
                .frame(maxWidth: .infinity)
            } else if forgot {
                Text(L10n.text("apple.sshconnectionsview.enter_your_recovery_code_and_choose_a_new.00f1a937"))
                    .font(Theme.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                TextField(L10n.text("apple.sshconnectionsview.recovery_code.5bda8302"), text: $enteredRecovery)
                    .textFieldStyle(.themedMono(12))
                    .focused($focus, equals: .recovery)
                    .shake(on: refusals)
                SecureField(L10n.text("apple.sshconnectionsview.new_password.3dd9df44"), text: $password)
                    .themedFieldBox()
                    .focused($focus, equals: .password)
                    .shake(on: refusals)
                SecureField(L10n.text("apple.sshconnectionsview.type_it_again.3b2acc21"), text: $confirmPassword)
                    .themedFieldBox()
                    .focused($focus, equals: .confirmPassword)
                    .shake(on: refusals)
                VaultPasswordRules(password: password)
                if !confirmPassword.isEmpty, !matches {
                    Text(L10n.text("apple.sshconnectionsview.the_two_do_not_match.184006b7")).font(Theme.caption).foregroundStyle(Theme.danger)
                }
                Text(L10n.text("apple.sshconnectionsview.the_code_is_spent_once_this_works_and_you.97746e7d"))
                    .font(Theme.caption).foregroundStyle(.secondary)
                Button(L10n.text("apple.sshconnectionsview.use_the_password_instead.8dd1f753"), .back) { forgot = false }
                    .buttonStyle(SecondaryButtonStyle(small: true))
            } else {
                Text(L10n.text("apple.sshconnectionsview.vault_password.1853752f"))
                    .font(Theme.headline)
                SecureField(L10n.text("apple.sshconnectionsview.vault_password.1853752f"), text: $password)
                    .themedFieldBox()
                    .focused($focus, equals: .password)
                    .shake(on: refusals)
                    .onSubmit { attempt() }
                HStack {
                    Button(L10n.text("apple.sshconnectionsview.forgot_password.30c1d8d3"), .help) { forgot = true; error = nil }
                        .buttonStyle(SecondaryButtonStyle(small: true))
                    Spacer(minLength: 0)
                    if biometricSaved, let biometricName {
                        Button(L10n.text("apple.sshconnectionsview.use_0.8ed7565b", "\(biometricName)"), .security) {
                            usePassword = false
                            password = ""
                            error = nil
                            focus = nil
                        }
                        .buttonStyle(SecondaryButtonStyle(small: true))
                    }
                }
                .disabled(working)
            }
            if !biometricUnlock {
                Text(L10n.text("apple.sshconnectionsview.your_password_stays_on_this_device.2993dce7"))
                    .font(Theme.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func biometricPreference(name: String) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Toggle(L10n.text("apple.sshconnectionsview.use_0_next_time.e5e01f34", "\(name)"), isOn: $enableBiometrics)
                .toggleStyle(.brandCheckbox)
                .font(Theme.callout)
            Text(L10n.text("apple.sshconnectionsview.only_on_this_device_you_can_always_use_you.79952bd2"))
                .font(Theme.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(Theme.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: Theme.cardRadius))
        .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius).strokeBorder(Theme.border))
        .disabled(working)
    }

    private var staleBody: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Text(L10n.text("apple.sshconnectionsview.earlier_vaults_were_opened_with_24_recover.b0bef388"))
                .font(Theme.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(L10n.text("apple.sshconnectionsview.deleting_it_loses_whatever_it_holds_anythi.e7eb49b2"))
                .font(Theme.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var footer: some View {
        Button(L10n.text("common.cancel"), .dismiss) { dismiss() }
            .buttonStyle(SecondaryButtonStyle())
            .keyboardShortcut(.cancelAction)
        if exists && !passwordAccepted && (forgot || stale) {
            // The way out when the password is gone and no other device
            // can open it. Deleting needs neither, so it is offered here
            // rather than only after a successful unlock.
            Button(L10n.text("apple.sshconnectionsview.delete_vault.9fd7de76"), .delete) { confirmingReset = true }
                .buttonStyle(DestructiveButtonStyle())
                .disabled(working)
        }
        Spacer()
        // Written out rather than one button with two ternaries. The two
        // do different things and read differently, and a glyph chosen by
        // an expression is a glyph nobody can grep for.
        if passwordAccepted {
            Button(L10n.text("common.done"), .done) { dismiss() }
                .buttonStyle(AccentButtonStyle())
        } else if biometricUnlock, let biometricName {
            Button(working ? L10n.text("apple.sshconnectionsview.unlocking.a4114da0") : L10n.text("apple.sshconnectionsview.unlock_with_0.20a41ad2", "\(biometricName)"), .security) {
                Task { await unlockWithBiometrics() }
            }
            .buttonStyle(AccentButtonStyle())
            // The panel can be up before the account key lands. Without this a
            // fast tap hits the guard in `unlockWithBiometrics` and nothing
            // happens, which reads as a broken button.
            .disabled(working || biometricAccount == nil)
            .keyboardShortcut(.defaultAction)
        } else if exists && !stale {
            Button(working ? L10n.text("apple.sshconnectionsview.unlocking.a4114da0") : L10n.text("apple.sshconnectionsview.unlock_with_password.f4ab8ea2"), .signIn) { attempt() }
                .buttonStyle(AccentButtonStyle())
                .disabled(working)
                .keyboardShortcut(.defaultAction)
        } else if !stale {
            Button(L10n.text("apple.sshconnectionsview.create_vault.c8c44253"), .create) { attempt() }
                .buttonStyle(AccentButtonStyle())
                .disabled(working)
                .keyboardShortcut(.defaultAction)
        }
    }

    // MARK: - Doing it

    private func run() async {
        let submittedPassword = password
        let enrollmentAccount = biometricAccount
        let shouldEnableBiometrics = enableBiometrics
        working = true
        error = nil
        defer {
            working = false
            if passwordAccepted {
                password = ""
                confirmPassword = ""
                enteredRecovery = ""
            }
        }
        do {
            if let biometricAccount = enrollmentAccount {
                guard try await SSHVaultBiometrics.accountKey() == biometricAccount else {
                    error = L10n.text("apple.sshconnectionsview.the_signed_in_account_changed_reopen_the_v.0d1b7357")
                    return
                }
            }
            if exists {
                if forgot {
                    // A recovery unlock is a password reset. The code proves
                    // who you are and buys one new password: unlocking on the
                    // code alone would leave every other device asking for the
                    // password nobody knows. The answer carries the fresh code
                    // that replaces the one just spent.
                    let result = try await Bridge.setSSHVaultPassword(
                        recovery: enteredRecovery,
                        newPassword: submittedPassword
                    )
                    recovery = result.recovery
                } else {
                    recovery = try await Bridge.unlockSSHVault(password: submittedPassword, tier: tier).recovery
                }
            } else {
                recovery = try await Bridge.createSSHVault(password: submittedPassword, tier: tier).recovery
            }
            passwordAccepted = true
            status = try await Bridge.sshVaultStatus()
            if let biometricAccount = enrollmentAccount, try await SSHVaultBiometrics.accountKey() == biometricAccount {
                if shouldEnableBiometrics {
                    try await SSHVaultBiometrics.save(password: submittedPassword, account: biometricAccount)
                } else {
                    try SSHVaultBiometrics.remove(account: biometricAccount)
                }
            }
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
                self.error = L10n.text("apple.sshconnectionsview.that_account_already_has_a_vault_enter_its.2a836a76")
            }
        }
    }

    private func unlockWithBiometrics() async {
        guard !working, let biometricAccount else { return }
        working = true
        error = nil
        defer { working = false }
        do {
            let saved = try await SSHVaultBiometrics.load(account: biometricAccount)
            guard try await SSHVaultBiometrics.accountKey() == biometricAccount else {
                error = L10n.text("apple.sshconnectionsview.the_signed_in_account_changed_reopen_the_v.0d1b7357")
                return
            }
            recovery = try await Bridge.unlockSSHVault(password: saved, tier: tier).recovery
            if !enableBiometrics { try SSHVaultBiometrics.remove(account: biometricAccount) }
            status = try await Bridge.sshVaultStatus()
            dismiss()
        } catch {
            if error.localizedDescription.lowercased().contains("wrong password") {
                try? SSHVaultBiometrics.remove(account: biometricAccount)
                biometricSaved = false
                enableBiometrics = false
            }
            self.error = L10n.text("apple.sshconnectionsview.0_you_can_always_unlock_with_your_vault_pa.ac01e224", "\(error.localizedDescription)")
        }
    }

    private func resetVault() async {
        working = true
        error = nil
        do {
            try await Bridge.resetSSHVault()
            recovery = nil
            biometricSaved = false
            enableBiometrics = false
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
        if scalars.count < minLength { out.append(L10n.text("apple.sshconnectionsview.at_least_0_characters.8fa59f2f", "\(minLength)")) }
        if !scalars.contains(where: { Character($0).isUppercase }) {
            out.append(L10n.text("apple.sshconnectionsview.an_uppercase_letter.a61f4d4b"))
        }
        if !scalars.contains(where: { $0.isASCII && Character($0).isNumber }) {
            out.append(L10n.text("apple.sshconnectionsview.a_number.a3c9dfa2"))
        }
        if !scalars.contains(where: { !CharacterSet.alphanumerics.contains($0) && !CharacterSet.whitespacesAndNewlines.contains($0) }) {
            out.append(L10n.text("apple.sshconnectionsview.a_special_character.9b79cde5"))
        }
        return out
    }

    static let all = [
        L10n.text("apple.sshconnectionsview.at_least_0_characters.8fa59f2f", "\(minLength)"),
        L10n.text("apple.sshconnectionsview.an_uppercase_letter.a61f4d4b"),
        L10n.text("apple.sshconnectionsview.a_number.a3c9dfa2"),
        L10n.text("apple.sshconnectionsview.a_special_character.9b79cde5"),
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
                        .font(Theme.font(10))
                        .foregroundStyle(met ? Theme.success : Color.secondary)
                    Text(rule)
                        .font(Theme.caption)
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
        ThemedSheet(
            title: host.label,
            subtitle: connectSubtitle,
            icon: .connect,
            onClose: { cancelAndClose() }
        ) {
            VStack(alignment: .leading, spacing: Theme.Space.l) {
                if let error {
                    InlineBanner(text: error, kind: .danger) { self.error = nil }
                }
                if host.hostKeys.isEmpty {
                    SSHEditorSection(title: L10n.text("apple.sshconnectionsview.server_identity.fa4fb0a3")) {
                        SSHEditorNote(text: L10n.text("apple.sshconnectionsview.verify_the_server_identity_before_sending.6988fa53"))
                        if let offeredFingerprint {
                            SSHEditorField(label: L10n.text("apple.sshconnectionsview.fingerprint.ba7af0b7")) {
                                Text(offeredFingerprint)
                                    .font(Theme.mono(11))
                                    .textSelection(.enabled)
                            }
                        }
                    }
                } else {
                    SSHEditorSection(title: L10n.text("apple.sshconnectionsview.authentication.66880d2d")) {
                        SSHEditorField(label: L10n.text("apple.sshconnectionsview.use.c36d819e")) {
                            Picker(L10n.text("apple.sshconnectionsview.authentication.66880d2d"), selection: $selectedKeyID) {
                                Text(L10n.text("apple.sshconnectionsview.password.e7cf3ef4")).tag("")
                                ForEach(model.keys) { Text($0.label).tag($0.id) }
                            }
                        }
                        if selectedKeyID.isEmpty {
                            SSHEditorField(label: L10n.text("apple.sshconnectionsview.password.e7cf3ef4")) {
                                SecureField(L10n.text("apple.sshconnectionsview.password.e7cf3ef4"), text: $password)
                                    .themedFieldBox()
                            }
                        }
                        SSHEditorNote(text: L10n.text("apple.sshconnectionsview.passwords_are_used_for_this_connection_and.47e746d5"))
                    }
                }
            }
            .disabled(working)
            .opacity(working ? 0.6 : 1)
            .animation(.easeOut(duration: 0.15), value: working)
        } actions: {
            Button(L10n.text("common.cancel"), .dismiss) { cancelAndClose() }
                .buttonStyle(SecondaryButtonStyle())
                .keyboardShortcut(.cancelAction)
            Spacer()
            Group {
                if working {
                    Button(action: {}) {
                        HStack(spacing: 6) {
                            ProgressView()
                                .controlSize(.small)
                                .tint(Theme.accent)
                            Text(connectBusyTitle)
                        }
                    }
                } else {
                    switch connectActionIcon {
                    case .connect: Button(connectActionTitle, .connect, action: start)
                    case .security: Button(connectActionTitle, .security, action: start)
                    case .approve: Button(connectActionTitle, .approve, action: start)
                    default: Button(connectActionTitle, .connect, action: start)
                    }
                }
            }
            .buttonStyle(AccentButtonStyle())
            .disabled(!canContinue || working)
            .keyboardShortcut(.defaultAction)
        }
        .modalFrame(width: 540, height: 500)
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

    private var connectSubtitle: String {
        if host.hostKeys.isEmpty {
            return L10n.text("apple.sshconnectionsview.confirm_the_server_fingerprint_before_send.0f8d28e8")
        }
        return L10n.text("apple.sshconnectionsview.passwords_are_used_for_this_connection_and.47e746d5")
    }

    private var connectActionTitle: String {
        if !host.hostKeys.isEmpty { return L10n.text("common.connect") }
        return offeredFingerprint == nil ? L10n.text("apple.sshconnectionsview.show_fingerprint.60097c5e") : L10n.text("apple.sshconnectionsview.trust_fingerprint.aaa68662")
    }

    private var connectBusyTitle: String {
        if !host.hostKeys.isEmpty { return L10n.text("apple.sshconnectionsview.connecting.72021eb7") }
        return offeredFingerprint == nil ? L10n.text("apple.sshconnectionsview.checking.ec963ffc") : L10n.text("apple.sshconnectionsview.trusting.b033578b")
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
                jump = try await Bridge.sshJumpPayload(jumpHost, key: model.key(jumpHost.credentialID))
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
            error = model.error ?? L10n.text("apple.sshconnectionsview.the_trusted_fingerprint_could_not_be_saved.aab9c4fe")
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
                jump = try await Bridge.sshJumpPayload(jumpHost, key: model.key(jumpHost.credentialID))
            }
            let handle: SSHSessionHandle
            let authPayload: [String: Any]
            if let key = model.keys.first(where: { $0.id == selectedKeyID }) {
                if key.secretRef.hasPrefix("agent:") {
                    let fingerprint = String(key.secretRef.dropFirst("agent:".count))
                    authPayload = ["kind": "agent", "fingerprint": fingerprint]
                    handle = try await Bridge.openSSHWithResolvedAuth(host, auth: authPayload, rows: 24, cols: 80, jump: jump)
                } else {
                    let pem = try await SSHSecretStore.loadForUse(reference: key.secretRef)
                    // Same encoding for open and probe: nil passphrase is
                    // NSNull, not missing, so the two calls cannot disagree.
                    authPayload = ["kind": "privateKey", "pem": pem, "passphrase": NSNull()]
                    handle = try await Bridge.openSSHWithResolvedAuth(host, auth: authPayload, rows: 24, cols: 80, jump: jump)
                }
            } else {
                authPayload = ["kind": "password", "password": password]
                handle = try await Bridge.openSSHWithResolvedAuth(host, auth: authPayload, rows: 24, cols: 80, jump: jump)
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
            // Clear secrets promptly; the probe below reuses the already
            // resolved values instead of holding cleartext longer.
            password = ""
            let probeAuth = authPayload
            let probeJump = jump
            let probeHost = host
            dismiss()
            // The library row shows what the server said about itself, and a
            // plain Connect never asked: the setup wizard probes, this sheet
            // did not. Refresh best effort with the same credential while it
            // is still in memory, so the next visit names the distro.
            // Scoped to this sheet's lifetime: no detached fire-and-forget
            // holding credentials after dismiss, failures surface via model.
            Task {
                try? await Bridge.probeServerForSetup(probeHost, auth: probeAuth, jump: probeJump)
            }
        } catch {
            guard !Task.isCancelled else { return }
            self.error = error.localizedDescription
        }
    }
}
