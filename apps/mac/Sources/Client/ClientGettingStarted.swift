// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available: source sharing and own builds are permitted.
// Store and commercial distribution of builds is reserved. See LICENSE.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

import SwiftUI

#if !os(macOS)

struct ClientGettingStarted: View {
    @Environment(AccountModel.self) private var account
    @Environment(ClientNavigationModel.self) private var navigation
    @Environment(ClientSetupSession.self) private var setup

    private var phoneName: String? {
        guard let id = account.account?.thisMachineID, !id.isEmpty else { return nil }
        return account.account?.machines.first { $0.machineID == id }?.displayName
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            header
            GettingStartedRail(steps: steps)
            waiting
        }
        .padding(Theme.Space.m)
        .cardSurface()
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
                action: { setup.open() }
            ),
        ]
    }

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
