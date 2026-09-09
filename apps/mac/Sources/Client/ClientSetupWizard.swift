// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

import SwiftUI

#if !os(macOS)

/// How somebody gets a machine, asked once and answerable forever after.
///
/// Not a modal that traps anybody: every step can be left, and leaving lands
/// on the numbers, which is a real product rather than a failure state. Skip
/// sits below the three doors as a quiet button rather than a fourth card,
/// so it never reads as a fourth way to set up.
struct ClientSetupWizard: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AccountModel.self) private var account
    @Environment(ClientNavigationModel.self) private var navigation

    @State private var model = ClientSetupModel()
    @State private var library = SSHLibraryModel()
    @State private var path: [SetupStep] = []

    var body: some View {
        NavigationStack(path: $path) {
            doors
                .navigationTitle("Set up a machine")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Close") { dismiss() }
                            // Escape leaves, for somebody on a keyboard. The
                            // sheet is dismissible by gesture already, and a
                            // keyboard had no equivalent.
                            .keyboardShortcut(.cancelAction)
                            .accessibilityIdentifier("setup.close")
                    }
                }
                .navigationDestination(for: SetupStep.self) { step in
                    ClientSetupServerStep(step: step, model: model, library: library, path: $path, onFinish: { dismiss() })
                }
        }
        .tint(Theme.accent)
        .task {
            await model.prepare(library: library)
            await account.load()
        }
        .onChange(of: account.account) { _, now in
            // A different account is a different setup. Land back on the doors
            // and load that account's own draft, if it has one.
            guard model.accountChanged(now) else { return }
            path = []
            Task { await model.prepare(library: library) }
        }
        .onDisappear { model.cancelWork() }
        .environment(account)
    }

    // MARK: - D0, the question

    private var doors: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                header
                // The doors had nowhere to say anything, so a refused resume
                // or a failed prepare was a button that did nothing.
                if let failure = model.failure {
                    SetupFailureBanner(
                        failure: failure,
                        onDismiss: { model.failure = nil },
                        onRecover: { recover($0, model: model, path: $path) }
                    )
                }
                if let draft = model.savedDraft { resumeCard(draft) }
                // The computer first: no token, no rental, nothing to buy.
                // The doors below it both assume a server.
                door(
                    title: "On my Mac",
                    body: "Install the desktop app on the computer you work on, sign in "
                        + "to this account, and let this device in.",
                    requirement: nil,
                    symbol: "laptopcomputer"
                ) {
                    path = [.mac]
                }
                door(
                    title: "On a server I have",
                    body: "Connect over SSH and set it up. tokenstat installs itself, "
                        + "signs the machine in and comes back paired.",
                    requirement: paywalled ? "Reaching it needs patron" : nil,
                    symbol: "server.rack"
                ) {
                    path = [.where]
                }
                door(
                    title: "On a cloud machine",
                    body: "A VPS or a dedicated server. Import the ones you have, or find "
                        + "out what to rent if you have none yet.",
                    requirement: paywalled ? "Reaching it needs patron" : nil,
                    symbol: "cloud.fill"
                ) {
                    path = [.cloud]
                }
                // Leaving, without pretending it is a setup choice. A fourth card
                // wore the same surface as the three doors and read as a fourth
                // way to set up. A quiet bordered button says what it is.
                VStack(spacing: Theme.Space.s) {
                    Button("Skip for now", .next) { dismiss() }
                        .buttonStyle(.bordered)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .accessibilityIdentifier("setup.skip")
                    Text("Go to your account and your numbers. Usage from machines you "
                        + "already have keeps arriving on its own, and a machine can be "
                        + "connected later from Devices.")
                        .font(ClientType.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity)
                }
                .padding(.top, Theme.Space.xs)
                Text(
                    "Nothing here is permanent. Every door can be left, and leaving lands on "
                    + "your numbers, which keep arriving whatever you choose."
                )
                .font(ClientType.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, Theme.Space.xs)
            }
            .padding(Theme.Space.m)
        }
        .background(Theme.background)
    }

    /// Setup left half-finished is the normal case on a phone, not an error.
    ///
    /// Continuing never repeats a remote step: it reopens where the draft
    /// stopped and asks the server what is actually true. Starting over is
    /// offered beside it, and says plainly that it changes nothing on the
    /// server, because that is the fear that makes people leave this screen.
    private func resumeCard(_ draft: ClientSetupDraft) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack(spacing: Theme.Space.s) {
                Image(systemName: "arrow.trianglehead.clockwise")
                    .font(Theme.fixed(15, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                    .accessibilityHidden(true)
                Text("Setup in progress")
                    .font(ClientType.caption.weight(.semibold))
                    .foregroundStyle(Theme.accent)
                    .textCase(.uppercase)
                    .kerning(0.6)
            }
            Text(draft.machineName)
                .font(Theme.headline)
            Text(draft.milestone.summary)
                .font(ClientType.label)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: Theme.Space.s) {
                Button("Continue setup", .next) {
                    if let step = model.resume(library: library) { path = [step] }
                }
                .clientProminentStyle()
                .accessibilityIdentifier("setup.resume")
                Button("Start over", .restore) {
                    if model.startNewSetup() { path = [.where] }
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("setup.startOver")
            }
            .padding(.top, Theme.Space.xs)
            Text("Starting over forgets this progress on this device. Nothing on the server is removed.")
                .font(ClientType.caption)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(Theme.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.panel, in: .rect(cornerRadius: Theme.cardRadius))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.cardRadius)
                .strokeBorder(Theme.accent.opacity(0.4), lineWidth: 1)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            ClientEmptyArt(kind: .connect)
                .frame(maxWidth: .infinity)
            Text("How do you want to work?")
                .font(Theme.title.weight(.semibold))
            Text(
                "tokenstat runs agents on a machine that stays on. It can be a computer "
                + "you own or a server you rent."
            )
            .font(ClientType.body)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.bottom, Theme.Space.xs)
    }

    /// The server and cloud doors need the tunnel, which is patron and up.
    /// Said on the door rather than after twenty minutes of SSH.
    private var paywalled: Bool {
        if let remote = account.account?.canRemote { return !remote }
        return !["patron", "legend"].contains(account.account?.tier?.lowercased())
    }

    private func door(
        title: String,
        body: String,
        requirement: String?,
        symbol: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: Theme.Space.m) {
                Image(systemName: symbol)
                    .font(Theme.fixed(25, weight: .medium))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 54, height: 54)
                    .background(Theme.accent.opacity(0.09), in: RoundedRectangle(cornerRadius: 15))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: Theme.Space.xs) {
                    Text(title).font(Theme.headline)
                    Text(body)
                        .font(ClientType.label)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                    if let requirement {
                        Text(requirement)
                            .font(ClientType.caption.weight(.medium))
                            .foregroundStyle(Theme.accent)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(Theme.fixed(13, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .padding(.top, 4)
            }
            .padding(Theme.Space.m)
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardSurface()
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
    }
}

#endif
