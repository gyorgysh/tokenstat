// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

import SwiftUI

/// The centre pane for a workspace.
///
/// The terminal belongs here and is not built yet, so this says so rather than
/// filling the space with something else. Everything below the tab strip is
/// what the terminal will sit above.
struct WorkspacesView: View {
    @Bindable var model: WorkspacesModel

    var body: some View {
        VStack(spacing: 0) {
            if let folder = model.selected {
                header(folder)
                Divider()
                terminalPlaceholder(folder)
            } else {
                empty
            }
        }
        .background(Theme.background)
        .toolbar { toolbar }
    }

    private func header(_ folder: WorkspaceFolder) -> some View {
        HStack(spacing: Theme.Space.m) {
            Image(systemName: "folder.fill")
                .foregroundStyle(Theme.accent)
            VStack(alignment: .leading, spacing: 1) {
                Text(folder.name)
                    .font(.system(size: 13, weight: .semibold))
                Text(folder.path)
                    .font(Theme.mono(10))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            Spacer()
            if let git = folder.git, git.isRepo {
                BranchChip(git: git)
            }
        }
        .padding(.horizontal, Theme.Space.m)
        .padding(.vertical, Theme.Space.s)
    }

    private func terminalPlaceholder(_ folder: WorkspaceFolder) -> some View {
        VStack(spacing: Theme.Space.m) {
            Spacer()
            Image(systemName: "terminal")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(Theme.accent.opacity(0.65))
            Text("No terminal yet")
                .font(.title3.weight(.medium))
            Text("""
            This is where sessions run: Claude Code, Codex, OpenCode and the \
            rest, launched in this folder, with what they burn counted live.
            """)
            .font(.callout)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: 400)
            Text("Milestone 5 in docs/desktop-app.md")
                .font(.caption)
                .foregroundStyle(.tertiary)

            if folder.exists {
                #if os(macOS)
                Button("Reveal in Finder") { model.revealInFinder(folder) }
                    .padding(.top, Theme.Space.s)
                #endif
            } else {
                Label("This folder is missing. It is kept in case it comes back.",
                      systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .padding(.top, Theme.Space.s)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(Theme.Space.xl)
    }

    private var empty: some View {
        VStack(spacing: Theme.Space.m) {
            Image(systemName: "square.stack.3d.up")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(Theme.accent.opacity(0.65))
            Text("No workspaces yet")
                .font(.title3.weight(.medium))
            Text("""
            Add a project folder. tokenstat reads its git state and, once the \
            terminal lands, runs your agents in it.
            """)
            .font(.callout)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: 360)
            #if os(macOS)
            Button {
                Task { await model.addFolder() }
            } label: {
                Label("Add Workspace", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.accent)
            #endif
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(Theme.Space.xl)
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem {
            Button {
                Task { await model.refresh() }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .help("Re-read git state for every workspace")
        }
    }
}

/// Branch, and how far it has drifted from its upstream.
struct BranchChip: View {
    var git: GitStatus

    var body: some View {
        HStack(spacing: Theme.Space.xs) {
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 9))
            Text(git.branch ?? "detached")
                .font(Theme.mono(11))
            if git.ahead > 0 {
                Text("↑\(git.ahead)").font(Theme.numeric(10)).foregroundStyle(Theme.secondary)
            }
            if git.behind > 0 {
                Text("↓\(git.behind)").font(Theme.numeric(10)).foregroundStyle(.orange)
            }
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, Theme.Space.s)
        .padding(.vertical, 3)
        .background(Theme.panel, in: Capsule())
        .overlay(Capsule().strokeBorder(Theme.border, lineWidth: 1))
    }
}

/// The right pane for a workspace: what changed, grouped by directory.
///
/// The same shape as the reference layout's Files panel, because that is the
/// question someone actually has when looking at a workspace.
struct WorkspaceChangesView: View {
    var folder: WorkspaceFolder?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                if let folder {
                    content(folder)
                } else {
                    Text("Select a workspace.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(Theme.Space.m)
        }
        .background(Theme.sidebar)
    }

    @ViewBuilder
    private func content(_ folder: WorkspaceFolder) -> some View {
        SectionLabel(text: "Changes")

        if !folder.exists {
            Text("The folder is missing, so there is nothing to read.")
                .font(.caption)
                .foregroundStyle(.orange)
        } else if let git = folder.git, git.isRepo {
            if git.files.isEmpty {
                Text("Working tree clean.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                summary(git)
                ForEach(groupByDirectory(git.files), id: \.directory) { group in
                    VStack(alignment: .leading, spacing: Theme.Space.xs) {
                        Text(group.directory.isEmpty ? "ROOT" : group.directory.uppercased())
                            .font(Theme.sectionHeader)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.head)
                            .padding(.top, Theme.Space.s)
                        ForEach(group.files) { file in
                            ChangeRow(file: file)
                        }
                    }
                }
            }
        } else {
            Text("Not a git repository. It is still a workspace, it just has no branch.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func summary(_ git: GitStatus) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: Theme.Space.s) {
                Text("+\(git.added)")
                    .font(Theme.numeric(12, weight: .medium))
                    .foregroundStyle(.green)
                Text("−\(git.removed)")
                    .font(Theme.numeric(12, weight: .medium))
                    .foregroundStyle(.red)
                Text("· \(git.files.count) file\(git.files.count == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if git.partial {
                // Untracked and binary files have no line counts, so saying
                // "+120" flat would be a number nobody measured.
                Text("Some files have no line counts, so these totals are a floor.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

private struct ChangeRow: View {
    var file: FileChange

    var body: some View {
        HStack(spacing: Theme.Space.s) {
            Image(systemName: file.kind.symbol)
                .font(.system(size: 10))
                .foregroundStyle(file.kind.tint)
            Text(file.fileName)
                .font(.system(size: 12))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: Theme.Space.xs)
            if let added = file.added, added > 0 {
                Text("+\(added)").font(Theme.numeric(10)).foregroundStyle(.green)
            }
            if let removed = file.removed, removed > 0 {
                Text("−\(removed)").font(Theme.numeric(10)).foregroundStyle(.red)
            }
            if file.added == nil {
                // A dash, not a zero. The difference matters here as much as it
                // does for token counters.
                Text("—").font(Theme.numeric(10)).foregroundStyle(.tertiary)
            }
        }
        .help(file.path)
    }
}
