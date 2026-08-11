// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

import SwiftUI

// The client is iOS and iPadOS only.
#if !os(macOS)

/// Folders on a machine that is awake, and later the sessions running in them.
///
/// **This is the machine plane, and it is the only tab on it.** Home, Insights
/// and the account heatmap all work with every laptop asleep, because they read
/// what the account already holds. Nothing here does: a folder list, a branch
/// name and a running session exist on one machine, and if that machine is
/// closed the honest answer is to say so.
///
/// The transport is not what is missing. `docs/remote-transport.md` is built:
/// direct machine to machine, a blind tunnel, `remote.call` forwarding a
/// dispatch to another machine, and remote pty by polling. What is missing is
/// the client half on iOS, which is P5 in `docs/mobile-app.md`.
///
/// So this screen exists now, empty and honest, rather than after: a tab that
/// says "not yet, and here is what it will need" is worth more than a tab that
/// is not there, because the question people arrive with is "can I reach my
/// Mac from this", and an app with no answer at all reads as no.
///
/// Two rules it inherits and does not get to bend:
/// - **Nothing mutates on a timer.** Every write runs because a person pressed
///   a button, the same line `CLAUDE.md` draws for the desktop. There is no
///   "start a session when the app opens".
/// - **Degrade to the account's cached answer, never to blank.** "Asleep, last
///   seen two hours ago" beats a spinner that resolves into nothing.
struct ClientWorkspacesView: View {
    @Environment(AccountModel.self) private var account

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                ClientEmptyState(
                    kind: .nothingYet,
                    title: "Reaching your devices",
                    message: "Folders and running sessions on a device that is awake. "
                        + "The connection this needs is built, the phone's half is not."
                )

                if deviceCount > 0 {
                    VStack(alignment: .leading, spacing: Theme.Space.s) {
                        Text("On your account")
                            .font(ClientType.sectionTitle)
                        Text("\(deviceCount) \(deviceCount == 1 ? "device" : "devices") "
                            + "sync to this account. Their workspaces appear here once "
                            + "this phone can reach them.")
                            .font(ClientType.label)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Theme.Space.m)
                    .cardSurface()
                }
            }
            .padding(.horizontal, Theme.Space.m)
            .padding(.top, Theme.Space.s)
            .padding(.bottom, 96)
        }
        .background(Theme.background)
    }

    private var deviceCount: Int {
        account.account?.machines.count ?? 0
    }
}

#endif
