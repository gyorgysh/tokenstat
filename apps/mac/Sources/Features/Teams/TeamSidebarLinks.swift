// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import SwiftUI

/// Additive destinations below the repository tree; project rows keep their
/// original ownership and continue to open the same local or remote chat.
struct TeamSidebarLinks: View {
    @Bindable var store: TeamStore
    let isTeamSelected: Bool
    let open: (TeamSection) -> Void
    var openProjects: (() -> Void)? = nil
    private var visible: Bool {
        store.owner != nil
    }
    var body: some View {
        if visible {
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                Text(store.selectedOrganization?.name ?? L10n.text("common.teams.title"))
                    .font(Theme.callout.weight(.semibold)).foregroundStyle(.secondary)
                    .lineLimit(2).padding(.horizontal, Theme.Space.m).padding(.top, Theme.Space.l)
                    .accessibilityAddTraits(.isHeader)
                if let openProjects {
                    Button(action: openProjects) {
                        HStack(spacing: Theme.Space.s) {
                            Image(systemName: ActionIcon.team.symbol).frame(width: 18).accessibilityHidden(true)
                            Text(L10n.text("common.teams.shared_projects")).lineLimit(2)
                            Spacer(minLength: 0)
                        }.font(Theme.body).padding(.horizontal, Theme.Space.m).padding(.vertical, Theme.Space.s)
                            .frame(minHeight: Theme.Control.heightComfortable).contentShape(.rect)
                            .background(isTeamSelected && store.browsingProjects ? Theme.rowSelected : .clear, in: RoundedRectangle(cornerRadius: 8))
                    }.buttonStyle(.plain).padding(.horizontal, Theme.Space.xs)
                        .accessibilityIdentifier("team.projects.sidebar")
                }
                if store.selectedOrganization != nil && store.phase == .ready {
                    row(.chats)
                    row(.repositories)
                    row(.members)
                    if store.selectedOrganization?.role.canManage == true { row(.invitations) }
                    row(.settings)
                } else { row(.overview) }
            }
            .padding(.bottom, Theme.Space.s)
        }
    }
    private func row(_ section: TeamSection) -> some View {
        Button { open(section) } label: {
            HStack(spacing: Theme.Space.s) {
                Image(systemName: section.symbol).frame(width: 18).accessibilityHidden(true)
                Text(section.label).lineLimit(2)
                Spacer(minLength: 0)
                if section == .overview, !store.inbox.isEmpty { Text(String(store.inbox.count)).foregroundStyle(.secondary) }
            }
            .font(Theme.body)
            .foregroundStyle(isTeamSelected && !store.browsingProjects && store.section == section ? TeamColors.action : Color.primary)
            .padding(.horizontal, Theme.Space.m).padding(.vertical, Theme.Space.s)
            .frame(minHeight: Theme.Control.heightComfortable)
            .background(isTeamSelected && !store.browsingProjects && store.section == section ? Theme.rowSelected : .clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, Theme.Space.xs)
        .accessibilityAddTraits(isTeamSelected && !store.browsingProjects && store.section == section ? .isSelected : [])
    }
}
#if os(macOS)
@MainActor
enum TeamScopeMenuItems {
    static func make(store: TeamStore, manage: @escaping () -> Void) -> [NativeMenuItem] {
        var items: [NativeMenuItem] = [
            .heading(L10n.text("common.teams.scope")),
            NativeMenuItem(L10n.text("common.teams.personal"), icon: .account, isSelected: store.selectedOrganizationId == nil) { store.select(nil) },
        ]
        if store.phase == .ready {
            items += store.organizations.map { organization in
                NativeMenuItem(organization.name, icon: .team, isSelected: store.selectedOrganizationId == organization.id) { store.select(organization) }
            }
            if let selected = store.selectedOrganization, !store.organizations.contains(where: { $0.id == selected.id }) {
                items.append(NativeMenuItem(selected.name, icon: .team, isSelected: true) { store.select(selected) })
            }
        }
        items += [.separator, NativeMenuItem(L10n.text("common.teams.manage_teams"), icon: .team, action: manage), .separator]
        return items
    }
}
#endif
