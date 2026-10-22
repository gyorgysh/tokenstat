// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import SwiftUI

struct TeamSharedProjectSettings: View {
    @Bindable var store: TeamStore
    let context: TeamMutationContext
    let repository: TeamRepository
    let checkout: TeamCheckout
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        ThemedSheet(title: L10n.text("common.teams.project_settings"), subtitle: repository.name, icon: .settings, scrolls: true, onClose: { dismiss() }) {
            VStack(alignment: .leading, spacing: Theme.Space.l) {
                Text(L10n.text("common.teams.project_settings_detail")).font(Theme.body).foregroundStyle(.secondary)
                TeamLaneSettings(store: store, context: context, checkoutId: checkout.id)
                ThemeRule()
                TeamAgentGrants(store: store, context: context, repository: repository, checkoutId: checkout.id)
            }
        } actions: {
            Spacer()
            Button(L10n.text("common.close"), .dismiss) { dismiss() }.buttonStyle(TeamButtonStyle()).keyboardShortcut(.cancelAction)
        }
    }
}
