// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available: source sharing and own builds are permitted.
// Store and commercial distribution of builds is reserved. See LICENSE.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

import Observation
import SwiftUI

@MainActor
@Observable
final class SSHVaultModel {
    @ObservationIgnored private var foreground = true
    @ObservationIgnored let ownership: SSHOperationOwner
    @ObservationIgnored private var refreshGeneration: UInt64 = 0
    init(ownerScope: WorkReference.Scope? = nil) {
        ownership = SSHOperationOwner(scope: ownerScope)
    }

    func deactivate() {
        let scope = ownership.captured?.scope
        let sessionID = status?.vaultSession
        let leftAccount = ownership.captured?.generation != WorkSessionContext.shared.generation
        ownership.retire()
        refreshGeneration &+= 1
        recovery = nil
        status = nil
        error = nil
        if leftAccount, let scope, let sessionID {
            Task { await Bridge.retireSSHVault(scope: scope, sessionID: sessionID) }
        }
    }

    private(set) var isWorking = false
    var status: SSHVaultStatus?
    var recovery: String?
    var error: String?

    var created: Bool { status?.created == true }
    var enrolled: Bool { status?.enrolled == true }
    var locked: Bool { created && status?.locked == true }
    var needsRecreate: Bool { status?.needsRecreate == true }
    var recordCount: Int { status?.recordCount ?? 0 }
    var unconfirmedRecovery: Bool { recovery != nil }
    var unreachable: String? { status?.unreachable }

    func refresh(allowDuringMutation: Bool = false) async {
        guard !isWorking || allowDuringMutation else { return }
        guard let owner = ownership.claim(), owner.scope.kind == .account else { return }
        refreshGeneration &+= 1
        let generation = refreshGeneration
        if let fresh = try? await Bridge.sshVaultStatus(expectedScope: owner.scope, expectedGeneration: owner.generation),
           ownership.permits(owner), generation == refreshGeneration {
            status = fresh
        }
    }

    func watch() async {
        if foreground { await refresh() }
        while ownership.claim() != nil && !Task.isCancelled {
            try? await Task.sleep(for: .seconds(20))
            if Task.isCancelled { return }
            if foreground { await refresh() }
        }
    }

    func setForeground(_ value: Bool) { foreground = value }

    func registerAndRefresh() async {
        await refresh()
    }

    func rotateRecovery(password: String) async {
        guard !isWorking, let owner = ownership.claim() else { return }
        isWorking = true
        defer { isWorking = false }
        refreshGeneration &+= 1
        do {
            let result = try await Bridge.rotateSSHVaultRecovery(password: password, expectedScope: owner.scope, expectedGeneration: owner.generation)
            guard ownership.permits(owner) else { return }
            recovery = result.recovery
            error = nil
            await refresh(allowDuringMutation: true)
        } catch { if ownership.permits(owner) { self.error = error.localizedDescription } }
    }

    func lock() async {
        guard !isWorking, let owner = ownership.claim() else { return }
        isWorking = true
        defer { isWorking = false }
        refreshGeneration &+= 1
        do {
            try await Bridge.lockSSHVault(expectedScope: owner.scope, expectedGeneration: owner.generation)
            guard ownership.permits(owner) else { return }
            status?.locked = true
            error = nil
            await refresh(allowDuringMutation: true)
        } catch { if ownership.permits(owner) { self.error = error.localizedDescription } }
    }

    @discardableResult
    func reset() async -> Bool {
        guard !isWorking, let owner = ownership.claim() else { return false }
        isWorking = true
        defer { isWorking = false }
        refreshGeneration &+= 1
        do {
            try await Bridge.resetSSHVault(expectedScope: owner.scope, expectedGeneration: owner.generation)
            guard ownership.permits(owner) else { return false }
            recovery = nil
            status?.created = false
            status?.recordCount = 0
            status?.locked = false
            error = nil
            await refresh(allowDuringMutation: true)
            return ownership.permits(owner)
        } catch {
            if ownership.permits(owner) { self.error = error.localizedDescription }
            return false
        }
    }

    func changePassword(current: String, to next: String) async -> Bool {
        guard !isWorking, let owner = ownership.claim() else { return false }
        isWorking = true
        defer { isWorking = false }
        refreshGeneration &+= 1
        do {
            let result = try await Bridge.setSSHVaultPassword(current: current, newPassword: next, expectedScope: owner.scope, expectedGeneration: owner.generation)
            guard ownership.permits(owner) else { return false }
            if let fresh = result.recovery { recovery = fresh }
            error = nil
            await refresh(allowDuringMutation: true)
            return ownership.permits(owner)
        } catch {
            if ownership.permits(owner) { self.error = error.localizedDescription }
            return false
        }
    }

}

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
                if vault.status == nil {
                    Skeleton.Bar(width: 62, height: 10)
                } else if let detail {
                    Text(detail)
                        .font(Theme.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .transition(.opacity)
                }
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
            .frame(minHeight: 44)
            .background(background, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.border))
            .contentShape(.rect)
            .animation(.smooth(duration: 0.22), value: vault.status)
        }
        .buttonStyle(CardButtonStyle())
    }

    private var symbol: String {
        if vault.unconfirmedRecovery { return "exclamationmark.shield.fill" }
        return vault.created ? "lock.shield.fill" : "lock.shield"
    }

    private var label: String {
        vault.unconfirmedRecovery ? L10n.text("apple.sshvaultview.recovery_code_not_confirmed.dc3c61fd") : L10n.text("apple.sshvaultview.encrypted_vault.31939e06")
    }

    private var detail: String? {
        if vault.unconfirmedRecovery { return nil }
        if vault.needsRecreate { return L10n.text("apple.sshvaultview.has_to_be_recreated.edf77f46") }
        if vault.locked { return nil }
        if vault.created {
            let records = vault.recordCount == 1 ? L10n.text("apple.sshvaultview.1_record.43507739") : L10n.text("apple.sshvaultview.0_records.2cd6fd62", "\(vault.recordCount)")
            return canWrite ? records : L10n.text("apple.sshvaultview.0_not_syncing.b60c9633", "\(records)")
        }
        return canWrite ? L10n.text("apple.sshvaultview.not_set_up.ef93782b") : L10n.text("apple.sshvaultview.not_syncing.c0737345")
    }

    private var background: Color {
        vault.unconfirmedRecovery ? Theme.warning.opacity(0.10) : Theme.panel
    }
}

struct SSHVaultScreen: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL
    @Bindable var vault: SSHVaultModel
    let tier: String
    let canWrite: Bool
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
                        action(
                            title: L10n.text("common.sync_now"),
                            detail: syncDetail,
                            button: library?.vaultSyncing == true ? L10n.text("apple.sshvaultview.syncing.5c8b9e1c") : L10n.text("common.sync_now"),
                            icon: .refresh,
                            busy: library?.vaultSyncing == true
                        ) {
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
                        action(
                            title: L10n.text("apple.sshvaultview.this_vault_has_stopped_syncing.7a4c7ecd"),
                            detail: L10n.text("apple.sshvaultview.it_still_exists_on_your_account_and_this_d.300cb00b"),
                            button: L10n.text("apple.sshvaultview.see_plans.d9898933"),
                            icon: .plans,
                            prominent: true
                        ) { Plans.open(using: openURL) }
                    }
                }

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
        .onChange(of: showingSetup) { was, now in
            guard was, !now, vault.created, canWrite, let library else { return }
            Task {
                await library.syncVault(tier: tier, asked: true)
                await vault.refresh()
            }
        }
        .task { await vault.refresh() }
        #if os(macOS)
        .task { await vault.watch() }
        #endif
        #if os(macOS)
        .onChange(of: scenePhase) { _, phase in
            vault.setForeground(phase == .active)
            if phase == .active { Task { await vault.refresh() } }
        }
        #endif
    }

    private var startOverDetail: String {
        let kept = L10n.text("apple.sshvaultview.everything_saved_on_this_device_stays_wher.d5485bee")
        if vault.locked || vault.needsRecreate || vault.unreachable != nil {
            return L10n.text("apple.sshvaultview.you_do_not_need_the_password_or_the_recove.61219aeb", "\(kept)")
        }
        return L10n.text("apple.sshvaultview.the_vault_is_removed_from_the_account_and.c8237a1a", "\(kept)")
    }

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
            Text(canWrite
                ? L10n.text("apple.sshvaultview.this_device_is_enrolled_and_can_read_and_w.2ee15a1d")
                : L10n.text("apple.sshvaultview.this_device_is_enrolled_and_can_read_the_v.2d983d08"))
                .font(Theme.caption).foregroundStyle(.secondary)
        }
    }

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
            Group {
                if destructive {
                    Button(button, icon, action: perform).buttonStyle(DestructiveButtonStyle())
                } else if prominent {
                    Button(button, icon, action: perform).buttonStyle(AccentButtonStyle())
                } else {
                    Button(button, icon, action: perform).buttonStyle(SecondaryButtonStyle())
                }
            }
            .disabled(busy || vault.isWorking)
            .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

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
        let succeeded = await vault.reset()
        working = false
        if succeeded { deleted = true }
    }
}

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
