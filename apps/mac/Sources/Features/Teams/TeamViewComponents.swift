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
private struct TeamAskStorageKey: EnvironmentKey { static let defaultValue = TeamAskRecoveryStore.shared }
extension EnvironmentValues {
    var teamAskRecoveryStorage: TeamAskRecoveryStore {
        get { self[TeamAskStorageKey.self] }
        set { self[TeamAskStorageKey.self] = newValue }
    }
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
        case .overview: L10n.text("common.teams.overview")
        case .chats: L10n.text("common.teams.section_chats")
        case .members: L10n.text("common.teams.members")
        case .invitations: L10n.text("common.teams.invitations")
        case .repositories: L10n.text("common.teams.repositories")
        case .settings: L10n.text("common.teams.section_settings")
        }
    }
    var symbol: String {
        switch self {
        case .overview: "square.grid.2x2"
        case .members: "person.2"
        case .chats: "bubble.left.and.bubble.right"
        case .invitations: "envelope"
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
    var showsPresence = false
    var online: Bool? = nil
    var body: some View {
        HStack(spacing: Theme.Space.m) {
            Avatar(url: teamAvatarURL(avatar, owner: owner)?.absoluteString, name: name, handle: handle, size: 32, tint: Avatar.tint(for: id))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(name).font(Theme.body.weight(.medium)).lineLimit(2)
                if let handle { Text("@\(handle)").font(Theme.callout).foregroundStyle(.secondary).lineLimit(1) }
                if showsPresence {
                    HStack(spacing: Theme.Space.xs) {
                        if let online {
                            Circle().fill(online ? Theme.accent : Theme.stateIdle).frame(width: 6, height: 6).accessibilityHidden(true)
                            Text(online ? L10n.text("common.teams.online") : L10n.text("common.teams.offline"))
                        } else { Text(L10n.text("common.teams.presence_unknown")) }
                    }.font(Theme.caption).foregroundStyle(online == true ? TeamColors.action : .secondary)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

struct TeamMemberLabel: View {
    @Bindable var store: TeamStore
    let member: TeamMember
    let organization: String
    var body: some View {
        TimelineView(.periodic(from: .now, by: 15)) { _ in
            TeamPersonLabel(id: member.id, name: member.name, handle: member.handle, avatar: member.avatar, owner: store.owner,
                showsPresence: true, online: store.presenceStatus(member: member.id, organization: organization, at: Date()))
        }
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
        .background(warning ? TeamColors.warning.opacity(0.08) : Theme.accentSoft, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(warning ? TeamColors.warning.opacity(0.3) : Theme.accent.opacity(0.2), lineWidth: 1))
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
/// The heading every Team page starts with: a title, one line saying what
/// the page is for, and that page's actions on the trailing edge.
struct TeamSectionHeader<Actions: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder let actions: () -> Actions
    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: Theme.Space.m) { heading; Spacer(minLength: Theme.Space.l); HStack(spacing: Theme.Space.s) { actions() } }
            VStack(alignment: .leading, spacing: Theme.Space.m) { heading; HStack(spacing: Theme.Space.s) { actions() } }
        }
    }
    private var heading: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            Text(title).font(Theme.title2.weight(.semibold)).lineLimit(2).accessibilityAddTraits(.isHeader)
            Text(subtitle).font(Theme.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}
extension TeamSectionHeader where Actions == EmptyView {
    init(title: String, subtitle: String) { self.init(title: title, subtitle: subtitle) { EmptyView() } }
}

/// One page shape for every Team screen. The same lane, margins and header
/// on every tab, so switching tabs never moves the content under the eye.
struct TeamPage<Actions: View, Content: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder var actions: () -> Actions
    @ViewBuilder var content: () -> Content
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.l) {
                TeamSectionHeader(title: title, subtitle: subtitle, actions: actions)
                content()
            }
            .teamLane()
        }
    }
}

extension View {
    /// The Team lane: leading, capped at the reading room's structured
    /// width, with the page margin on every side.
    func teamLane() -> some View {
        padding(Theme.Space.l)
            .frame(maxWidth: ReadingRoom.laneWidth + Theme.Space.l * 2, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .topLeading)
    }
    /// The one surface Team content sits on: a panel with the app's card
    /// radius and hairline, clipped so a pressed row stays inside it.
    func teamCard() -> some View {
        background(Theme.panel, in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
            .clipShape(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous).strokeBorder(Theme.border, lineWidth: 1))
    }
    /// Inner spacing of a row in a Team list card.
    func teamRowPadding() -> some View {
        padding(.horizontal, Theme.cardPadding).padding(.vertical, Theme.Space.m)
            .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
    }
}

/// A group heading inside a page: the same small caps label the sidebar
/// uses, with an optional link to the full list.
struct TeamGroupHeading: View {
    let title: String
    var action: (title: String, run: () -> Void)?
    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title.uppercased()).font(Theme.sectionHeader).foregroundStyle(.secondary).accessibilityAddTraits(.isHeader)
            Spacer(minLength: Theme.Space.s)
            if let action {
                Button(action.title, .next, action: action.run).buttonStyle(.plain).font(Theme.callout).foregroundStyle(TeamColors.action)
            }
        }
        .padding(.horizontal, Theme.Space.xs)
    }
}

/// Rows in one card, with hairlines between them inset to the text.
struct TeamListCard<Item: Identifiable, Row: View>: View {
    let items: [Item]
    @ViewBuilder let row: (Item) -> Row
    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                if index > 0 { ThemeRule().padding(.leading, Theme.cardPadding) }
                row(item)
            }
        }
        .teamCard()
    }
}

/// A row that opens something. Hover and press tint the whole row, the way
/// a sidebar row does, and a chevron says it leads somewhere.
struct TeamListRowButtonStyle: ButtonStyle {
    var chevron = true
    func makeBody(configuration: Configuration) -> some View { RowBody(configuration: configuration, chevron: chevron) }
    private struct RowBody: View {
        let configuration: Configuration
        let chevron: Bool
        @State private var hovering = false
        var body: some View {
            HStack(spacing: Theme.Space.m) {
                configuration.label.frame(maxWidth: .infinity, alignment: .leading)
                if chevron { Image(systemName: "chevron.right").font(Theme.font(11, weight: .semibold)).foregroundStyle(.tertiary).accessibilityHidden(true) }
            }
            .teamRowPadding()
            .background(configuration.isPressed ? Theme.rowSelected : hovering ? Theme.rowHighlight : Color.clear)
            .contentShape(.rect)
            .onHover { hovering = $0 }
        }
    }
}

/// One count on an overview. Every tile in a row has the same height and
/// width, and the label never wraps, so a row of them reads as one strip.
struct TeamMetricTile: View {
    let title: String
    let value: String
    let symbol: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                HStack {
                    Image(systemName: symbol).font(Theme.font(14, weight: .medium)).foregroundStyle(TeamColors.action)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right").font(Theme.font(10, weight: .semibold)).foregroundStyle(.tertiary)
                }
                Text(value).font(Theme.numeric(26, weight: .semibold)).foregroundStyle(.primary).lineLimit(1)
                Text(title).font(Theme.callout).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.85)
            }
            .padding(Theme.cardPadding)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .teamCard()
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
    }
}

/// A setting on a Settings page: what it is on the leading side, the
/// control that changes it on the trailing side.
struct TeamSettingRow<Control: View>: View {
    let title: String
    var detail: String?
    @ViewBuilder var control: () -> Control
    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: Theme.Space.l) { text; Spacer(minLength: Theme.Space.m); control() }
            VStack(alignment: .leading, spacing: Theme.Space.s) { text; control() }
        }
        .teamRowPadding()
    }
    private var text: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(Theme.body.weight(.medium))
            if let detail { Text(detail).font(Theme.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
        }
    }
}

/// The trailing "more" menu of a row: platform menu rows, one glyph.
struct TeamRowMenu<Content: View>: View {
    let label: String
    @ViewBuilder var content: () -> Content
    var body: some View {
        Menu(content: content) {
            Image(systemName: "ellipsis").font(Theme.font(13, weight: .semibold)).foregroundStyle(Theme.controlGlyph)
                .frame(width: Theme.Control.heightComfortable, height: Theme.Control.heightComfortable).contentShape(.rect)
        }
        #if os(macOS)
        .menuStyle(.borderlessButton)
        #endif
        .menuIndicator(.hidden).fixedSize()
        .accessibilityLabel(label)
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


struct TeamChatActivityBadge: View {
    @Bindable var store: TeamStore
    let share: TeamSharedChat
    let repository: TeamRepository
    let checkout: TeamCheckout
    var body: some View {
        if store.chatReadState.isUnread(share, repository: repository, checkout: checkout) {
            Text(store.chatReadState.hasRead(share, repository: repository, checkout: checkout) ? L10n.text("common.teams.unread") : L10n.text("common.teams.new_activity"))
                .font(Theme.caption.weight(.semibold)).foregroundStyle(TeamColors.action)
                .padding(.horizontal, Theme.Space.s).padding(.vertical, Theme.Space.xs)
                .background(Theme.accentSoft, in: Capsule())
                .accessibilityIdentifier("team.chat.unread.\(share.id)")
        }
    }
}

/// What the shared chat composer sends: a comment people read, or a
/// request the publishing computer's agent runs.
enum TeamComposerMode: String, CaseIterable, Hashable {
    case comment, ask
    var label: String {
        switch self {
        case .comment: L10n.text("common.teams.composer_comment")
        case .ask: L10n.text("common.teams.composer_ask")
        }
    }
}

/// Buttons inside the composer well. The Mac uses the main composer's
/// dense size. A phone keeps the comfortable touch target.
struct TeamComposerButtonStyle: ButtonStyle {
    var primary = false
    @ViewBuilder func makeBody(configuration: Configuration) -> some View {
        #if os(iOS)
        TeamButtonStyle(primary: primary).makeBody(configuration: configuration)
        #else
        if configuration.role == .destructive {
            DestructiveButtonStyle(small: true).makeBody(configuration: configuration)
        } else if primary {
            AccentButtonStyle(small: true).makeBody(configuration: configuration)
        } else {
            SecondaryButtonStyle(small: true).makeBody(configuration: configuration)
        }
        #endif
    }
}

/// The text field of the composer well: no box of its own, because the
/// well is the box, exactly as in the main chat composer.
struct TeamComposerField: View {
    let placeholder: String
    @Binding var text: String
    var body: some View {
        TextField(placeholder, text: $text, axis: .vertical)
            .font(Theme.body).textFieldStyle(.plain)
            .lineLimit(1...8)
            .padding(.vertical, 6).padding(.horizontal, Theme.Space.xs)
            .frame(minHeight: 34, alignment: .topLeading)
    }
}
