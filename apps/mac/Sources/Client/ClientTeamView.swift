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

/// Lives in the existing account sheet. Choosing a directory does not change
/// the login lifetime, dismiss a chat, or reconnect to another computer.
struct ClientTeamAccountScope: View {
    @Environment(TeamStore.self) private var teams
    @Environment(ClientNavigationModel.self) private var navigation
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        Card(title: L10n.text("common.teams.scope")) {
            Menu {
                Button { teams.select(nil) } label: {
                    if teams.selectedOrganizationId == nil { Label(L10n.text("common.teams.personal"), systemImage: "checkmark") }
                    else { Text(L10n.text("common.teams.personal")) }
                }
                if teams.phase == .ready {
                    ForEach(teams.organizations) { organization in
                        Button { teams.select(organization) } label: {
                            if teams.selectedOrganizationId == organization.id { Label(organization.name, systemImage: "checkmark") }
                            else { Text(organization.name) }
                        }
                    }
                    if let selected = teams.selectedOrganization, !teams.organizations.contains(where: { $0.id == selected.id }) {
                        Button { teams.select(selected) } label: { Label(selected.name, systemImage: "checkmark") }
                    }
                }
            } label: {
                HStack {
                    Label(teams.selectedOrganization?.name ?? L10n.text("common.teams.personal"), systemImage: teams.selectedOrganization == nil ? "person.crop.circle" : "person.2")
                    Spacer(minLength: Theme.Space.s)
                    Image(systemName: "chevron.up.chevron.down").accessibilityHidden(true)
                }.font(Theme.body).frame(minHeight: Theme.Control.heightComfortable).contentShape(.rect)
            }
            .accessibilityLabel(L10n.text("common.teams.scope"))
            .accessibilityValue(teams.selectedOrganization?.name ?? L10n.text("common.teams.personal"))
            Button(L10n.text("common.teams.manage_teams"), .team) {
                navigation.chooseNavigation(); navigation.restoredRoute = nil
                navigation.destination = .team; navigation.folderID = nil
                dismiss()
            }.buttonStyle(TeamButtonStyle())
        }
    }
}
#endif
