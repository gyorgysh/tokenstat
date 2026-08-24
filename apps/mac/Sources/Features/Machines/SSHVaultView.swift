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
    /// Set only between generating recovery words and confirming them. While
    /// it holds words, they have not been written down yet, and that is the
    /// one vault state that is allowed to look urgent.
    var recovery: String?
    var error: String?
    var enrollmentRequests: [SSHVaultEnrollment] = []

    var created: Bool { status?.created == true }
    var enrolled: Bool { status?.enrolled == true }
    var needsEnrollment: Bool { created && status?.enrolled == false }
    var recordCount: Int { status?.recordCount ?? 0 }
    /// Words generated and not yet confirmed. The only warning here.
    var unconfirmedRecovery: Bool { recovery != nil }

    func refresh() async {
        status = try? await Bridge.sshVaultStatus()
        guard enrolled else {
            enrollmentRequests = []
            return
        }
        enrollmentRequests = (try? await Bridge.sshVaultEnrollmentRequests()) ?? []
    }

    func rotateRecovery() async {
        do {
            recovery = try await Bridge.rotateSSHVaultRecovery().recovery
            status = try await Bridge.sshVaultStatus()
        } catch { self.error = error.localizedDescription }
    }

    func reset() async {
        do {
            try await Bridge.resetSSHVault()
            recovery = nil
            enrollmentRequests = []
            status = try await Bridge.sshVaultStatus()
        } catch { self.error = error.localizedDescription }
    }

    func approve(_ request: SSHVaultEnrollment) async {
        do {
            _ = try await Bridge.approveSSHVaultEnrollment(request)
            enrollmentRequests.removeAll { $0.id == request.id }
        } catch { self.error = error.localizedDescription }
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
                if !vault.enrollmentRequests.isEmpty {
                    Text(vault.enrollmentRequests.count == 1
                        ? "1 device waiting"
                        : "\(vault.enrollmentRequests.count) devices waiting")
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
        if vault.unconfirmedRecovery { return "Recovery words not confirmed" }
        if vault.needsEnrollment { return "Encrypted vault · this device is not enrolled" }
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
    @Bindable var vault: SSHVaultModel
    let tier: String
    let canWrite: Bool

    @State private var showingSetup = false
    @State private var showingRecovery = false
    @State private var confirmingRotation = false
    @State private var confirmingReset = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Encrypted vault").font(.title3.weight(.semibold))
                    Text("Hosts, keys and snippets, readable only by your devices and your 24 recovery words.")
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
                        InlineBanner(text: error, kind: .danger) { vault.error = nil }
                    }
                    if vault.unconfirmedRecovery {
                        action(
                            title: "Confirm your recovery words",
                            detail: "The words have been generated but not written down. They are the only way back in if every enrolled device is lost.",
                            button: "Show words",
                            icon: .reveal,
                            prominent: true
                        ) { showingRecovery = true }
                    }
                    ForEach(vault.enrollmentRequests) { request in
                        action(
                            title: "A device is waiting to join",
                            detail: "Identity \(String(request.publicIdentity.prefix(16)))… Approving lets it decrypt everything in the vault.",
                            button: "Approve",
                            icon: .approve,
                            prominent: true
                        ) { Task { await vault.approve(request) } }
                    }

                    if !vault.created {
                        action(
                            title: "Set up the vault",
                            detail: canWrite
                                ? "Creates a key on this device and 24 recovery words. Nothing leaves the machine unencrypted."
                                : "Creating a vault needs Supporter or above. Existing vaults stay readable.",
                            button: "Set up vault",
                            icon: .security,
                            prominent: true,
                            enabled: canWrite
                        ) { showingSetup = true }
                    } else if vault.needsEnrollment {
                        action(
                            title: "Enrol this device",
                            detail: "This computer cannot read the vault yet. Approve it from a device that is already in, or enter the recovery words here.",
                            button: "Enrol this device",
                            icon: .device,
                            prominent: true
                        ) { showingSetup = true }
                    } else {
                        status
                        if canWrite {
                            action(
                                title: "New recovery words",
                                detail: "Replaces the current 24 words. The old ones stop working as soon as the encrypted update succeeds, so write the new ones down before closing.",
                                button: "New recovery words",
                                icon: .refresh
                            ) { confirmingRotation = true }
                            action(
                                title: "Delete this vault",
                                detail: "Every encrypted secret in it is permanently lost, and other devices will have to set up a new one. This cannot be undone.",
                                button: "Delete vault",
                                icon: .delete,
                                destructive: true
                            ) { confirmingReset = true }
                        } else {
                            Text("Your plan can read this vault but not write to it. Hosts and keys still sync in; changes made here stay on this machine.")
                                .font(.callout).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
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
            "Replace the current recovery words?",
            isPresented: $confirmingRotation,
            titleVisibility: .visible
        ) {
            Button("Generate new recovery words", role: .destructive) { Task { await vault.rotateRecovery() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The current words will stop working as soon as the encrypted update succeeds.")
        }
        .confirmationDialog("Delete this vault?", isPresented: $confirmingReset, titleVisibility: .visible) {
            Button("Delete vault", role: .destructive) { Task { await vault.reset() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Every encrypted SSH secret in the vault is permanently lost. Other devices will need to set up a new vault. This cannot be undone.")
        }
        .onChange(of: vault.recovery) { _, value in if value != nil { showingRecovery = true } }
        .task { await vault.refresh() }
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
