// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available: source sharing and own builds are permitted.
// Store and commercial distribution of builds is reserved. See LICENSE.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

import SwiftUI


struct InspectorEmptyState<Action: View>: View {
    var systemImage: String = "circle"
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

struct WorkspaceInspector: View {
    @Bindable var model: WorkspacesModel
    #if os(macOS)
    @Bindable var automations: AutomationsModel
    #endif
    var account: Account?
    var onClose: () -> Void
    var chat: ChatModel? = nil
    var workspace: WorkspaceFolder? = nil
    var showsChatOverview = false
    private var showingChatSettings: Bool {
        get { chat != nil && model.chatInspectorShowsSettings }
        nonmutating set { model.chatInspectorShowsSettings = newValue }
    }
    #if os(macOS)
    var onOpenAutomation: ((String, String?) -> Void)? = nil
    var onReviewWorkingTree: ((String?) -> Void)? = nil
    #endif
    var onOpenPull: ((ChatPull) -> Void)? = nil
    var onReviewCommit: ((String) -> Void)? = nil

    private var tab: Binding<InspectorTab> {
        Binding(get: { model.inspectorTab }, set: {
            model.inspectorTab = $0
            if chat != nil { showingChatSettings = false }
        })
    }

    private var folder: WorkspaceFolder? { chat == nil ? model.selected : workspace }
    @Namespace private var tabSeat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        #if DEBUG && os(macOS)
        let _ = DebugUIHooks.printsChanges ? Self._printChanges() : ()
        #endif
        VStack(spacing: 0) {
            InspectorChromeBar(onClose: onClose) {
                HStack(spacing: 3) {
                    if chat != nil {
                        inspectorTab(L10n.text("apple.workspaceinspector.chat.460b3a7d"), selected: showingChatSettings) { showingChatSettings = true }
                    }
                    ForEach(InspectorTab.allCases) { item in
                        inspectorTab(item == .changes ? L10n.text("apple.rootview.git.b949c922") : L10n.enumLabel(item), selected: !showingChatSettings && tab.wrappedValue == item) {
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
            GeometryReader { proxy in
                content
                    .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
                    .clipped()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .desktopPaneBackground()
    }

    private func inspectorTab(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        let animated = { withAnimation(Motion.unless(reduceMotion, Motion.morph)) { action() } }
        return Button(action: animated) {
            Text(title)
                .font(Theme.font(12, weight: selected ? .semibold : .medium))
                .lineLimit(1)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .foregroundStyle(selected ? Theme.accent : Theme.controlGlyph)
                .background {
                    if selected {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Theme.accentSoft)
                            .matchedGeometryEffect(id: "seat", in: tabSeat)
                    }
                }
                .hoverSeat(radius: 6)
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
                ChatInspector(model: chat, folder: folder, onClose: onClose, showsHeader: false, openPull: onOpenPull)
            } else {
                InspectorEmptyState(title: L10n.text("apple.workspaceinspector.open_a_conversation.6de86c4a"), subtitle: L10n.text("apple.workspaceinspector.chat_settings_appear_here_when_a_conversat.258869ce"))
            }
        } else {
            #if os(macOS)
            ZStack {
                ForEach(InspectorTab.allCases) { item in
                    let shown = tab.wrappedValue == item
                    if mounted.folder == folder?.id, mounted.tabs.contains(item) {
                        pane(item)
                            .retainedPane(isActive: shown)
                            .opacity(shown ? 1 : 0)
                            .allowsHitTesting(shown)
                            .accessibilityHidden(!shown)
                    } else if shown {
                        PanelListSkeleton(rows: 16, twoLine: item == .history)
                            .task {
                                try? await Task.sleep(for: .milliseconds(24))
                                guard !Task.isCancelled else { return }
                                if mounted.folder != folder?.id { mounted = Mounted(folder: folder?.id) }
                                mounted.tabs.insert(item)
                            }
                            .id(folder?.id)
                    }
                }
            }
            .transaction(value: tab.wrappedValue) { $0.animation = nil }
            #else
            pane(tab.wrappedValue)
            #endif
        }
    }

    #if os(macOS)
    private struct Mounted: Equatable {
        var folder: String?
        var tabs: Set<InspectorTab> = []
    }
    @State private var mounted = Mounted()
    #endif

    @ViewBuilder
    private func pane(_ item: InspectorTab) -> some View {
        switch item {
        case .changes:
            #if os(macOS)
            WorkspaceChangesView(
                model: model,
                folder: folder,
                automations: automations,
                onOpenAutomation: onOpenAutomation,
                onReview: onReviewWorkingTree
            )
            #else
            WorkspaceChangesView(model: model, folder: folder)
            #endif
        case .files:
            WorkspaceFilesView(model: model, folder: folder)
        case .history:
            WorkspaceHistoryView(model: model, folder: folder, account: account,
                onReviewCommit: onReviewCommit)
        }
    }
}

struct WorkspaceHistoryView: View {
    @Bindable var model: WorkspacesModel
    var folder: WorkspaceFolder?
    var account: Account?
    var onReviewCommit: ((String) -> Void)? = nil
    @State private var pictures = HistoryAvatarIndex.empty
    @State private var picturesKey: HistoryAvatarCache.Key?

    var body: some View {
        historyBody
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Theme.background)
            .task(id: folder?.id) {
                guard let id = folder?.id else { return }
                await model.loadHistory(for: id)
            }
            .task(id: pictureCacheKey) {
                let request = pictureRequest
                let key = pictureCacheKey
                guard !request.workspaceID.isEmpty else { return }
                if let cached = HistoryAvatarCache.shared.exact(key) {
                    pictures = cached; picturesKey = key; return
                }
                guard let loaded = try? await Bridge.commitAvatars(workspaceID: request.workspaceID, oid: request.from) else { return }
                guard !Task.isCancelled else { return }
                HistoryAvatarCache.shared.store(loaded, for: key)
                pictures = loaded.normalized()
                picturesKey = key
            }
    }

    private var pictureRequest: HistoryPictureRequest {
        let id = folder?.id ?? ""
        let commits = model.history[id] ?? []
        let from = commits.first(where: { !$0.unpushed })?.id ?? ""
        return HistoryPictureRequest(workspaceID: id, from: from)
    }
    private var pictureCacheKey: HistoryAvatarCache.Key {
        let request = pictureRequest
        return .init(owner: WorkSessionContext.shared.generation, peer: "", workspace: request.workspaceID, from: request.from)
    }
    private var displayedPictures: HistoryAvatarIndex {
        if picturesKey == pictureCacheKey { return pictures }
        return HistoryAvatarCache.shared.exact(pictureCacheKey) ?? HistoryAvatarCache.shared.recent(pictureCacheKey) ?? .empty
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
                                    avatar: displayedPictures.url(
                                        commitID: commit.id,
                                        email: commit.email,
                                        mine: commit.mine == true,
                                        accountAvatar: account?.avatar
                                    ),
                                    isOpen: model.isFront(.commit(commit.id), in: folder.id)
                                ) {
                                    if let onReviewCommit { onReviewCommit(commit.id) }
                                    else { Task { await model.showCommit(commit.id, in: folder.id) } }
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
                PanelListSkeleton(rows: 16, twoLine: true)
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

private struct CommitRow: View {
    let commit: Commit
    let avatar: String?
    let isOpen: Bool
    let action: () -> Void

    @State private var isHovering = false

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
            Avatar(
                url: avatar,
                handle: commit.author,
                size: 20,
                tint: Avatar.tint(for: identity)
            )
            .padding(.top, 1)
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
