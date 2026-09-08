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
/// on the numbers, which is a real product rather than a failure state. That
/// is the whole reason door four exists on the same screen as the other three
/// instead of being a Skip button in the corner.
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
                    }
                }
                .navigationDestination(for: SetupStep.self) { step in
                    ClientSetupServerStep(step: step, model: model, library: library, path: $path)
                }
        }
        .tint(Theme.accent)
        .task {
            await model.prepare(library: library)
            await account.load()
        }
        .environment(account)
    }

    // MARK: - D0, the question

    private var doors: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                header
                door(
                    title: "On a server I have",
                    body: "Connect over SSH and set it up. tokenstat installs itself, "
                        + "signs the machine in and comes back paired.",
                    requirement: paywalled ? "Reaching it needs patron" : nil,
                    icon: .connect
                ) {
                    path = [.where]
                }
                door(
                    title: "On my Mac",
                    body: "Install the desktop app on the computer you work on, sign in "
                        + "to this account, and let this phone in.",
                    requirement: nil,
                    icon: .device
                ) {
                    navigation.destination = .machines
                    dismiss()
                }
                door(
                    title: "Just my numbers",
                    body: "Skip all of this. Usage from every machine you already have "
                        + "keeps arriving on its own.",
                    requirement: nil,
                    icon: .home
                ) {
                    dismiss()
                }
                Text(
                    "Cloud providers arrive next. Until then, import a machine into your "
                    + "SSH library and use the first door."
                )
                .font(ClientType.caption)
                .foregroundStyle(.secondary)
                .padding(.top, Theme.Space.xs)
            }
            .padding(Theme.Space.m)
        }
        .background(Theme.background)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            ClientEmptyArt(kind: .noMachine)
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

    /// Doors two and three need the tunnel, which is patron and up. Said on the
    /// door rather than after twenty minutes of SSH.
    private var paywalled: Bool {
        if let remote = account.account?.canRemote { return !remote }
        return !["patron", "legend"].contains(account.account?.tier?.lowercased())
    }

    private func door(
        title: String,
        body: String,
        requirement: String?,
        icon: ActionIcon,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: Theme.Space.m) {
                Image(systemName: icon.symbol)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 26, height: 26)
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
                    .font(.system(size: 13, weight: .semibold))
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

/// The six steps of door two, in the order they have to happen.
///
/// A step per screen rather than one long form, because each of them can fail
/// on its own and each failure has its own thing to say. Trusting a host key
/// in particular is the one place where a mistake is permanent, so it is not a
/// row inside somebody else's screen.
enum SetupStep: Hashable {
    case `where`
    case credential
    case fingerprint
    case check
    case install
    case finish
    /// The install line, for somebody who would rather run it themselves.
    case byHand
}

#endif
