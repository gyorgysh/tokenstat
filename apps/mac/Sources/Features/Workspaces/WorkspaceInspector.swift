// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

import SwiftUI

// MARK: - Shared empty-state chrome

/// Centred icon + title + subtitle used by all three inspector tabs.
struct InspectorEmptyState: View {
    let systemImage: String
    let title: String
    let subtitle: String
    var tint: Color = .secondary

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(tint.opacity(0.7))
                .symbolRenderingMode(.hierarchical)
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.primary.opacity(0.75))
            Text(subtitle)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 360)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The right pane for a workspace: what changed, and what has already landed.
///
/// Two tabs rather than one long scroll, because they answer different
/// questions. Changes is "what have I done since the last commit", history is
/// "what is already in". Stacking them would bury whichever one you wanted.
struct WorkspaceInspector: View {
    @Bindable var model: WorkspacesModel
    /// Dismisses the pane. Owned by the root view, which is the only place the
    /// inspector's presence is decided.
    var onClose: () -> Void

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
            HStack(spacing: 0) {
                TabStrip(
                    // No icons: the inspector is 280pt at its narrowest and three
                    // labels plus three glyphs truncate before they fit.
                    tabs: InspectorTab.allCases.map { ($0, model.inspectorTabTitle($0), "") },
                    selection: tab
                )
                InspectorCloseButton(action: onClose)
                    .padding(.trailing, Theme.Space.s)
            }
            // The strip's chrome has to cover the whole band, close button
            // included. TabStrip only paints its own width, so without this the
            // xmark sat on the grey pane material beside the dark tab band.
            .background(Theme.tabStrip)
            .overlay(alignment: .bottom) {
                Rectangle().fill(Theme.border).frame(height: 1)
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

    // The empty band above this panel is the window's titlebar, not padding
    // this view controls: `RootView.belowTitlebar` reserves it, because the
    // detail column is lifted into the traffic-light row and everything
    // mounted on it comes up too. Drawing into that band is not a matter of
    // taste, it is a dead strip: AppKit's titlebar owns the mouse there, and
    // the tab that used to sit in it could not be clicked.
    //
    // Two ways of using the band were tried and both came out worse:
    //
    // - `.ignoresSafeArea(.container, edges: .top)` does not move a view *into*
    //   the titlebar, it slides it *behind* it, and the tabs vanish entirely.
    // - A `ToolbarItem` does land in the band, but toolbar items fill from the
    //   leading edge, so the tabs sat beside the sidebar toggle instead of over
    //   the column they switch. `ToolbarSpacer` fixes that and is macOS 26,
    //   above this app's deployment target.
    //
    // Leave the band alone. The tabs belong to the panel they switch.

    @ViewBuilder
    private var content: some View {
        switch tab.wrappedValue {
        case .changes:
            WorkspaceChangesView(model: model, folder: folder)
        case .files:
            WorkspaceFilesView(model: model, folder: folder)
        case .history:
            WorkspaceHistoryView(model: model, folder: folder)
        }
    }
}

/// The commits already in, newest first.
struct WorkspaceHistoryView: View {
    @Bindable var model: WorkspacesModel
    var folder: WorkspaceFolder?

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
                                    isOpen: model.openCommit[folder.id]?.id == commit.id
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
    let isOpen: Bool
    let action: () -> Void

    @State private var isHovering = false

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
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
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
                    Text(commit.date, format: .relative(presentation: .named))
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
