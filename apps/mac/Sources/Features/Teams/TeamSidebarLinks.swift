// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import SwiftUI

/// Compact clients have one Team destination. Its sections live in the
/// content's existing picker rather than duplicating them in the sidebar.
struct TeamSidebarLinks: View {
    @Bindable var store: TeamStore
    let isTeamSelected: Bool
    let open: (TeamSection) -> Void
    var body: some View {
        if store.owner != nil {
            Button { open(store.section) } label: {
                HStack(spacing: Theme.Space.s) {
                    Image(systemName: ActionIcon.team.symbol).frame(width: 18).accessibilityHidden(true)
                    Text(L10n.text("common.teams.title")).lineLimit(2)
                    Spacer(minLength: 0)
                }
                .font(Theme.body)
                .foregroundStyle(isTeamSelected ? TeamColors.action : Color.primary)
                .padding(.horizontal, Theme.Space.m).padding(.vertical, Theme.Space.s)
                .frame(minHeight: Theme.Control.heightComfortable)
                .background(isTeamSelected ? Theme.rowSelected : .clear, in: RoundedRectangle(cornerRadius: 8))
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, Theme.Space.xs)
            .accessibilityIdentifier("team.sidebar.open")
            .accessibilityAddTraits(isTeamSelected ? .isSelected : [])
        }
    }
}
