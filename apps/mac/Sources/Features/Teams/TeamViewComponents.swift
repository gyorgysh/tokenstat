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
/// Opens the team thread for a shared chat: the share id, and the folder the
/// chat belongs to when it is known.
typealias TeamChatOpener = @MainActor (String, String?) -> Void
private struct TeamChatOpenerKey: EnvironmentKey { static let defaultValue: TeamChatOpener? = nil }
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
    var openTeamChat: TeamChatOpener? {
        get { self[TeamChatOpenerKey.self] }
        set { self[TeamChatOpenerKey.self] = newValue }
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
/// The row under the chrome bar on every Team screen, the same row Devices
/// has: the screen's tabs on the leading edge, its actions on the trailing
/// edge, a hairline under both.
struct TeamToolbarRow<Leading: View, Trailing: View>: View {
    @ViewBuilder var leading: () -> Leading
    @ViewBuilder var trailing: () -> Trailing
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: Theme.Space.m) {
                leading()
                Spacer(minLength: 0)
                HStack(spacing: Theme.Space.s) { trailing() }
            }
            .padding(Theme.Space.m)
            ThemeRule()
        }
    }
}

/// The scrolling body of a Team screen: the full width of the window with
/// the same margin and gap as Devices, so cards line up across screens.
struct TeamPage<Content: View>: View {
    @ViewBuilder var content: () -> Content
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.m) { content() }
                .padding(Theme.Space.m)
                .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }
}

extension View {
    /// A tile inside a card: the page ground, a hairline and a smaller
    /// radius, so it reads as part of the card around it.
    func teamTile() -> some View {
        background(Theme.background, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.border, lineWidth: 1))
    }
    /// A standalone surface outside a card, with the card's own radius.
    func teamCard() -> some View {
        background(Theme.panel, in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
            .clipShape(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous).strokeBorder(Theme.border, lineWidth: 1))
    }
    /// Spacing of one row inside a card. The card supplies the side margin.
    func teamRowPadding() -> some View {
        padding(.vertical, Theme.Space.s)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
    }
}

/// Rows inside a card, with a hairline between each pair.
struct TeamRows<Item: Identifiable, Row: View>: View {
    let items: [Item]
    @ViewBuilder let row: (Item) -> Row
    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                if index > 0 { ThemeRule() }
                row(item)
            }
        }
    }
}

/// A row that opens something. Hover and press tint the row the way a
/// sidebar row tints, reaching just past the text so the tint has a margin,
/// and a chevron says it leads somewhere.
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
            .padding(.horizontal, Theme.Space.s)
            .teamRowPadding()
            .background(configuration.isPressed ? Theme.rowSelected : hovering ? Theme.rowHighlight : Color.clear,
                in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .padding(.horizontal, -Theme.Space.s)
            .contentShape(.rect)
            .onHover { hovering = $0 }
        }
    }
}

/// One count on an overview, in the shape of the app's summary tiles. Every
/// tile in a row has the same height and width, and the label never wraps.
struct TeamMetricTile: View {
    let title: String
    let value: String
    let symbol: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                HStack {
                    Image(systemName: symbol).font(Theme.font(15, weight: .medium)).foregroundStyle(TeamColors.action)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right").font(Theme.font(10, weight: .semibold)).foregroundStyle(.tertiary)
                }
                Text(value).font(Theme.font(26, weight: .semibold)).monospacedDigit().foregroundStyle(.primary).lineLimit(1)
                Text(title).font(Theme.caption).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.85)
            }
            .padding(Theme.Space.m)
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

/// Buttons in a toolbar row and in the composer well. The Mac uses the
/// dense size Devices and the main composer use. A phone keeps the
/// comfortable touch target.
struct TeamSmallButtonStyle: ButtonStyle {
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

/// The two views of the Teams place: the organizations and every shared
/// project across them.
enum TeamHubPage: String, CaseIterable, Hashable {
    case organizations, projects
    var label: String {
        switch self {
        case .organizations: L10n.text("common.teams.organizations")
        case .projects: L10n.text("common.teams.shared_projects")
        }
    }
}

/// The sections of an organization on a phone: the same choice as the Mac's
/// tabs, as a row of chips that scrolls when it does not fit, so every
/// section is one tap away instead of behind a menu.
struct TeamSectionChips: View {
    @Binding var selection: TeamSection
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Theme.Space.xs) {
                    ForEach(TeamSection.allCases) { section in
                        let selected = section == selection
                        Button {
                            withAnimation(.snappy(duration: 0.2)) { selection = section }
                        } label: {
                            Label(section.label, systemImage: section.symbol)
                                .font(Theme.callout.weight(selected ? .semibold : .regular))
                                .foregroundStyle(selected ? Theme.accent : Theme.controlGlyph)
                                .padding(.horizontal, Theme.Space.m)
                                .frame(minHeight: Theme.Control.heightComfortable)
                                .background(selected ? Theme.accentSoft : Theme.panel, in: Capsule())
                                .overlay(Capsule().strokeBorder(selected ? Theme.accent.opacity(0.35) : Theme.border, lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                        .id(section)
                        .accessibilityAddTraits(selected ? [.isSelected] : [])
                    }
                }
                .padding(.vertical, 2)
            }
            .onAppear { proxy.scrollTo(selection, anchor: .center) }
            .onChange(of: selection) { _, next in withAnimation { proxy.scrollTo(next, anchor: .center) } }
        }
    }
}

/// Which teams can open a folder, as small accent pills. The same mark on
/// the Mac's repository list and the phone's, so a shared folder is told
/// apart at a glance wherever it is listed.
struct TeamFolderBadges: View {
    let names: [String]
    var body: some View {
        ForEach(names, id: \.self) { team in
            Label(team, systemImage: "person.2.fill")
                .font(Theme.font(10, weight: .semibold)).lineLimit(1)
                .foregroundStyle(Theme.accent)
                .padding(.horizontal, Theme.Space.s).padding(.vertical, 2)
                .background(Theme.accentSoft, in: Capsule())
                .help(L10n.text("common.teams.shared_with_team", team))
                .accessibilityLabel(L10n.text("common.teams.shared_with_team", team))
        }
    }
}

/// Says that Teams is an early preview, and what that means, wherever Team
/// is open. It is a disclaimer rather than a control, so it reads as a
/// small label: hovering it on a Mac explains it, and a tap or a click opens
/// the same note on every device.
struct TeamPreviewBadge: View {
    @State private var hovering = false
    @State private var pinned = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "flask")
                .font(.system(size: 9, weight: .semibold))
            Text(L10n.text("common.teams.preview_badge"))
                .font(.system(size: 11, weight: .semibold))
                .lineLimit(1)
        }
        .foregroundStyle(Theme.accent)
        .padding(.horizontal, Theme.Space.s)
        .padding(.vertical, 3)
        .background(Theme.accentSoft, in: Capsule())
        .overlay(Capsule().strokeBorder(Theme.accent.opacity(0.25), lineWidth: 0.5))
        .contentShape(Capsule())
        .onTapGesture { pinned.toggle() }
        #if os(macOS)
        .onHover { inside in
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.12)) { hovering = inside }
        }
        #endif
        .popover(isPresented: Binding(get: { hovering || pinned }, set: { if !$0 { hovering = false; pinned = false } }),
                 arrowEdge: .bottom) {
            TeamPreviewNote()
                #if os(iOS)
                .presentationCompactAdaptation(.popover)
                #endif
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L10n.text("common.teams.preview_title"))
        .accessibilityHint(L10n.text("common.teams.preview_detail"))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { pinned = true }
    }
}

/// The note behind the preview badge: what works, what does not yet, and
/// that the person's own projects are safe whatever happens to Teams.
struct TeamPreviewNote: View {
    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Label(L10n.text("common.teams.preview_title"), systemImage: "flask")
                .font(Theme.font(13, weight: .semibold))
                .foregroundStyle(Theme.accent)
            Text(L10n.text("common.teams.preview_detail"))
            Text(L10n.text("common.teams.preview_safety"))
                .foregroundStyle(.secondary)
        }
        .font(Theme.font(12))
        .fixedSize(horizontal: false, vertical: true)
        .frame(width: 300, alignment: .leading)
        .padding(Theme.Space.m)
    }
}
