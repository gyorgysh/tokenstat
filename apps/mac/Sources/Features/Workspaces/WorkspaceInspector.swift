// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

import SwiftUI

/// The right pane for a workspace: what changed, and what has already landed.
///
/// Two tabs rather than one long scroll, because they answer different
/// questions. Changes is "what have I done since the last commit", history is
/// "what is already in". Stacking them would bury whichever one you wanted.
struct WorkspaceInspector: View {
    @Bindable var model: WorkspacesModel

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
            TabStrip(
                // No icons: the inspector is 280pt at its narrowest and three
                // labels plus three glyphs truncate before they fit.
                tabs: InspectorTab.allCases.map { ($0, model.inspectorTabTitle($0), "") },
                selection: tab
            )
            content
        }
        .background(Theme.sidebarMaterial)
    }

    // The empty band above this panel is the window's toolbar, not padding this
    // view controls, and two attempts to use it both came out worse:
    //
    // - `.ignoresSafeArea(.container, edges: .top)` does not move a view *into*
    //   the toolbar, it slides it *behind* it, and the tabs vanish entirely.
    // - A `ToolbarItem` does land in the band, but toolbar items fill from the
    //   leading edge, so the tabs sat beside the sidebar toggle instead of over
    //   the column they switch. `ToolbarSpacer` fixes that and is macOS 26,
    //   above this app's deployment target.
    //
    // Leave the band alone. It is one empty strip, and the tabs belong to the
    // panel they switch.

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
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Theme.Space.m)
        }
        .background(Theme.sidebarMaterial)
        // Keyed on the folder, so switching workspaces reads the right history
        // instead of leaving the previous one on screen.
        .task(id: folder?.id) {
            guard let id = folder?.id else { return }
            await model.loadHistory(for: id)
        }
    }

    @ViewBuilder
    private var content: some View {
        if let folder {
            if !folder.exists {
                note("The folder is missing, so there is nothing to read.", tint: .orange)
            } else if let commits = model.history[folder.id] {
                if commits.isEmpty {
                    note(
                        folder.git?.isRepo == true
                            ? "No commits yet."
                            : "Not a git repository, so there is no history to show."
                    )
                } else {
                    ForEach(commits) { commit in
                        CommitRow(
                            commit: commit,
                            isOpen: model.openCommit[folder.id]?.id == commit.id
                        ) {
                            Task { await model.showCommit(commit.id, in: folder.id) }
                        }
                    }
                }
            } else if let error = model.historyError {
                note(error, tint: .red)
            } else {
                note("Reading history…")
            }
        } else {
            note("Select a workspace.")
        }
    }

    private func note(_ text: String, tint: Color = .secondary) -> some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(tint)
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
