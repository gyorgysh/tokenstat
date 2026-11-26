// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
#if !os(macOS)
import SwiftUI

struct ClientTeamView: View {
    @Environment(TeamStore.self) private var teams
    @Environment(AccountModel.self) private var account
    @Environment(\.openClientAccount) private var openAccount
    var body: some View {
        TeamManagementView(store: teams, canCreateOrganization: account.account?.tier?.lowercased() == "legend", onAccount: openAccount, transcript: TeamTranscriptContent.render)
    }
}

/// Account settings link to the collaboration destination; organization
/// navigation belongs inside Team and never pretends to switch accounts.
struct ClientTeamAccountLink: View {
    @Environment(ClientNavigationModel.self) private var navigation
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        // One row, like the profile above it: the whole card opens Team.
        Button {
            navigation.chooseNavigation(); navigation.restoredRoute = nil
            navigation.destination = .team; navigation.folderID = nil
            dismiss()
        } label: {
            HStack(spacing: Theme.Space.m) {
                VStack(alignment: .leading, spacing: Theme.Space.s) {
                    HStack(spacing: Theme.Space.s) {
                        Image(systemName: ActionIcon.team.symbol)
                            .font(Theme.font(17, weight: .semibold))
                            .foregroundStyle(Theme.accent)
                            .frame(width: 22, height: 22)
                            .accessibilityHidden(true)
                        Text(L10n.text("common.teams.title"))
                            .font(ClientType.sectionTitle)
                            .foregroundStyle(.primary)
                    }
                    Text(L10n.text("common.teams.hub_detail"))
                        .font(ClientType.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                RowChevron()
            }
            .padding(.vertical, Theme.Space.s)
            .contentShape(.rect)
        }
        .buttonStyle(RowFeedbackStyle(bleed: Theme.Space.s, radius: 12))
        .accessibilityHint(L10n.text("common.teams.manage_teams"))
        .padding(Theme.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
    }
}
#endif
