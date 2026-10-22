// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import SwiftUI

struct TeamTranscriptRenderedKey: PreferenceKey {
    static let defaultValue: UUID? = nil
    static func reduce(value: inout UUID?, nextValue: () -> UUID?) { value = nextValue() ?? value }
}
struct TeamChatReadingKey: PreferenceKey {
    static let defaultValue = false
    static func reduce(value: inout Bool, nextValue: () -> Bool) { value = value || nextValue() }
}

private struct TeamAvatarOwnerKey: EnvironmentKey { static let defaultValue: TeamAccountOwner? = nil }
/// A file from someone else's computer. Name and type are the ones that
/// computer derived from the stored file, never the history's own label.
struct TeamAttachmentFile: Sendable { let name: String; let mediaType: String?; let data: Data }
typealias TeamAttachmentLoader = @MainActor @Sendable (String) async throws -> TeamAttachmentFile
private struct TeamAttachmentLoaderKey: EnvironmentKey { static let defaultValue: TeamAttachmentLoader? = nil }
private struct TeamCommentStorageKey: EnvironmentKey { static let defaultValue = TeamCommentDraftStore.shared }
extension EnvironmentValues {
    var teamCommentDraftStorage: TeamCommentDraftStore {
        get { self[TeamCommentStorageKey.self] }
        set { self[TeamCommentStorageKey.self] = newValue }
    }
    /// Fetches one file the shared history shows from the publishing computer.
    /// Nil outside a Team reader, where attachments are not reachable.
    var teamAttachmentLoader: TeamAttachmentLoader? {
        get { self[TeamAttachmentLoaderKey.self] }
        set { self[TeamAttachmentLoaderKey.self] = newValue }
    }
    var teamAvatarOwner: TeamAccountOwner? {
        get { self[TeamAvatarOwnerKey.self] }
        set { self[TeamAvatarOwnerKey.self] = newValue }
    }
}

enum TeamColors {
    // The app's own accent and danger, so Team screens read as the same app.
    static let action = Theme.accent
    static let destructive = Theme.danger
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
        case .chats: L10n.text("common.teams.chats")
        case .members: L10n.text("common.teams.members")
        case .invitations: L10n.text("common.teams.invitations")
        case .repositories: L10n.text("common.teams.repositories")
        case .settings: L10n.text("common.teams.organization_settings")
        }
    }
    var symbol: String {
        switch self {
        case .overview, .members: "person.2"
        case .chats: "bubble.left.and.bubble.right"
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
        Text(text).font(Theme.caption.weight(.medium)).foregroundStyle(.secondary)
            .padding(.horizontal, Theme.Space.s).padding(.vertical, 3)
            .background(Theme.rowHighlight, in: Capsule())
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
/// The app's own button styles. Touch platforms get the comfortable size.
struct TeamButtonStyle: ButtonStyle {
    var primary = false
    #if os(iOS)
    private let comfortable = true
    #else
    private let comfortable = false
    #endif
    @ViewBuilder func makeBody(configuration: Configuration) -> some View {
        if configuration.role == .destructive {
            DestructiveButtonStyle().makeBody(configuration: configuration)
        } else if primary {
            AccentButtonStyle(comfortable: comfortable).makeBody(configuration: configuration)
        } else {
            SecondaryButtonStyle(comfortable: comfortable).makeBody(configuration: configuration)
        }
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
    case renameRepository(TeamMutationContext, TeamRepository)
    case access(TeamMutationContext, TeamRepository)
    case checkouts(TeamMutationContext, TeamRepository)
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
        case let .renameRepository(_, repository): "rename-repository:\(repository.id)"
        case let .access(_, repository): "access:\(repository.id)"
        case let .checkouts(_, repository): "checkouts:\(repository.id)"
        case .rename: "rename"
        case .transfer: "transfer"
        case let .ownershipDecision(_, request, cancelling): "ownership:\(request.requestId ?? "legacy"):\(cancelling)"
        case .delete: "delete"
        case .leave: "leave"
        }
    }
}

/// Menu picker titles are not visible outside Form on iOS. Keep the field name
/// separate so every repository and permission level can be identified.
struct TeamPickerField<Selection: Hashable, Options: View>: View {
    let title: String
    @Binding var selection: Selection
    @ViewBuilder var options: () -> Options
    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Text(title).font(Theme.headline).accessibilityHidden(true)
            Picker(title, selection: $selection, content: options)
                .pickerStyle(.menu).labelsHidden()
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
