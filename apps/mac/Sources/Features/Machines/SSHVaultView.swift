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
        if let fresh = try? await Bridge.sshVaultStatus() {
            status = fresh
        }
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

    func rotateRecovery(password: String) async {
        do {
            recovery = try await Bridge.rotateSSHVaultRecovery(password: password).recovery
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
                    .font(Theme.callout)
                    .foregroundStyle(vault.unconfirmedRecovery ? Theme.warning : Color.primary)
                    .lineLimit(1)
                Spacer(minLength: Theme.Space.s)
                // The count at the trailing edge, and a wireframe in its place
                // until the account has answered.
                //
                // It used to be the tail of the label, which meant the row
                // read "Encrypted vault · not set up" for as long as the call
                // took and then rewrote itself into "· 3 records": a sentence
                // that was wrong first and jumped when it stopped being wrong.
                // A placeholder of about the right width says the same thing
                // honestly and does not move the rest of the row when the real
                // answer lands.
                if vault.status == nil {
                    Skeleton.Bar(width: 62, height: 10)
                } else if let detail {
                    Text(detail)
                        .font(Theme.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .transition(.opacity)
                }
                // The badge belongs at the trailing edge with the chevron, not
                // pinned to the end of the sentence. Beside the text it read as
                // a second half of the label, and the label already said
                // "locked", so the row said it twice a few points apart.
                if vault.locked {
                    Text(L10n.text("apple.sshvaultview.locked.a424e33d"))
                        .font(Theme.caption)
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(Theme.accentSoft, in: Capsule())
                        .foregroundStyle(Theme.accent)
                }
                Image(systemName: "chevron.right")
                    .font(Theme.font(10, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, Theme.Space.m)
            .padding(.vertical, Theme.Space.s)
            // A row that opens a whole screen has to be comfortable to hit.
            // At eight points of padding around one line this came out near
            // 33, under the 44 a finger is entitled to, and it was cramped
            // with a pointer too. The same number on both: the Mac's rows
            // are not a different kind of target, they are the same row.
            .frame(minHeight: 44)
            .background(background, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.border))
            .contentShape(.rect)
            .animation(.smooth(duration: 0.22), value: vault.status)
        }
        .buttonStyle(.plain)
    }

    private var symbol: String {
        if vault.unconfirmedRecovery { return "exclamationmark.shield.fill" }
        return vault.created ? "lock.shield.fill" : "lock.shield"
    }

    private var label: String {
        vault.unconfirmedRecovery ? L10n.text("apple.sshvaultview.recovery_code_not_confirmed.dc3c61fd") : L10n.text("apple.sshvaultview.encrypted_vault.31939e06")
    }

    /// What this vault is, in the space at the trailing edge. Nil where the
    /// leading text has already said the whole thing.
    private var detail: String? {
        if vault.unconfirmedRecovery { return nil }
        if vault.needsRecreate { return L10n.text("apple.sshvaultview.has_to_be_recreated.edf77f46") }
        // No "locked" here: the badge beside this says that, and the row was
        // saying it twice.
        if vault.locked { return nil }
        if vault.created {
            let records = vault.recordCount == 1 ? "1 record" : L10n.text("apple.sshvaultview.0_records.2cd6fd62", "\(vault.recordCount)")
            // A vault that exists on a plan that cannot write it is the state
            // somebody lands in by letting Supporter lapse, and the row used
            // to look exactly like a vault that was working. The records are
            // still there and still readable, and that is worth saying, but
            // not without saying that nothing new is going into them.
            return canWrite ? records : L10n.text("apple.sshvaultview.0_not_syncing.b60c9633", "\(records)")
        }
        // Not "Supporter and above", which named a plan and left it to the
        // reader to work out that this meant off. What is happening here is
        // that servers saved on this device stay on this device.
        return canWrite ? L10n.text("apple.sshvaultview.not_set_up.ef93782b") : L10n.text("apple.sshvaultview.not_syncing.c0737345")
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
    @Environment(\.openURL) private var openURL
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
    @State private var rotationPassword = ""
    @State private var deleting = false

    var body: some View {
        ThemedSheet(
            title: L10n.text("apple.sshvaultview.encrypted_vault.31939e06"),
            subtitle: L10n.text("apple.sshvaultview.hosts_keys_and_snippets_readable_only_by_y.5b20e431"),
            icon: .security,
            scrolls: true,
            onClose: { dismiss() }
        ) {
            VStack(alignment: .leading, spacing: Theme.Space.xl) {
                if let error = vault.error {
                    InlineBanner(text: FriendlyError.from(error).message, kind: .danger) {
                        vault.error = nil
                    }
                }
                // What the last sync could not do. It has its own line on
                // the library screen, which this sheet covers, so a sync
                // started here would otherwise report nothing at all.
                if let library, let problem = library.vaultError {
                    InlineBanner(text: L10n.text("apple.sshvaultview.not_everything_synced_0.4b2987c3", "\(FriendlyError.from(problem).message)")) {
                        library.vaultError = nil
                    }
                }
                if vault.unconfirmedRecovery {
                    action(
                        title: L10n.text("apple.sshvaultview.confirm_your_recovery_code.2a50d287"),
                        detail: L10n.text("apple.sshvaultview.the_code_has_been_generated_but_not_writte.e121ffb4"),
                        button: L10n.text("apple.sshvaultview.show_code.c9eab29c"),
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
                        detail: L10n.text("apple.sshvaultview.0_anything_already_saved_on_this_computer.403eb4a5", "\(friendly.message)"),
                        button: L10n.text("apple.sshvaultview.try_again.d8b8392e"),
                        icon: .refresh,
                        prominent: true
                    ) { Task { await vault.registerAndRefresh() } }
                } else if !vault.created, canWrite {
                    action(
                        title: L10n.text("apple.sshvaultview.set_up_the_vault.dd2ea4f1"),
                        detail: L10n.text("apple.sshvaultview.creates_a_vault_on_this_account_locked_by.d1530af6"),
                        button: L10n.text("apple.sshvaultview.set_up_vault.663a7ec6"),
                        icon: .security,
                        prominent: true
                    ) { showingSetup = true }
                } else if !vault.created {
                    // A greyed-out "Set up vault" was the whole of this
                    // screen on a Free plan: the one thing on it did
                    // nothing when pressed, and pressing a dead button is
                    // how somebody finds out what their plan does. The
                    // button that is here now is the one that can help.
                    action(
                        title: L10n.text("apple.sshvaultview.syncing_needs_supporter.00d943e5"),
                        detail: L10n.text("apple.sshvaultview.your_servers_folders_keys_and_snippets_are.be25d97f"),
                        button: L10n.text("apple.sshvaultview.see_plans.d9898933"),
                        icon: .plans,
                        prominent: true
                    ) { Plans.open(using: openURL) }
                } else if vault.needsRecreate {
                    action(
                        title: L10n.text("apple.sshvaultview.recreate_the_vault.1e58f60b"),
                        detail: L10n.text("apple.sshvaultview.it_was_made_before_password_unlock_and_can.c713b2b8"),
                        button: L10n.text("apple.sshvaultview.recreate.15efb691"),
                        icon: .refresh,
                        prominent: true
                    ) { showingSetup = true }
                } else if vault.locked {
                    action(
                        title: L10n.text("apple.sshvaultview.unlock_the_vault.ee6cb495"),
                        detail: L10n.text("apple.sshvaultview.use_your_vault_password_or_biometrics_enab.0eeb1674"),
                        button: L10n.text("apple.sshvaultview.unlock.4ac709aa"),
                        icon: .signIn,
                        prominent: true
                    ) { showingSetup = true }
                } else {
                    status
                    if let name = SSHVaultBiometrics.name {
                        action(
                            title: L10n.text("apple.sshvaultview.unlock_with_0.20a41ad2", "\(name)"),
                            detail: L10n.text("apple.sshvaultview.enter_your_vault_password_to_manage_biomet.4c04ba28"),
                            button: L10n.text("apple.sshvaultview.manage_biometrics.883eb089"),
                            icon: .security
                        ) { showingSetup = true }
                    }
                    if canWrite {
                        // First, because it is the one thing on this
                        // screen somebody opens it to do. The three below
                        // it are maintenance.
                        action(
                            title: L10n.text("common.sync_now"),
                            detail: syncDetail,
                            button: library?.vaultSyncing == true ? L10n.text("apple.sshvaultview.syncing.5c8b9e1c") : L10n.text("common.sync_now"),
                            icon: .refresh,
                            busy: library?.vaultSyncing == true
                        ) {
                            // The count on this screen is the vault's own
                            // answer, so it has to be asked again or a
                            // sync that just carried thirty records across
                            // still reads "0 records".
                            Task {
                                await library?.syncNow()
                                await vault.refresh()
                            }
                        }
                        action(
                            title: L10n.text("apple.sshvaultview.change_the_password.0876521d"),
                            detail: L10n.text("apple.sshvaultview.ask_for_the_one_you_use_now_then_the_new_o.3af2e414"),
                            button: L10n.text("apple.sshvaultview.change_password.3f9c991f"),
                            icon: .edit
                        ) { changingPassword = true }
                        action(
                            title: L10n.text("apple.sshvaultview.new_recovery_code.5335b90e"),
                            detail: L10n.text("apple.sshvaultview.replaces_the_current_code_the_old_one_stop.f2add631"),
                            button: L10n.text("apple.sshvaultview.new_recovery_code.5335b90e"),
                            icon: .refresh
                        ) { confirmingRotation = true }
                        action(
                            title: L10n.text("apple.sshvaultview.lock_on_this_device.43218e32"),
                            detail: L10n.text("apple.sshvaultview.unlock_again_with_your_vault_password_or_b.5f957103"),
                            button: L10n.text("apple.sshvaultview.lock.db44b8db"),
                            icon: .signOut
                        ) { Task { await vault.lock() } }
                    } else {
                        // The state a lapsed, refunded or cancelled
                        // Supporter lands in, and the one this screen used
                        // to say least about: the vault is still there,
                        // still readable, and quietly no longer receiving
                        // anything. Said plainly, with the way back.
                        action(
                            title: L10n.text("apple.sshvaultview.this_vault_has_stopped_syncing.7a4c7ecd"),
                            detail: L10n.text("apple.sshvaultview.it_still_exists_on_your_account_and_this_d.300cb00b"),
                            button: L10n.text("apple.sshvaultview.see_plans.d9898933"),
                            icon: .plans,
                            prominent: true
                        ) { Plans.open(using: openURL) }
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
                    ThemeRule()
                    action(
                        title: L10n.text("apple.sshvaultview.delete_the_vault_and_start_over.e49d06f1"),
                        detail: startOverDetail,
                        button: L10n.text("apple.sshvaultview.delete_vault.9fd7de76"),
                        icon: .delete,
                        destructive: true
                    ) { deleting = true }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .modalFrame(width: 580, height: 640)
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
        .alert(
            L10n.text("apple.sshvaultview.replace_the_current_recovery_code.7430b0d2"),
            isPresented: $confirmingRotation
        ) {
            SecureField(L10n.text("apple.sshvaultview.vault_password.1853752f"), text: $rotationPassword)
            Button(L10n.text("apple.sshvaultview.generate_a_new_recovery_code.0db28270"), role: .destructive) {
                let password = rotationPassword
                rotationPassword = ""
                Task { await vault.rotateRecovery(password: password) }
            }
            Button(L10n.text("common.cancel"), role: .cancel) { rotationPassword = "" }
        } message: {
            Text(L10n.text("apple.sshvaultview.enter_the_vault_password_to_re_encrypt_you.fec33737"))
        }
        .sheet(isPresented: $deleting) {
            SSHVaultDeleteSheet(vault: vault, tier: tier, canWrite: canWrite, library: library)
        }
        .onChange(of: vault.recovery) { _, value in if value != nil { showingRecovery = true } }
        // Making a vault, and unlocking one, both end with this device able to
        // write to a vault it could not write to a moment ago. Neither used to
        // put anything into it: a fresh vault said "0 records" beside a list of
        // forty servers, and the only thing that ever went in was the next
        // record somebody happened to edit.
        .onChange(of: showingSetup) { was, now in
            guard was, !now, vault.created, canWrite, let library else { return }
            Task {
                await library.syncVault(tier: tier, asked: true)
                await vault.refresh()
            }
        }
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
        let kept = L10n.text("apple.sshvaultview.everything_saved_on_this_device_stays_wher.d5485bee")
        if vault.locked || vault.needsRecreate || vault.unreachable != nil {
            return L10n.text("apple.sshvaultview.you_do_not_need_the_password_or_the_recove.61219aeb", "\(kept)")
        }
        return L10n.text("apple.sshvaultview.the_vault_is_removed_from_the_account_and.c8237a1a", "\(kept)")
    }

    /// What Sync now does, and what the last one did.
    ///
    /// The sentence about what it does matters as much as the button: this is
    /// the screen where somebody who has just made a vault and still sees
    /// "0 records" comes looking for the thing that carries their servers into
    /// it, and until now there was nothing here to tell them or to press.
    private var syncDetail: String {
        let what = L10n.text("apple.sshvaultview.puts_anything_saved_on_this_device_that_th.0be965fe")
        guard let library else { return what }
        if library.vaultSyncing { return L10n.text("apple.sshvaultview.0_syncing_now.a1cfcb49", "\(what)") }
        guard let when = library.vaultSyncedAt else {
            return L10n.text("apple.sshvaultview.0_not_synced_yet_on_this_device.f3015a55", "\(what)")
        }
        return L10n.text("apple.sshvaultview.0_last_synced_1.11b24df2", "\(what)", "\(RelativeClock.phrase(for: when, style: .full))")
    }

    private var status: some View {
        VStack(alignment: .leading, spacing: 2) {
            Label(
                vault.recordCount == 1 ? L10n.text("apple.sshvaultview.1_record.43507739") : L10n.text("apple.sshvaultview.0_records.2cd6fd62", "\(vault.recordCount)"),
                systemImage: "lock.shield.fill"
            )
            .font(Theme.callout.weight(.medium))
            // It said "can read and write" on every plan, directly above the
            // paragraph explaining that this plan cannot write. One of the two
            // had to go, and it was not the paragraph.
            Text(canWrite
                ? L10n.text("apple.sshvaultview.this_device_is_enrolled_and_can_read_and_w.2ee15a1d")
                : L10n.text("apple.sshvaultview.this_device_is_enrolled_and_can_read_the_v.2d983d08"))
                .font(Theme.caption).foregroundStyle(.secondary)
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
        busy: Bool = false,
        perform: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            Text(title).font(Theme.callout.weight(.medium))
            Text(detail)
                .font(Theme.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            // All three at the same size. Prominent and plain were dense and
            // destructive was not, so Unlock came out visibly smaller than
            // Delete vault two paragraphs below it and the screen looked like
            // it had been assembled from two different designs. These are the
            // one call to action under a paragraph of consequences, which is
            // the full size everywhere else in the app.
            Group {
                if destructive {
                    Button(button, icon, action: perform).buttonStyle(DestructiveButtonStyle())
                } else if prominent {
                    Button(button, icon, action: perform).buttonStyle(AccentButtonStyle())
                } else {
                    Button(button, icon, action: perform).buttonStyle(SecondaryButtonStyle())
                }
            }
            .disabled(busy)
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
    @Environment(\.openURL) private var openURL
    @Bindable var vault: SSHVaultModel
    let tier: String
    let canWrite: Bool
    var library: SSHLibraryModel?

    @State private var typed = ""
    @State private var working = false
    @State private var deleted = false
    @State private var creating = false

    private static let word = L10n.text("apple.sshvaultview.delete.65daeb37")

    private var confirmed: Bool {
        typed.trimmingCharacters(in: .whitespaces).uppercased() == Self.word
    }

    /// Keys whose private half only ever lived in the vault. Nothing recovers
    /// these, so they are named before the button, not after it.
    private var strandedKeys: [SSHKeyRecord] { library?.keysOnlyInTheVault ?? [] }

    var body: some View {
        ThemedSheet(
            title: deleted ? L10n.text("apple.sshvaultview.the_vault_is_gone.ab82a5c9") : L10n.text("apple.sshvaultview.delete_the_vault_and_start_over.e49d06f1"),
            subtitle: deleted
                ? L10n.text("apple.sshvaultview.this_account_has_no_vault_nothing_saved_on.85cfe254")
                : L10n.text("apple.sshvaultview.for_when_the_password_is_forgotten_and_no.fd06b159"),
            icon: .delete,
            onClose: { dismiss() }
        ) {
            VStack(alignment: .leading, spacing: Theme.Space.l) {
                if deleted { afterBody } else { beforeBody }
                if let error = vault.error {
                    Text(FriendlyError.from(error).message)
                        .font(Theme.caption)
                        .foregroundStyle(Theme.danger)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        } actions: {
            footer
        }
        .modalFrame(width: 580, height: 560)
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
            bullet(L10n.text("apple.sshvaultview.the_vault_is_removed_from_the_account_ever.b635ec5b"))
            bullet(L10n.text("apple.sshvaultview.anything_in_it_that_this_device_never_rece.eba27863"))
            bullet(L10n.text("apple.sshvaultview.your_saved_servers_folders_and_snippets_ar.52190870"))
            bullet(L10n.text("apple.sshvaultview.nothing_on_any_server_changes_and_no_conne.88bb63db"))
            if !strandedKeys.isEmpty {
                Text(strandedKeys.count == 1
                    ? L10n.text("apple.sshvaultview.one_key_has_no_private_half_on_this_device.c7b6f61e")
                    : L10n.text("apple.sshvaultview.0_keys_have_no_private_half_on_this_device.11149f0a", "\(strandedKeys.count)"))
                    .font(Theme.caption.weight(.medium))
                    .foregroundStyle(Theme.warning)
                    .padding(.top, Theme.Space.xs)
                ForEach(strandedKeys) { key in
                    Text(L10n.text("apple.sshvaultview.0.b05cd7b2", "\(key.label)"))
                        .font(Theme.caption).foregroundStyle(.secondary)
                }
            }
            Text(L10n.text("apple.sshvaultview.type_0_to_confirm.9d14bdfd", "\(Self.word)"))
                .font(Theme.caption).foregroundStyle(.secondary)
                .padding(.top, Theme.Space.xs)
            TextField(Self.word, text: $typed)
                .textFieldStyle(.themedMono(12))
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
                Text(L10n.text("apple.sshvaultview.make_a_new_vault_and_put_this_device_s_ser.f579b3e4"))
                    .font(Theme.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let library {
                    Text(summary(of: library))
                        .font(Theme.caption).foregroundStyle(.secondary)
                }
            } else {
                Text(L10n.text("apple.sshvaultview.making_a_vault_needs_supporter_or_above_ev.ec6a00d6"))
                    .font(Theme.callout).foregroundStyle(.secondary)
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
        return parts.isEmpty ? L10n.text("apple.sshvaultview.there_is_nothing_on_this_device_to_carry_a.9d9460dc") : L10n.text("apple.sshvaultview.ready_to_carry_across.7fb2e43d") + parts.joined(separator: ", ") + "."
    }

    private func count(_ n: Int, _ one: String, _ many: String) -> String? {
        n <= 0 ? nil : "\(n) \(n == 1 ? one : many)"
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.xs) {
            Text(L10n.text("apple.sshvaultview..4f8865ab")).foregroundStyle(.secondary)
            Text(text)
                .font(Theme.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var footer: some View {
        Button(deleted ? L10n.text("apple.sshvaultview.not_now.a0e63d7c") : L10n.text("common.cancel"), .dismiss) { dismiss() }
            .buttonStyle(SecondaryButtonStyle())
            .keyboardShortcut(.cancelAction)
        Spacer()
        if deleted, !canWrite {
            // The same dead button as the one on the screen behind this,
            // in the one place somebody arrives at having just lost the
            // vault they were trying to get back into.
            Button(L10n.text("apple.sshvaultview.see_plans.d9898933"), .plans) { Plans.open(using: openURL) }
                .buttonStyle(AccentButtonStyle())
        } else if deleted {
            Button(L10n.text("apple.sshvaultview.create_a_new_vault.6c1a3d41"), .create) { creating = true }
                .buttonStyle(AccentButtonStyle())
                .disabled(working)
        } else {
            Button(L10n.text("apple.sshvaultview.delete_vault.9fd7de76"), .delete) { Task { await run() } }
                .buttonStyle(DestructiveButtonStyle())
                .disabled(!confirmed || working)
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
        ThemedSheet(
            title: L10n.text("apple.sshvaultview.change_vault_password.2dea91a3"),
            subtitle: L10n.text("apple.sshvaultview.your_saved_servers_and_keys_stay_exactly_a.7fcbdec6"),
            icon: .security,
            onClose: { dismiss() }
        ) {
            VStack(alignment: .leading, spacing: Theme.Space.l) {
                SecureField(L10n.text("apple.sshvaultview.current_password.72ed2bd7"), text: $current)
                    .themedFieldBox()
                SecureField(L10n.text("apple.sshvaultview.new_password.3dd9df44"), text: $next)
                    .themedFieldBox()
                SecureField(L10n.text("apple.sshvaultview.type_the_new_one_again.489d8d4c"), text: $again)
                    .themedFieldBox()
                VaultPasswordRules(password: next)
                if !again.isEmpty, next != again {
                    Text(L10n.text("apple.sshvaultview.the_two_do_not_match.184006b7"))
                        .font(Theme.caption)
                        .foregroundStyle(Theme.danger)
                }
                if let error = vault.error {
                    Text(FriendlyError.from(error).message)
                        .font(Theme.caption)
                        .foregroundStyle(Theme.danger)
                }
            }
        } actions: {
            Button(L10n.text("common.cancel"), .dismiss) { dismiss() }
                .buttonStyle(SecondaryButtonStyle())
                .keyboardShortcut(.cancelAction)
            Spacer()
            Button(L10n.text("apple.sshvaultview.change_password.3f9c991f"), .save) {
                Task {
                    working = true
                    if await vault.changePassword(current: current, to: next) { dismiss() }
                    working = false
                }
            }
            .buttonStyle(AccentButtonStyle())
            .disabled(!canSave)
            .keyboardShortcut(.defaultAction)
        }
        .modalFrame(width: 540, height: 520)
    }
}
