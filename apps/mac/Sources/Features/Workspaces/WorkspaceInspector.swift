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
                    .font(.system(size: 28, weight: .light))
                    .foregroundStyle(tint.opacity(0.7))
                    .symbolRenderingMode(.hierarchical)
            }
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.primary.opacity(0.75))
            Text(subtitle)
                .font(.system(size: 11))
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
    /// The signed-in account, for the picture beside your own commits in
    /// History. Nil signs in nobody and draws monograms throughout.
    var account: Account?
    /// Dismisses the pane. Owned by the root view, which is the only place the
    /// inspector's presence is decided.
    var onClose: () -> Void
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
        Binding(get: { model.inspectorTab }, set: { model.inspectorTab = $0 })
    }

    private var folder: WorkspaceFolder? { model.selected }

    var body: some View {
        VStack(spacing: 0) {
            InspectorChromeBar(onClose: onClose) {
                TabStrip(
                    // No icons: the inspector is 280pt at its narrowest and three
                    // labels plus three glyphs truncate before they fit.
                    tabs: InspectorTab.allCases.map { ($0, model.inspectorTabTitle($0), "") },
                    selection: tab,
                    // The chrome bar owns the fill and the hairline, so the
                    // strip does not paint a second band that stops short of
                    // the close button.
                    showsChrome: false
                )
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

    // The band above this panel is the window titlebar. AppKit owns the
    // mouse there, so the tabs stay in the panel they switch.

    @ViewBuilder
    private var content: some View {
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

/// The commits already in, newest first.
struct WorkspaceHistoryView: View {
    @Bindable var model: WorkspacesModel
    var folder: WorkspaceFolder?
    /// For the picture beside a commit of your own. Optional so the view can
    /// still be built without an account in front of it.
    var account: Account?

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
    }

    @ViewBuilder
    private var historyBody: some View {
        if let folder {
            if !folder.exists {
                InspectorEmptyState(
                    systemImage: "exclamationmark.triangle",
                    title: "Folder missing",
                    subtitle: "The folder no longer exists on disk.",
                    tint: Theme.warning
                )
            } else if folder.git?.isRepo != true {
                InspectorEmptyState(
                    systemImage: "clock.arrow.trianglehead.counterclockwise.rotate.90",
                    title: "No git history",
                    subtitle: "This folder is not a git repository, so there are no commits to browse."
                )
            } else if let commits = model.history[folder.id] {
                if commits.isEmpty {
                    InspectorEmptyState(
                        systemImage: "clock",
                        title: "No commits yet",
                        subtitle: "Make your first commit and it will appear here."
                    )
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(commits) { commit in
                                CommitRow(
                                    commit: commit,
                                    // Your own commits carry your picture. For
                                    // anyone else the app has no picture to
                                    // show and will not go looking for one: an
                                    // avatar service would mean sending a
                                    // colleague's address off this machine on
                                    // every history load.
                                    avatar: commit.mine == true ? account?.avatar : nil,
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
            } else if let error = model.historyError {
                InspectorEmptyState(
                    systemImage: "exclamationmark.circle",
                    title: "Could not load history",
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
                title: "No workspace selected",
                subtitle: "Pick a workspace from the list on the left."
            )
        }
    }
}

/// One commit: subject, then who and when, with a mark for anything that has
/// not left this machine yet.
private struct CommitRow: View {
    let commit: Commit
    /// The account picture, for a commit this account authored. Nil draws the
    /// author's monogram instead.
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
                    .font(.system(size: 13))
                    .lineLimit(2)
                    .truncationMode(.tail)
                HStack(spacing: Theme.Space.xs) {
                    Text(commit.author)
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                    Text("·")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                    // One shared tick rather than a live time source per row.
                    // A commit list is the worst case for the latter: every
                    // row installs one, and each one dirties the view graph on
                    // every frame. See `RelativeClock`.
                    RelativeTimeText(date: commit.date)
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                    Text("·")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                    Text(commit.shortID)
                        .font(Theme.mono(11))
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: Theme.Space.xs)
            if commit.unpushed {
                Image(systemName: "arrow.up.circle")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.accent)
                    .help("Not pushed yet")
            }
        }
        .padding(.horizontal, Theme.Space.xs)
        .padding(.vertical, Theme.Space.xs)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(.rect)
        .help("Open this commit")
    }
}
