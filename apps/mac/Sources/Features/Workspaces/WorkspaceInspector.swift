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

    enum Tab: String, CaseIterable, Identifiable {
        case changes = "Changes"
        case files = "Files"
        case history = "History"

        var id: String { rawValue }
    }

    @State private var tab: Tab = .changes

    private var folder: WorkspaceFolder? { model.selected }

    var body: some View {
        VStack(spacing: 0) {
            picker
            Divider()
            content
        }
        .background(Theme.sidebar)
    }

    private var picker: some View {
        Picker("", selection: $tab) {
            ForEach(Tab.allCases) { tab in
                // The count belongs on the tab: it is the reason to look at it.
                Text(title(for: tab)).tag(tab)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .padding(.horizontal, Theme.Space.m)
        .padding(.vertical, Theme.Space.s)
    }

    private func title(for tab: Tab) -> String {
        switch tab {
        case .changes:
            let count = folder?.changeCount ?? 0
            return count > 0 ? "Changes (\(count))" : "Changes"
        case .files:
            return "Files"
        case .history:
            return "History"
        }
    }

    @ViewBuilder
    private var content: some View {
        switch tab {
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
        .background(Theme.sidebar)
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
                        CommitRow(commit: commit)
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

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
            VStack(alignment: .leading, spacing: 2) {
                Text(commit.subject)
                    .font(.system(size: 12))
                    .lineLimit(2)
                    .truncationMode(.tail)
                HStack(spacing: Theme.Space.xs) {
                    Text(commit.author)
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                    Text("·")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                    Text(commit.date, format: .relative(presentation: .named))
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                    Text("·")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                    Text(commit.shortID)
                        .font(Theme.mono(10))
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: Theme.Space.xs)
            if commit.unpushed {
                Image(systemName: "arrow.up.circle")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.accent)
                    .help("Not pushed yet")
            }
        }
        .padding(.vertical, Theme.Space.xs)
        .frame(maxWidth: .infinity, alignment: .leading)
        .help(commit.id)
    }
}
