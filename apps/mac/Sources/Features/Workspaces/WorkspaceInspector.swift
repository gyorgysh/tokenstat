// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

import SwiftUI

// MARK: - Shared empty-state chrome

/// Centred icon + title + subtitle used by all three inspector tabs.
///
/// The whole thing is one centred group on purpose, including the optional
/// call to action. A caller that stacked its own button under this view got a
/// button pinned to the floor of the pane, because this view claims the height
/// it is centred in, and a caller that reached for `fixedSize` to stop that got
/// an infinite ideal height and a pane taller than the window. Hand the button
/// in instead and it lands where the sentence it belongs to is.
struct InspectorEmptyState<Action: View>: View {
    var systemImage: String = "circle"
    /// Product mark. Preferred over `systemImage` so the pane matches cards.
    var mark: String? = nil
    let title: String
    let subtitle: String
    var tint: Color = .secondary
    @ViewBuilder var action: () -> Action

    var body: some View {
        VStack(spacing: 10) {
            if let mark {
                FeatureMark(
                    name: mark,
                    tint: tint == .secondary ? Theme.accent : tint,
                    size: 28
                )
            } else {
                Image(systemName: systemImage)
                    .font(Theme.font(28, weight: .light))
                    .foregroundStyle(tint.opacity(0.7))
                    .symbolRenderingMode(.hierarchical)
            }
            Text(title)
                .font(Theme.font(13, weight: .semibold))
                .foregroundStyle(.primary.opacity(0.75))
            Text(subtitle)
                .font(Theme.font(11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 360)
            action()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

extension InspectorEmptyState where Action == EmptyView {
    init(
        systemImage: String = "circle",
        mark: String? = nil,
        title: String,
        subtitle: String,
        tint: Color = .secondary
    ) {
        self.init(
            systemImage: systemImage,
            mark: mark,
            title: title,
            subtitle: subtitle,
            tint: tint,
            action: { EmptyView() }
        )
    }
}

/// The right pane for a workspace: what changed, and what has already landed.
///
/// Two tabs rather than one long scroll, because they answer different
/// questions. Changes is "what have I done since the last commit", history is
/// "what is already in". Stacking them would bury whichever one you wanted.
struct WorkspaceInspector: View {
    @Bindable var model: WorkspacesModel
    #if os(macOS)
    @Bindable var automations: AutomationsModel
    #endif
    /// The signed-in account. History uses its picture for commits this
    /// repository counts as yours, and the forge's public pictures for
    /// everyone else. Nil signs in nobody, so those rows stay monograms.
    var account: Account?
    /// Dismisses the pane. Owned by the root view, which is the only place the
    /// inspector's presence is decided.
    var onClose: () -> Void
    var chat: ChatModel? = nil
    var workspace: WorkspaceFolder? = nil
    var showsChatOverview = false
    private var showingChatSettings: Bool {
        get { chat != nil && model.chatInspectorShowsSettings }
        nonmutating set { model.chatInspectorShowsSettings = newValue }
    }
    #if os(macOS)
    /// After Auto commit starts, open that job on the Automations screen.
    var onOpenAutomation: ((String, String?) -> Void)? = nil
    #endif

    /// The chosen tab lives in the model, not in `@State` here.
    ///
    /// This view is rebuilt whenever the folder list refreshes, which the file
    /// watcher does every time anything in a workspace changes. With the
    /// selection in view state it was reset on the next build, so the tabs
    /// simply did not switch while a build was running in one of the folders.
    private var tab: Binding<InspectorTab> {
        Binding(get: { model.inspectorTab }, set: {
            model.inspectorTab = $0
            if chat != nil { showingChatSettings = false }
        })
    }

    private var folder: WorkspaceFolder? { chat == nil ? model.selected : workspace }

    var body: some View {
        VStack(spacing: 0) {
            InspectorChromeBar(onClose: onClose) {
                HStack(spacing: 3) {
                    if chat != nil {
                        inspectorTab(L10n.text("apple.workspaceinspector.chat.460b3a7d"), selected: showingChatSettings) { showingChatSettings = true }
                    }
                    ForEach(InspectorTab.allCases) { item in
                        inspectorTab(L10n.enumLabel(item), selected: !showingChatSettings && tab.wrappedValue == item) {
                            tab.wrappedValue = item
                        }
                    }
                }
                .padding(.horizontal, Theme.Space.s)
            }
            if let folder {
                HStack(spacing: Theme.Space.xs) {
                    Image(systemName: "folder").foregroundStyle(Theme.accent)
                    Text(folder.name).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 4)
                    if let branch = folder.git?.branch {
                        Image(systemName: "arrow.triangle.branch")
                        Text(branch).lineLimit(1).truncationMode(.middle)
                    }
                }
                .font(Theme.font(11))
                .foregroundStyle(.secondary)
                .padding(.horizontal, Theme.Space.m)
                .padding(.vertical, Theme.Space.s)
                ThemeRule()
            }
            // Give every tab the same measured rectangle.  Using an unbounded
            // max-height here lets a tab's internal VStack negotiate a
            // different height, which makes the inspector appear to jump when
            // switching between an empty state and a list.
            GeometryReader { proxy in
                content
                    .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
                    .clipped()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.background)
    }

    private func inspectorTab(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(Theme.font(12, weight: selected ? .semibold : .medium))
                .lineLimit(1)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .foregroundStyle(selected ? Theme.accent : Theme.controlGlyph)
                .background(selected ? Theme.accentSoft : .clear, in: RoundedRectangle(cornerRadius: 6))
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
        .help(title == "Chat" ? L10n.text("apple.workspaceinspector.chat_settings.17de0faa") : title)
    }

    // The band above this panel is the window titlebar. AppKit owns the
    // mouse there, so the tabs stay in the panel they switch.

    @ViewBuilder
    private var content: some View {
        if showingChatSettings, let chat {
            if !showsChatOverview, chat.selected != nil, chat.folderID == folder?.id {
                ChatInspector(model: chat, folder: folder, onClose: onClose, showsHeader: false)
            } else {
                InspectorEmptyState(title: L10n.text("apple.workspaceinspector.open_a_conversation.6de86c4a"), subtitle: L10n.text("apple.workspaceinspector.chat_settings_appear_here_when_a_conversat.258869ce"))
            }
        } else {
        switch tab.wrappedValue {
        case .changes:
            #if os(macOS)
            WorkspaceChangesView(
                model: model,
                folder: folder,
                automations: automations,
                onOpenAutomation: onOpenAutomation
            )
            #else
            WorkspaceChangesView(model: model, folder: folder)
            #endif
        case .files:
            WorkspaceFilesView(model: model, folder: folder)
        case .history:
            WorkspaceHistoryView(model: model, folder: folder, account: account)
        }
        }
    }
}

/// The commits already in, newest first.
struct WorkspaceHistoryView: View {
    @Bindable var model: WorkspacesModel
    var folder: WorkspaceFolder?
    /// For the picture beside a commit of your own. Optional so the view can
    /// still be built without an account in front of it.
    var account: Account?
    /// Forge pictures for the authors of the list on screen. Empty until the
    /// lookup returns, and empty for good when there is nothing to show.
    @State private var pictures = HistoryAvatarIndex.empty

    var body: some View {
        historyBody
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Theme.background)
            // Keyed on the folder, so switching workspaces reads the right history
            // instead of leaving the previous one on screen.
            .task(id: folder?.id) {
                guard let id = folder?.id else { return }
                await model.loadHistory(for: id)
            }
            .task(id: pictureRequest) {
                let request = pictureRequest
                pictures = .empty
                guard !request.workspaceID.isEmpty else { return }
                let loaded = (try? await Bridge.commitAvatars(workspaceID: request.workspaceID, oid: request.from)) ?? .empty
                guard !Task.isCancelled else { return }
                pictures = loaded.normalized()
            }
    }

    /// The newest pushed commit is where the forge page starts. Unpushed
    /// commits share their author's picture by email. An empty id asks the
    /// forge for the default branch instead.
    private var pictureRequest: HistoryPictureRequest {
        let id = folder?.id ?? ""
        let commits = model.history[id] ?? []
        let from = commits.first(where: { !$0.unpushed })?.id ?? ""
        return HistoryPictureRequest(workspaceID: id, from: from)
    }

    @ViewBuilder
    private var historyBody: some View {
        if let folder {
            if !folder.exists {
                InspectorEmptyState(
                    systemImage: "exclamationmark.triangle",
                    title: L10n.text("apple.workspaceinspector.folder_missing.f06c68a6"),
                    subtitle: L10n.text("apple.workspaceinspector.the_folder_no_longer_exists_on_disk.54b54492"),
                    tint: Theme.warning
                )
            } else if folder.git?.isRepo != true {
                InspectorEmptyState(
                    systemImage: "clock.arrow.trianglehead.counterclockwise.rotate.90",
                    title: L10n.text("apple.workspaceinspector.no_git_history.ea733651"),
                    subtitle: L10n.text("apple.workspaceinspector.this_folder_is_not_a_git_repository_so_the.d5100e52")
                )
            } else if let commits = model.history[folder.id] {
                if commits.isEmpty {
                    InspectorEmptyState(
                        systemImage: "clock",
                        title: L10n.text("apple.workspaceinspector.no_commits_yet.f17a8736"),
                        subtitle: L10n.text("apple.workspaceinspector.make_your_first_commit_and_it_will_appear.2ac31904")
                    )
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 4) {
                            ForEach(commits) { commit in
                                CommitRow(
                                    commit: commit,
                                    // Yours uses the account picture. Everyone
                                    // else uses the public picture the forge
                                    // already has for that author. A miss
                                    // draws initials.
                                    avatar: pictures.url(
                                        commitID: commit.id,
                                        email: commit.email,
                                        mine: commit.mine == true,
                                        accountAvatar: account?.avatar
                                    ),
                                    isOpen: model.isFront(.commit(commit.id), in: folder.id)
                                ) {
                                    Task { await model.showCommit(commit.id, in: folder.id) }
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(Theme.Space.m)
                    }
                }
            } else if let error = model.historyError(for: folder.id) {
                InspectorEmptyState(
                    systemImage: "exclamationmark.circle",
                    title: L10n.text("apple.workspaceinspector.could_not_load_history.c4dfa2b1"),
                    subtitle: error,
                    tint: Theme.danger
                )
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else {
            InspectorEmptyState(
                systemImage: "sidebar.right",
                title: L10n.text("apple.workspaceinspector.no_workspace_selected.12b33b8c"),
                subtitle: L10n.text("apple.workspaceinspector.pick_a_workspace_from_the_list_on_the_left.ba048561")
            )
        }
    }
}

/// One commit: subject, then who and when, with a mark for anything that has
/// not left this machine yet.
private struct CommitRow: View {
    let commit: Commit
    /// Account picture for a commit of yours, or the author's public forge
    /// picture. Nil draws the author's monogram.
    let avatar: String?
    let isOpen: Bool
    let action: () -> Void

    @State private var isHovering = false

    /// Identity to colour the monogram by. The address is the stable one: two
    /// people can share a display name, and one person can change theirs.
    private var identity: String {
        commit.email ?? commit.author
    }

    var body: some View {
        Button(action: action) {
            content
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(isOpen ? Theme.rowSelected : (isHovering ? Theme.rowHighlight.opacity(0.6) : .clear))
        )
    }

    private var content: some View {
        HStack(alignment: .top, spacing: Theme.Space.s) {
            // Beside the subject rather than beside the name: at the top of the
            // row it lines up down the list whether a subject wraps to two
            // lines or not, which is what makes the column readable.
            Avatar(
                url: avatar,
                handle: commit.author,
                size: 20,
                tint: Avatar.tint(for: identity)
            )
            .padding(.top, 1)
            // The row's own help would hide a tooltip on the mark. A dwell
            // popover is the card, and it is attached here so only the
            // picture opens it.
            .authorHoverCard(
                url: avatar,
                name: commit.author,
                email: commit.email,
                mine: commit.mine == true,
                tint: Avatar.tint(for: identity)
            )

            VStack(alignment: .leading, spacing: 2) {
                Text(commit.subject)
                    .font(Theme.font(13))
                    .lineLimit(2)
                    .truncationMode(.tail)
                CommitTagPills(tags: commit.tagList)
                HStack(spacing: Theme.Space.xs) {
                    Text(commit.author)
                        .font(Theme.font(11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Text("·")
                        .font(Theme.font(11))
                        .foregroundStyle(.tertiary)
                    // One shared tick rather than a live time source per row.
                    // A commit list is the worst case for the latter: every
                    // row installs one, and each one dirties the view graph on
                    // every frame. See `RelativeClock`.
                    RelativeTimeText(date: commit.date)
                        .font(Theme.font(11))
                        .foregroundStyle(.tertiary)
                    Text("·")
                        .font(Theme.font(11))
                        .foregroundStyle(.tertiary)
                    Text(commit.shortID)
                        .font(Theme.mono(11))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .fixedSize()
                }
            }
            Spacer(minLength: Theme.Space.xs)
            if commit.unpushed {
                Image(systemName: "arrow.up.circle")
                    .font(Theme.font(11))
                    .foregroundStyle(Theme.accent)
                    .help(L10n.text("apple.workspaceinspector.not_pushed_yet.06de6fec"))
            }
        }
        .padding(.horizontal, Theme.Space.xs)
        .padding(.vertical, Theme.Space.xs)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(.rect)
        .help(L10n.text("apple.workspaceinspector.open_this_commit.1459225a"))
    }
}
