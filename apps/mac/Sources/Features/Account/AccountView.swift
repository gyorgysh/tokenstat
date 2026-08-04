// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

import SwiftUI

struct AccountView: View {
    @Bindable var model: AccountModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.l) {
                if let message = model.errorMessage {
                    Banner(text: message, tint: .orange, symbol: "exclamationmark.triangle.fill")
                }
                if let summary = model.lastSyncSummary {
                    Banner(text: summary, tint: Theme.secondary, symbol: "checkmark.circle.fill")
                }

                if let device = model.pendingLogin {
                    SignInCode(device: device) { model.cancelSignIn() }
                } else if model.signedIn, let account = model.account {
                    signedIn(account)
                } else if model.account != nil {
                    signedOut
                } else {
                    // Neither state is known yet. Showing "sign in" here would
                    // flash the wrong answer on every launch.
                    ProgressView().frame(maxWidth: .infinity)
                }

                privacyNote
            }
            .padding(Theme.Space.l)
        }
        .navigationTitle("Account")
        .task { if model.account == nil { await model.load() } }
    }

    private var signedOut: some View {
        Card(
            title: "Not signed in",
            subtitle: "Everything works without an account. Signing in only adds the option to publish."
        ) {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                Text("""
                An account lets you publish a profile page and see usage from \
                all your machines in one place. Only aggregate counters are \
                eligible to be sent.
                """)
                .font(.callout)
                .foregroundStyle(.secondary)

                Button {
                    model.signIn()
                } label: {
                    Label("Sign in to tokenstat.ai", systemImage: "person.crop.circle")
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
            }
        }
    }

    private func signedIn(_ account: Account) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            Card(title: "Signed in", subtitle: account.host) {
                HStack(alignment: .top, spacing: Theme.Space.l) {
                    Stat(label: "Handle", value: account.handle.map { "@\($0)" } ?? "unknown")
                    Stat(label: "Plan", value: account.tier?.capitalized ?? "free")
                    Stat(
                        label: "Last sync",
                        value: formatServerDate(account.lastSyncAt) ?? "never"
                    )
                }

                HStack(spacing: Theme.Space.s) {
                    Button {
                        Task { await model.sync() }
                    } label: {
                        if model.isSyncing {
                            ProgressView().controlSize(.small)
                        } else {
                            Label("Sync now", systemImage: "arrow.up.circle")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.accent)
                    .disabled(model.isSyncing)

                    Button("Sign out") {
                        Task { await model.signOut() }
                    }
                    .disabled(model.isSyncing)
                }
                .padding(.top, Theme.Space.xs)
            }

            Card(
                title: "Machines",
                subtitle: "Every machine that has synced to this account"
            ) {
                if account.machines.isEmpty {
                    Text("Nothing has synced yet.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    VStack(spacing: Theme.Space.s) {
                        ForEach(account.machines) { machine in
                            HStack(spacing: Theme.Space.m) {
                                Image(systemName: "desktopcomputer")
                                    .foregroundStyle(.secondary)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(machine.displayName)
                                        .font(.callout)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                    if let subtitle = machine.subtitle {
                                        Text(subtitle)
                                            .font(.caption)
                                            .foregroundStyle(.tertiary)
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                    }
                                }
                                Spacer()
                                Text(formatServerDate(machine.lastSyncAt) ?? "never synced")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
    }

    /// The claim, stated where someone is deciding whether to connect an
    /// account. This is the moment it matters, not the marketing page.
    private var privacyNote: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            Label("What syncing sends", systemImage: "lock.shield")
                .font(.callout.weight(.medium))
            Text("""
            Aggregate counts per day, tool and model, and project names replaced \
            by salted hashes. Prompts, replies, file contents, file paths and \
            session ids are never eligible.
            """)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(Theme.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.2), in: RoundedRectangle(cornerRadius: Theme.cardRadius))
    }
}

/// The device code, shown while waiting for the browser half of sign-in.
private struct SignInCode: View {
    var device: DeviceLogin
    var onCancel: () -> Void

    var body: some View {
        Card(
            title: "Confirm in your browser",
            subtitle: "A page should have opened at \(device.verificationURI)"
        ) {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                Text(device.userCode)
                    .font(.system(size: 30, weight: .semibold, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(.vertical, Theme.Space.s)
                    .padding(.horizontal, Theme.Space.m)
                    .background(
                        .quaternary.opacity(0.4),
                        in: RoundedRectangle(cornerRadius: Theme.Space.s)
                    )

                Text("Check that the page shows this code, then approve it there.")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                HStack(spacing: Theme.Space.s) {
                    ProgressView().controlSize(.small)
                    Text("Waiting for confirmation…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Cancel", action: onCancel)
                }
            }
        }
    }
}
