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
        Card(title: L10n.text("common.teams.title"), subtitle: L10n.text("common.teams.hub_detail")) {
            Button(L10n.text("common.teams.manage_teams"), .team) {
                navigation.chooseNavigation(); navigation.restoredRoute = nil
                navigation.destination = .team; navigation.folderID = nil
                dismiss()
            }.buttonStyle(TeamButtonStyle())
        }
    }
}
#endif
