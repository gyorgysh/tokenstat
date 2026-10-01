// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

import SwiftUI

// The client is iOS and iPadOS only.
#if !os(macOS)

/// What to do next, on a phone whose account has nothing on it yet.
///
/// Signing in and finding four screens that each say "nothing recorded yet" is
/// four dead ends and no order. This is the one card that says which end to
/// start at, and it leaves the moment the first numbers land.
///
/// **There is an install step now, and it is not a download link.** Nobody
/// installs a Mac app from an iPhone, which is why this card used to say the
/// product started somewhere else. It no longer has to: a phone can give
/// tokenstat a server over SSH and get back a machine that runs agents. So
/// step two is the wizard, and the Mac remains the first door inside it.
///
/// Signing in is behind us by the time Home draws at all: `ClientRootView`
/// shows `ClientLoginView` until it is done. So step one arrives struck
/// through, which is worth more than hiding it: the rail opens already part
/// finished instead of opening as a list of chores.
struct ClientGettingStarted: View {
    @Environment(AccountModel.self) private var account
    @Environment(ClientNavigationModel.self) private var navigation
    @State private var showSetup = false

    /// The account's own name for this phone, when it has one. "Signed in" is
    /// true of somebody's account, and naming the device makes it true of the
    /// thing in their hand.
    private var phoneName: String? {
        account.account?.machines.first { !$0.isHost }?.displayName
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            header
            GettingStartedRail(steps: steps)
            waiting
        }
        .padding(Theme.Space.m)
        .cardSurface()
        .fullScreenCover(isPresented: $showSetup) {
            ClientSetupWizard()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            ClientEmptyArt(kind: .getCounting)
                .frame(maxWidth: .infinity)
                .padding(.bottom, 2)
            ClientSectionTitle(title: L10n.text("apple.clientgettingstarted.get_tokenstat_counting.331454ea"), mark: "mark_activity")
            Text(
                L10n.text("apple.clientgettingstarted.tokenstat_counts_on_the_computers_you_work.9e9d0969")
            )
            .font(ClientType.label)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var steps: [GettingStartedStep] {
        [
            GettingStartedStep(
                number: 1,
                title: L10n.text("apple.clientgettingstarted.signed_in.ca566c89"),
                body: phoneName.map { L10n.text("apple.clientgettingstarted.this_device_is_on_your_account_as_0.852b249c", "\($0)") }
                    ?? L10n.text("apple.clientgettingstarted.this_device_is_on_your_account.0d089d05"),
                state: .done
            ),
            GettingStartedStep(
                number: 2,
                title: L10n.text("apple.clientgettingstarted.connect_a_machine.d4f654b6"),
                body: L10n.text("apple.clientgettingstarted.a_mac_you_already_work_on_or_a_server_toke.d55e3d18"),
                state: .now,
                actionTitle: L10n.text("apple.clientgettingstarted.set_up_a_machine.43e10e13"),
                actionIcon: .connect,
                action: { showSetup = true }
            ),
        ]
    }

    /// Step three has no instruction, so it is not a step. It is the picture of
    /// what arrives once step two is done, which is the honest way to draw
    /// waiting: the grid appears where the real one will be.
    private var waiting: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            ThemeRule()
            Text(L10n.text("apple.clientgettingstarted.then_there_is_nothing_left_to_run.9a5af1d1"))
                .font(ClientType.label.weight(.semibold))
            Text(L10n.text("apple.clientgettingstarted.the_first_usage_update_arrives_on_its_own.771c0d1b"))
                .font(ClientType.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            GettingStartedGhostGrid(weeks: 16, alignment: .center)
                .padding(.top, Theme.Space.xs)
        }
        .padding(.top, Theme.Space.xs)
    }
}

#endif
