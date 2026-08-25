// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

import Observation
import SwiftUI

/// The vault's state, and the four calls that change it.
///
/// A model rather than state on a banner, because the row that reports the
/// vault and the screen that manages it are two views of one thing, and the
/// version where each held its own copy is the version where deleting from one
/// left the other saying "ready".
@MainActor
@Observable
final class SSHVaultModel {
    var status: SSHVaultStatus?
    /// Set only between generating a recovery code and confirming it. While
    /// it holds a code, it has not been written down yet, and that is the
    /// one vault state that is allowed to look urgent.
    var recovery: String?
    var error: String?

    var created: Bool { status?.created == true }
    var enrolled: Bool { status?.enrolled == true }
    /// The vault exists and this device has no key for it yet, so somebody has
    /// to type the password before anything can be read here.
    var locked: Bool { created && status?.locked == true }
    /// Made before password unlock existed. It cannot be opened at all.
    var needsRecreate: Bool { status?.needsRecreate == true }
    var recordCount: Int { status?.recordCount ?? 0 }
    /// Code generated and not yet confirmed. The only warning here.
    var unconfirmedRecovery: Bool { recovery != nil }
    /// The account could not be asked. Not the same as having no vault, and
    /// the screen must not offer to create one while this is set: the vault
    /// that may already exist is simply out of reach.
    var unreachable: String? { status?.unreachable }

    func refresh() async {
        status = try? await Bridge.sshVaultStatus()
    }

    /// Keep the state honest while somebody is looking at it.
    ///
    /// The vault lives on the account, so it changes on other devices. Reading
    /// it once when the screen appeared meant a vault made on a phone stayed
    /// invisible on a Mac that had the screen open, for as long as it stayed
    /// open. Slow on purpose: this is a network call, and nothing here is
    /// worth a tighter loop than the pace somebody sets up a vault at.
    func watch() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(20))
            if Task.isCancelled { return }
            await refresh()
        }
    }

    /// Say what this computer is, then ask again.
    ///
    /// The vault calls already republish the machine record when the account
    /// does not recognise it, so this is mostly the same work behind a button.
    /// It exists because being told your computer is not on your account and
    /// having nothing to press is the state this screen was in.
    func registerAndRefresh() async {
        do {
            try await Bridge.registerThisMachine()
        } catch {
            self.error = error.localizedDescription
        }
        await refresh()
    }

    func rotateRecovery() async {
        do {
            recovery = try await Bridge.rotateSSHVaultRecovery().recovery
            status = try await Bridge.sshVaultStatus()
        } catch { self.error = error.localizedDescription }
    }

    /// Forget the key held for this run, so the password is asked for again.
    func lock() async {
        do {
            try await Bridge.lockSSHVault()
            status = try await Bridge.sshVaultStatus()
        } catch { self.error = error.localizedDescription }
    }

    func reset() async {
        do {
            try await Bridge.resetSSHVault()
            recovery = nil
            status = try await Bridge.sshVaultStatus()
        } catch { self.error = error.localizedDescription }
    }

    /// Change the password, having proved the current one.
    func changePassword(current: String, to next: String) async -> Bool {
        do {
            let result = try await Bridge.setSSHVaultPassword(current: current, newPassword: next)
            // A change made with the current password keeps the recovery code,
            // so there is nothing new to show.
            if let fresh = result.recovery { recovery = fresh }
            status = try await Bridge.sshVaultStatus()
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }
}

/// The vault, as one quiet line above the host list.
///
/// It used to be three buttons in a row, two of them destructive, at the top of
/// a screen people open to add a server. A shield, a count and a chevron says
/// the same thing, and the actions live one click away where each of them has
/// room for the sentence it needs.
struct SSHVaultRow: View {
    @Bindable var vault: SSHVaultModel
    let canWrite: Bool
    var onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: Theme.Space.s) {
                Image(systemName: symbol)
                    .foregroundStyle(vault.unconfirmedRecovery ? Theme.warning : Theme.accent)
                Text(label)
                    .font(.callout)
                    .foregroundStyle(vault.unconfirmedRecovery ? Theme.warning : Color.primary)
                if vault.locked {
                    Text("Locked")
                        .font(.caption)
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(Theme.accentSoft, in: Capsule())
                        .foregroundStyle(Theme.accent)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, Theme.Space.m)
            .padding(.vertical, Theme.Space.s)
            .background(background, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.border))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    private var symbol: String {
        if vault.unconfirmedRecovery { return "exclamationmark.shield.fill" }
        return vault.created ? "lock.shield.fill" : "lock.shield"
    }

    private var label: String {
        if vault.unconfirmedRecovery { return "Recovery code not confirmed" }
        if vault.needsRecreate { return "Encrypted vault · has to be recreated" }
        if vault.locked { return "Encrypted vault · locked" }
        if vault.created {
            return vault.recordCount == 1
                ? "Encrypted vault · 1 record"
                : "Encrypted vault · \(vault.recordCount) records"
        }
        return canWrite ? "Encrypted vault · not set up" : "Encrypted vault · Supporter and above"
    }

    private var background: Color {
        vault.unconfirmedRecovery ? Theme.warning.opacity(0.10) : Theme.panel
    }
}

/// Everything the vault can be asked to do, with room to say what each one
/// costs.
///
/// A sheet because it is a set of decisions, and two of them are permanent.
/// The row that opens it is not a control panel, which is what it had become.
struct SSHVaultScreen: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Bindable var vault: SSHVaultModel
    let tier: String
    let canWrite: Bool
    /// What is on this device, so a fresh vault can be filled from it after a
    /// delete. Nil where the screen was opened without a library beside it.
    var library: SSHLibraryModel?

    @State private var showingSetup = false
    @State private var changingPassword = false
    @State private var showingRecovery = false
    @State private var confirmingRotation = false
    @State private var deleting = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Encrypted vault").font(.title3.weight(.semibold))
                    Text("Hosts, keys and snippets, readable only by your devices, your password and your recovery code.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                InspectorCloseButton(action: { dismiss() }, help: "Close", label: "Close vault")
            }
            .padding(Theme.Space.l)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.l) {
                    if let error = vault.error {
                        InlineBanner(text: FriendlyError.from(error).message, kind: .danger) {
                            vault.error = nil
                        }
                    }
                    if vault.unconfirmedRecovery {
                        action(
                            title: "Confirm your recovery code",
                            detail: "The code has been generated but not written down. It is the only way back in if the password is forgotten and every device is lost.",
                            button: "Show code",
                            icon: .reveal,
                            prominent: true
                        ) { showingRecovery = true }
                    }

                    // Out of reach beats absent. Offering "set up" here is
                    // what sent people into a create that the account then
                    // refused, and the sentence they got back was about a
                    // machine id rather than about the vault they already had.
                    if let unreachable = vault.unreachable {
                        let friendly = FriendlyError.from(unreachable)
                        action(
                            title: friendly.title,
                            detail: "\(friendly.message)\n\nAnything already saved on this computer still works.",
                            button: "Try again",
                            icon: .refresh,
                            prominent: true
                        ) { Task { await vault.registerAndRefresh() } }
                    } else if !vault.created {
                        action(
                            title: "Set up the vault",
                            detail: canWrite
                                ? "Creates a vault on this account, locked by a password you choose, and one recovery code. Nothing leaves the machine unencrypted."
                                : "Creating a vault needs Supporter or above. Existing vaults stay readable.",
                            button: "Set up vault",
                            icon: .security,
                            prominent: true,
                            enabled: canWrite
                        ) { showingSetup = true }
                    } else if vault.needsRecreate {
                        action(
                            title: "Recreate the vault",
                            detail: "It was made before password unlock and cannot be opened by this version. Anything saved on this Mac stays where it is.",
                            button: "Recreate",
                            icon: .refresh,
                            prominent: true
                        ) { showingSetup = true }
                    } else if vault.locked {
                        action(
                            title: "Unlock the vault",
                            detail: "Enter your vault password to let this computer read and write the account's saved servers and keys.",
                            button: "Unlock",
                            icon: .signIn,
                            prominent: true
                        ) { showingSetup = true }
                    } else {
                        status
                        if canWrite {
                            action(
                                title: "Change the password",
                                detail: "Ask for the one you use now, then the new one. The records are untouched: only the lock around them changes.",
                                button: "Change password",
                                icon: .edit
                            ) { changingPassword = true }
                            action(
                                title: "New recovery code",
                                detail: "Replaces the current code. The old one stops working as soon as the encrypted update succeeds, so save the new one before closing.",
                                button: "New recovery code",
                                icon: .refresh
                            ) { confirmingRotation = true }
                            action(
                                title: "Lock on this Mac",
                                detail: "This computer will ask for the password again, including after the helper restarts, until you unlock it here.",
                                button: "Lock",
                                icon: .signOut
                            ) { Task { await vault.lock() } }
                        } else {
                            Text("Your plan can read this vault but not write to it. Hosts and keys still sync in; changes made here stay on this machine.")
                                .font(.callout).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    // Outside every branch above, on purpose.
                    //
                    // This used to sit inside the unlocked case, which put the
                    // one way out of a forgotten password behind the door it
                    // is the way out of: a locked device was offered Unlock and
                    // nothing else, and somebody with no other device and no
                    // recovery code had no move left. Deleting needs no
                    // password, no code and no key, so nothing about it
                    // belonged behind an unlock.
                    if vault.created || vault.unreachable != nil {
                        Divider()
                        action(
                            title: "Delete the vault and start over",
                            detail: startOverDetail,
                            button: "Delete vault",
                            icon: .delete,
                            destructive: true
                        ) { deleting = true }
                    }
                }
                .padding(Theme.Space.l)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .sshSheetFrame(width: 560, height: 520)
        .sheet(isPresented: $showingSetup) {
            SSHVaultSetupSheet(tier: tier, status: $vault.status, recovery: $vault.recovery)
        }
        .sheet(isPresented: $changingPassword) {
            SSHVaultPasswordSheet(vault: vault)
        }
        .sheet(isPresented: $showingRecovery) {
            if let recovery = vault.recovery {
                SSHRecoveryWordsSheet(
                    recovery: recovery,
                    onConfirmed: { vault.recovery = nil },
                    onDiscard: { Task { await vault.reset() } }
                )
            }
        }
        .confirmationDialog(
            "Replace the current recovery code?",
            isPresented: $confirmingRotation,
            titleVisibility: .visible
        ) {
            Button("Generate a new recovery code", role: .destructive) { Task { await vault.rotateRecovery() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The current code will stop working as soon as the encrypted update succeeds.")
        }
        .sheet(isPresented: $deleting) {
            SSHVaultDeleteSheet(vault: vault, tier: tier, canWrite: canWrite, library: library)
        }
        .onChange(of: vault.recovery) { _, value in if value != nil { showingRecovery = true } }
        .task { await vault.refresh() }
        .task { await vault.watch() }
        // Coming back to the app is the moment somebody has most likely just
        // done something on another device.
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await vault.refresh() } }
        }
    }

    /// What deleting costs, said differently depending on what can be opened.
    ///
    /// A locked device cannot list what is in the vault, so it must not claim
    /// to know. What it can promise is the part that matters to somebody stuck:
    /// the servers on this computer are records, not secrets, and they stay.
    private var startOverDetail: String {
        let kept = "Everything saved on this device stays where it is, and a new vault can be filled from it. Nothing on any server changes."
        if vault.locked || vault.needsRecreate || vault.unreachable != nil {
            return "You do not need the password or the recovery code for this. The vault is removed from the account, and anything in it that this device never received is gone for good.\n\n\(kept)"
        }
        return "The vault is removed from the account and every device is asked to set up a new one. This cannot be undone.\n\n\(kept)"
    }

    private var status: some View {
        VStack(alignment: .leading, spacing: 2) {
            Label(
                vault.recordCount == 1 ? "1 record" : "\(vault.recordCount) records",
                systemImage: "lock.shield.fill"
            )
            .font(.callout.weight(.medium))
            Text("This device is enrolled and can read and write the vault.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    /// One decision: what it is, what it costs, and the button that does it.
    @ViewBuilder
    private func action(
        title: String,
        detail: String,
        button: String,
        icon: ActionIcon,
        prominent: Bool = false,
        destructive: Bool = false,
        enabled: Bool = true,
        perform: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            Text(title).font(.callout.weight(.medium))
            Text(detail)
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Group {
                if destructive {
                    Button(button, icon, action: perform).buttonStyle(DestructiveButtonStyle())
                } else if prominent {
                    Button(button, icon, action: perform).buttonStyle(AccentButtonStyle(small: true))
                } else {
                    Button(button, icon, action: perform).buttonStyle(SecondaryButtonStyle(small: true))
                }
            }
            .disabled(!enabled)
            .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Delete the vault, and offer to make a new one out of what is on this device.
///
/// Two halves, because deleting alone is not a way out. Somebody reaches this
/// screen having forgotten the password with no other device signed in, and
/// what they want is not an empty account: it is their servers back, syncing
/// again. The records are still in `connections.json`, so the second half is
/// possible and the sheet stays open to offer it.
///
/// Typed confirmation rather than one tap. This is the one control in the app
/// that destroys data for every device on the account at once.
struct SSHVaultDeleteSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var vault: SSHVaultModel
    let tier: String
    let canWrite: Bool
    var library: SSHLibraryModel?

    @State private var typed = ""
    @State private var working = false
    @State private var deleted = false
    @State private var creating = false

    private static let word = "DELETE"

    private var confirmed: Bool {
        typed.trimmingCharacters(in: .whitespaces).uppercased() == Self.word
    }

    /// Keys whose private half only ever lived in the vault. Nothing recovers
    /// these, so they are named before the button, not after it.
    private var strandedKeys: [SSHKeyRecord] { library?.keysOnlyInTheVault ?? [] }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(deleted ? "The vault is gone" : "Delete the vault and start over")
                        .font(.title3.weight(.semibold))
                    Text(deleted
                        ? "This account has no vault. Nothing saved on this device was touched."
                        : "For when the password is forgotten and no other device can open it.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                InspectorCloseButton(action: { dismiss() }, help: "Close", label: "Close vault deletion")
            }
            Divider()
            if deleted { afterBody } else { beforeBody }
            if let error = vault.error {
                Text(FriendlyError.from(error).message)
                    .font(.caption).foregroundStyle(Theme.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            footer
        }
        .padding(Theme.Space.l)
        .sshSheetFrame(width: 560, height: 520)
        .sheet(isPresented: $creating) {
            SSHVaultSetupSheet(tier: tier, status: $vault.status, recovery: $vault.recovery)
        }
        // The setup sheet only makes the vault. Filling it is this screen's
        // job, and it can only run once the vault exists to be filled.
        .onChange(of: vault.created) { was, now in
            guard deleted, !was, now, let library else { return }
            Task {
                working = true
                await library.seedVaultFromThisDevice(tier: tier)
                working = false
                dismiss()
            }
        }
    }

    @ViewBuilder
    private var beforeBody: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            bullet("The vault is removed from the account. Every signed-in device is asked to set up a new one.")
            bullet("Anything in it that this device never received cannot be recovered, by you or by anybody here.")
            bullet("Your saved servers, folders and snippets are records rather than secrets. They stay on this device, and a new vault can be filled from them.")
            bullet("Nothing on any server changes, and no connection is closed.")
            if !strandedKeys.isEmpty {
                Text(strandedKeys.count == 1
                    ? "One key has no private half on this device and will be lost:"
                    : "\(strandedKeys.count) keys have no private half on this device and will be lost:")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Theme.warning)
                    .padding(.top, Theme.Space.xs)
                ForEach(strandedKeys) { key in
                    Text("\u{2022} \(key.label)")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Text("Type \(Self.word) to confirm.")
                .font(.caption).foregroundStyle(.secondary)
                .padding(.top, Theme.Space.xs)
            TextField(Self.word, text: $typed)
                .textFieldStyle(.roundedBorder)
                .font(Theme.mono(12))
                #if !os(macOS)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                #endif
        }
    }

    @ViewBuilder
    private var afterBody: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            if canWrite {
                Text("Make a new vault and put this device's servers, folders, snippets and keys into it. Your other devices join it with the new password.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let library {
                    Text(summary(of: library))
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Text("Making a vault needs Supporter or above. Everything saved on this device keeps working without one.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func summary(of library: SSHLibraryModel) -> String {
        let parts = [
            count(library.hosts.count, "server", "servers"),
            count(library.folders.count, "folder", "folders"),
            count(library.snippets.count, "snippet", "snippets"),
            count(library.keys.count - library.keysOnlyInTheVault.count, "key", "keys"),
        ].compactMap { $0 }
        return parts.isEmpty ? "There is nothing on this device to carry across." : "Ready to carry across: " + parts.joined(separator: ", ") + "."
    }

    private func count(_ n: Int, _ one: String, _ many: String) -> String? {
        n <= 0 ? nil : "\(n) \(n == 1 ? one : many)"
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.xs) {
            Text("\u{2022}").foregroundStyle(.secondary)
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var footer: some View {
        HStack {
            Button(deleted ? "Not now" : "Cancel", .dismiss) { dismiss() }
                .buttonStyle(SecondaryButtonStyle())
                .frame(minWidth: Theme.Control.pairedWidth)
            Spacer()
            if deleted {
                Button("Create a new vault", .create) { creating = true }
                    .buttonStyle(AccentButtonStyle())
                    .disabled(!canWrite || working)
            } else {
                Button("Delete vault", .delete) { Task { await run() } }
                    .buttonStyle(DestructiveButtonStyle())
                    .disabled(!confirmed || working)
            }
        }
    }

    private func run() async {
        working = true
        vault.error = nil
        await vault.reset()
        working = false
        // Staying open is the point. A sheet that closed here would leave
        // somebody on the screen they started from with an empty account and
        // no hint that their servers are still on the machine.
        if vault.error == nil { deleted = true }
    }
}

/// Change the vault password, having proved the current one.
///
/// A change is not a reset: the records never move, only the wrap around the
/// key. That is why it does not produce a new recovery code and does not touch
/// the snapshot revision, so it cannot collide with a device writing a record.
struct SSHVaultPasswordSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var vault: SSHVaultModel

    @State private var current = ""
    @State private var next = ""
    @State private var again = ""
    @State private var working = false

    private var problems: [String] { VaultPassword.problems(next) }
    private var canSave: Bool {
        !working && !current.isEmpty && problems.isEmpty && next == again
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Change vault password").font(.title3.weight(.semibold))
                    Text("Your saved servers and keys stay exactly as they are.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                InspectorCloseButton(action: { dismiss() }, help: "Close", label: "Close password change")
            }
            Divider()
            SecureField("Current password", text: $current)
                .textFieldStyle(.roundedBorder)
            SecureField("New password", text: $next)
                .textFieldStyle(.roundedBorder)
            SecureField("Type the new one again", text: $again)
                .textFieldStyle(.roundedBorder)
            VaultPasswordRules(password: next)
            if !again.isEmpty, next != again {
                Text("The two do not match.").font(.caption).foregroundStyle(Theme.danger)
            }
            if let error = vault.error {
                Text(FriendlyError.from(error).message).font(.caption).foregroundStyle(Theme.danger)
            }
            Spacer(minLength: 0)
            HStack {
                Button("Cancel", .dismiss) { dismiss() }
                    .buttonStyle(SecondaryButtonStyle())
                    .frame(minWidth: Theme.Control.pairedWidth)
                Spacer()
                Button("Change password", .save) {
                    Task {
                        working = true
                        if await vault.changePassword(current: current, to: next) { dismiss() }
                        working = false
                    }
                }
                .buttonStyle(AccentButtonStyle())
                .frame(minWidth: Theme.Control.pairedWidth)
                .disabled(!canSave)
            }
        }
        .padding(Theme.Space.l)
        .sshSheetFrame(width: 520, height: 420)
    }
}
