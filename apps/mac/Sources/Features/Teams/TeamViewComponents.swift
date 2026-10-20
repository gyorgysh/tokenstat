// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import SwiftUI

enum TeamColors {
    static let action = Color.adaptive(light: Color(red: 0x5C / 255, green: 0x2B / 255, blue: 0xD9 / 255), dark: Color(red: 0xA7 / 255, green: 0x8B / 255, blue: 0xFA / 255))
    static let destructive = Color.adaptive(light: Color(red: 0xB4 / 255, green: 0x23 / 255, blue: 0x18 / 255), dark: Color(red: 1, green: 0x8A / 255, blue: 0x80 / 255))
    // Keep the app's amber hue, with enough contrast for small text on light panels.
    static let warning = Color.adaptive(light: Color(red: 0x80 / 255, green: 0x54 / 255, blue: 0x0A / 255), dark: Theme.warning)
}

extension TeamOrganizationRole {
    var label: String {
        switch self {
        case .owner: L10n.text("common.teams.owner")
        case .admin: L10n.text("common.teams.admin")
        case .member: L10n.text("common.teams.member")
        }
    }
}
extension TeamRepositoryRole {
    var label: String {
        switch self {
        case .viewer: L10n.text("common.teams.viewer")
        case .contributor: L10n.text("common.teams.contributor")
        case .maintainer: L10n.text("common.teams.maintainer")
        }
    }
    var detail: String {
        switch self {
        case .viewer: L10n.text("common.teams.viewer_detail")
        case .contributor: L10n.text("common.teams.contributor_detail")
        case .maintainer: L10n.text("common.teams.maintainer_detail")
        }
    }
}
extension TeamSection {
    var label: String {
        switch self {
        case .overview: L10n.text("common.teams.title")
        case .members: L10n.text("common.teams.members")
        case .invitations: L10n.text("common.teams.invitations")
        case .repositories: L10n.text("common.teams.repositories")
        case .settings: L10n.text("common.teams.organization_settings")
        }
    }
    var symbol: String {
        switch self {
        case .overview, .members: "person.2"
        case .invitations: "person.badge.plus"
        case .repositories: "folder"
        case .settings: "gearshape"
        }
    }
}
struct TeamPersonLabel: View {
    let id: String
    let name: String
    let handle: String?
    let avatar: String?
    let owner: TeamAccountOwner?
    var body: some View {
        HStack(spacing: Theme.Space.m) {
            Avatar(url: teamAvatarURL(avatar, owner: owner)?.absoluteString, name: name, handle: handle, size: 32, tint: Avatar.tint(for: id))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(name).font(Theme.body.weight(.medium)).lineLimit(2)
                if let handle { Text("@\(handle)").font(Theme.callout).foregroundStyle(.secondary).lineLimit(1) }
            }
        }
        .accessibilityElement(children: .combine)
    }
}
struct TeamRoleBadge: View {
    let text: String
    var body: some View {
        Text(text).font(Theme.callout).foregroundStyle(TeamColors.action)
            .padding(.horizontal, Theme.Space.s).padding(.vertical, Theme.Space.xs)
            .background(Theme.rowHighlight, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}
struct TeamNotice: View {
    let message: String
    var warning = false
    var body: some View {
        HStack(alignment: .top, spacing: Theme.Space.s) {
            Image(systemName: warning ? "exclamationmark.circle" : "info.circle")
                .foregroundStyle(warning ? TeamColors.warning : TeamColors.action)
            Text(message).font(Theme.callout).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(Theme.Space.m)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Theme.border, lineWidth: 1))
        .accessibilityElement(children: .combine)
    }
}
/// Matches the app's colors while preserving a comfortable target on touch
/// platforms and allowing a long translated label to wrap.
struct TeamButtonStyle: ButtonStyle {
    var primary = false
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.callout.weight(.semibold))
            .multilineTextAlignment(.center)
            .padding(.horizontal, Theme.Space.m)
            .frame(minHeight: Theme.Control.heightComfortable)
            .labelStyle(ActionLabelStyle())
            .foregroundStyle(configuration.role == .destructive ? TeamColors.destructive : TeamColors.action)
            .background(primary ? Theme.accentSoft : Theme.controlSeat,
                in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(primary ? Theme.accent.opacity(0.35) : Theme.border, lineWidth: 1))
            .contentShape(.rect)
            .opacity(enabled ? (configuration.isPressed ? 0.8 : 1) : 0.45)
    }
}
struct TeamLoadingView: View {
    var body: some View {
        VStack(spacing: Theme.Space.m) {
            ProgressView().controlSize(.small)
            Text(L10n.text("common.teams.loading")).font(Theme.callout).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }
}
struct TeamRowButtonStyle: ButtonStyle {
    var detail: String? = nil
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: Theme.Space.m) {
            configuration.label.font(Theme.body.weight(.medium)).labelStyle(.titleAndIcon)
            Spacer(minLength: Theme.Space.m)
            if let detail { TeamRoleBadge(text: detail) }
            Image(systemName: ActionIcon.next.symbol).foregroundStyle(.secondary).accessibilityHidden(true)
        }
        .padding(.horizontal, Theme.Space.m).padding(.vertical, Theme.Space.s)
        .frame(minHeight: Theme.Control.heightComfortable, alignment: .leading)
        .background(configuration.isPressed ? Theme.rowHighlight : Theme.panel)
        .contentShape(.rect)
    }
}
struct TeamSectionHeader<Actions: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder let actions: () -> Actions
    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: Theme.Space.m) { heading; Spacer(minLength: Theme.Space.l); actions() }
            VStack(alignment: .leading, spacing: Theme.Space.m) { heading; actions() }
        }
        .padding(Theme.Space.l)
    }
    private var heading: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            Text(title).font(Theme.title2.weight(.semibold)).accessibilityAddTraits(.isHeader)
            Text(subtitle).font(Theme.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

enum TeamSheet: Identifiable {
    case authorize
    case create(TeamMutationContext)
    case invite(TeamMutationContext)
    case memberRole(TeamMutationContext, TeamMember)
    case remove(TeamMutationContext, TeamMember)
    case accept(TeamMutationContext, TeamInvitation)
    case invitationAction(TeamMutationContext, TeamInvitation, renewing: Bool)
    case repository(TeamMutationContext)
    case access(TeamMutationContext, TeamRepository)
    case rename(TeamMutationContext)
    case transfer(TeamMutationContext)
    case ownershipDecision(TeamMutationContext, TeamOwnershipRequest, cancelling: Bool)
    case delete(TeamMutationContext)
    case leave(TeamMutationContext)
    var id: String {
        switch self {
        case .authorize: "authorize"
        case .create: "create"
        case .invite: "invite"
        case let .memberRole(_, member): "role:\(member.id)"
        case let .remove(_, member): "remove:\(member.id)"
        case let .accept(_, invitation): "accept:\(invitation.id)"
        case let .invitationAction(_, invitation, renewing): "invitation:\(invitation.id):\(renewing)"
        case .repository: "repository"
        case let .access(_, repository): "access:\(repository.id)"
        case .rename: "rename"
        case .transfer: "transfer"
        case let .ownershipDecision(_, request, cancelling): "ownership:\(request.requestId ?? "legacy"):\(cancelling)"
        case .delete: "delete"
        case .leave: "leave"
        }
    }
}
