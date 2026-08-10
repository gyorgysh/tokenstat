// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

import SwiftUI

/// The centre pane for a workspace.
///
/// The workspace header, then the terminal surface: a session strip, the
/// selected session's terminal, and the launches offered when a folder has no
/// session. On macOS the host owns the process; on iOS there is no host yet,
/// so the pane keeps its placeholder.
struct WorkspacesView: View {
    @Bindable var model: WorkspacesModel
    #if os(macOS)
    @Bindable var terminals: TerminalsModel
    #endif

    var body: some View {
        VStack(spacing: 0) {
            // Same leading toggles as every other destination; trailing empty
            // because workspace actions sit in the folder header and terminal.
            DetailChromeBar {
                EmptyView()
            }
            if let folder = model.selected {
                header(folder)
                Divider()
                // Remote workspaces run the same terminal surface as local
                // ones: the host forwards every pty call to the machine that
                // owns the folder, so sessions spawn, stream and close there
                // and only the rendering happens here.
                #if os(macOS)
                TerminalPane(folder: folder, terminals: terminals, workspaces: model)
                #else
                terminalPlaceholder(folder)
                #endif
            } else {
                empty
            }
        }
        .background(Theme.background)
    }

    private func header(_ folder: WorkspaceFolder) -> some View {
        HStack(spacing: Theme.Space.m) {
            Image(systemName: "folder.fill")
                .foregroundStyle(Theme.accent)
            VStack(alignment: .leading, spacing: 1) {
                Text(folder.name)
                    .font(.system(size: DisplayFit.dp(13), weight: .semibold))
                Text(folder.isRemote
                     ? "\(folder.machineLabel ?? "Remote machine") · \(folder.path)"
                     : folder.path)
                    .font(Theme.mono(11))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    // Head truncation hid the start of the path, which is the
                    // part that identifies the project. Middle keeps both ends
                    // visible, and the full path is one hover away.
                    .truncationMode(.middle)
                    .minimumScaleFactor(0.75)
                    .help(folder.path)
            }
            // The path is the identifying line; the branch chip must never
            // squeeze it out of existence.
            .frame(maxWidth: .infinity, alignment: .leading)
            .layoutPriority(1)
            Spacer()
            if let git = folder.git, git.isRepo {
                BranchChip(git: git)
                    // The chip keeps its whole shape whatever the path does:
                    // without this, a long path with layout priority squeezes
                    // the branch text and the chip starts to look broken.
                    .fixedSize()
                    .layoutPriority(2)
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
            rest, launched in this folder. Live usage meters are coming next.
            """)
            .font(.callout)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: 400)
            Text("Sessions are ready when you are")
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
                    .foregroundStyle(Theme.warning)
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
            Add a project folder. tokenstat reads its git state and gives you a \
            place to run your agents.
            """)
            .font(.callout)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: 360)
            #if os(macOS)
            Button {
                model.requestAdd()
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

}

/// Branch, and how far it has drifted from its upstream.
struct BranchChip: View {
    var git: GitStatus

    var body: some View {
        HStack(spacing: Theme.Space.xs) {
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 9))
            Text(git.branch ?? "detached")
                .font(Theme.mono(12))
            if git.ahead > 0 {
                Text("↑\(git.ahead)").font(Theme.numeric(11)).foregroundStyle(Theme.secondary)
            }
            if git.behind > 0 {
                Text("↓\(git.behind)").font(Theme.numeric(11)).foregroundStyle(Theme.warning)
            }
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, Theme.Space.s)
        .padding(.vertical, 3)
        .background(Theme.panel, in: Capsule())
        .overlay(Capsule().strokeBorder(Theme.border, lineWidth: 1))
    }
}

/// The Changes tab of the workspace inspector: what changed, grouped by
/// directory. The tab already says "Changes", so nothing here repeats it.
struct WorkspaceChangesView: View {
    @Bindable var model: WorkspacesModel
    var folder: WorkspaceFolder?
    @State private var expandedDiffs: Set<String> = []

    var body: some View {
        changesSurface
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Theme.sidebarMaterial)
    }

    @ViewBuilder
    private var changesSurface: some View {
        #if os(macOS)
        if let folder, folder.exists, folder.git?.isRepo == true {
            changesBody
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    CommitBox(model: model, folder: folder)
                }
        } else {
            changesBody
        }
        #else
        changesBody
        #endif
    }

    @ViewBuilder
    private var changesBody: some View {
        if let folder {
            if !folder.exists {
                InspectorEmptyState(
                    systemImage: "exclamationmark.triangle",
                    title: "Folder missing",
                    subtitle: "The folder no longer exists on disk.",
                    tint: Theme.warning
                )
            } else if let git = folder.git, git.isRepo, !git.files.isEmpty {
                // Only show the scroll list when there is real content.
                ScrollView {
                    VStack(alignment: .leading, spacing: Theme.Space.m) {
                        content(folder)
                    }
                    .padding(Theme.Space.m)
                }
            } else {
                // All other states (clean tree, not a git repo) are centred.
                content(folder)
            }
        } else {
            InspectorEmptyState(
                systemImage: "square.stack.3d.up",
                title: "No workspace selected",
                subtitle: "Pick a workspace from the list on the left."
            )
        }
    }

    @ViewBuilder
    private func content(_ folder: WorkspaceFolder) -> some View {
        if !folder.exists {
            InspectorEmptyState(
                systemImage: "exclamationmark.triangle",
                title: "Folder missing",
                subtitle: "The folder no longer exists on disk.",
                tint: Theme.warning
            )
        } else if let git = folder.git, git.isRepo {
            if git.files.isEmpty {
                InspectorEmptyState(
                    systemImage: "checkmark.seal",
                    title: "Working tree clean",
                    subtitle: "No uncommitted changes. Everything is up to date.",
                    tint: Theme.accent
                )
            } else {
                summary(git)
                #if os(macOS)
                selectAll(git, in: folder)
                #endif
                diffControls(git, in: folder)
                changeSection("Staged", files: git.files.filter { model.isStaged($0.path, in: folder.id) }, in: folder)
                changeSection("Unstaged", files: git.files.filter { !model.isStaged($0.path, in: folder.id) }, in: folder)
            }
        } else {
            InspectorEmptyState(
                systemImage: "arrow.triangle.branch",
                title: "Not a git repository",
                subtitle: "This folder has no branch. Files are still accessible in the Files tab."
            )
        }
    }

    #if os(macOS)
    /// Tick or clear everything at once. The label says which way it will go,
    /// rather than being a tri-state box that makes you guess.
    private func selectAll(_ git: GitStatus, in folder: WorkspaceFolder) -> some View {
        let selected = model.stagedSelection[folder.id]?.count ?? 0
        let all = selected == git.files.count
        return Button(all ? "Clear all" : "Select all") {
            model.setAllStaged(!all, in: folder)
        }
        .buttonStyle(.plain)
        .font(.caption)
        .foregroundStyle(Theme.accent)
    }
    #endif

    private func summary(_ git: GitStatus) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: Theme.Space.s) {
                Text("+\(git.added)")
                    .font(Theme.numeric(13, weight: .medium))
                    .foregroundStyle(Theme.success)
                Text("−\(git.removed)")
                    .font(Theme.numeric(13, weight: .medium))
                    .foregroundStyle(Theme.danger)
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

    private func diffControls(_ git: GitStatus, in folder: WorkspaceFolder) -> some View {
        HStack(spacing: Theme.Space.s) {
            Text("Review")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Spacer()
            Button("Expand all") {
                expandedDiffs.formUnion(git.files.map { diffKey($0, in: folder) })
                Task {
                    for file in git.files {
                        await model.loadDiff(file.path, in: folder.id)
                    }
                }
            }
            .buttonStyle(.borderless)
            Button("Collapse all") {
                expandedDiffs.subtract(git.files.map { diffKey($0, in: folder) })
            }
            .buttonStyle(.borderless)
            Button("Review") {
                model.reviewWorkingTree(in: folder.id)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .layoutPriority(1)
        }
        .font(.caption)
        .padding(.top, Theme.Space.s)
    }

    @ViewBuilder
    private func changeSection(_ title: String, files: [FileChange], in folder: WorkspaceFolder) -> some View {
        if !files.isEmpty {
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                HStack {
                    Text(title.uppercased())
                        .font(Theme.sectionHeader)
                        .foregroundStyle(.tertiary)
                    Text("\(files.count)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Spacer()
                }
                .padding(.top, Theme.Space.s)
                ForEach(files) { file in
                    let key = diffKey(file, in: folder)
                    ChangeRow(
                        file: file,
                        isStaged: model.isStaged(file.path, in: folder.id),
                        isOpen: model.activeFile[folder.id] == file.path,
                        isExpanded: expandedDiffs.contains(key),
                        onToggle: { model.toggleStaged(file.path, in: folder.id) },
                        onToggleDiff: {
                            if expandedDiffs.contains(key) {
                                expandedDiffs.remove(key)
                            } else {
                                expandedDiffs.insert(key)
                                Task { await model.loadDiff(file.path, in: folder.id) }
                            }
                        },
                        onOpen: { Task { await model.openFile(file.path, in: folder.id) } }
                    )
                    if expandedDiffs.contains(key) {
                        if let diff = model.diff(for: file.path, in: folder.id) {
                            ScrollView([.vertical, .horizontal]) {
                                DiffBody(diff: diff)
                            }
                            .frame(maxHeight: 260)
                                .background(Theme.background, in: RoundedRectangle(cornerRadius: Theme.cardRadius))
                                .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius).strokeBorder(Theme.border))
                                .padding(.leading, Theme.Space.l)
                        } else {
                            ProgressView().controlSize(.small).padding(.leading, Theme.Space.l)
                        }
                    }
                }
            }
        }
    }

    private func diffKey(_ file: FileChange, in folder: WorkspaceFolder) -> String {
        "\(folder.id):\(file.path)"
    }
}

#if os(macOS)
/// Message, commit, push. Pinned to the bottom of the Changes tab, which is
/// where every tool that does this puts it.
///
/// Staging and committing are one action here rather than two buttons. The
/// index is not something this panel shows, so a half-staged repository left
/// behind by a click would be a state the user cannot see and did not ask for.
private struct CommitBox: View {
    @Bindable var model: WorkspacesModel
    let folder: WorkspaceFolder

    private var title: Binding<String> {
        Binding(
            get: { model.commitMessage[folder.id] ?? "" },
            set: { model.commitMessage[folder.id] = $0 }
        )
    }

    private var description: Binding<String> {
        Binding(
            get: { model.commitDescription[folder.id] ?? "" },
            set: { model.commitDescription[folder.id] = $0 }
        )
    }

    private var selectedCount: Int {
        model.stagedSelection[folder.id]?.count ?? 0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Rectangle().fill(Theme.border).frame(height: 1)

            if let outcome = model.gitOutcome {
                Text(outcome.message.isEmpty ? "Done." : outcome.message)
                    .font(.caption)
                    .foregroundStyle(outcome.ok ? .green : .red)
                    .lineLimit(4)
                    .textSelection(.enabled)
                    .padding(.horizontal, Theme.Space.m)
            }

            TextField("Commit title", text: title)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .lineLimit(1)
                .padding(Theme.Space.s)
                .background(Theme.panel, in: RoundedRectangle(cornerRadius: 5))
                .overlay(
                    RoundedRectangle(cornerRadius: 5).strokeBorder(Theme.border, lineWidth: 1)
                )
                .padding(.horizontal, Theme.Space.m)

            TextEditor(text: description)
                .font(.system(size: 12))
                .scrollContentBackground(.hidden)
                .frame(minHeight: 44, maxHeight: 82)
                .padding(Theme.Space.xs)
                .background(Theme.panel, in: RoundedRectangle(cornerRadius: 5))
                .overlay(
                    RoundedRectangle(cornerRadius: 5).strokeBorder(Theme.border, lineWidth: 1)
                )
                .overlay(alignment: .topLeading) {
                    if description.wrappedValue.isEmpty {
                        Text("Description (optional)")
                            .font(.system(size: 12))
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, Theme.Space.s)
                            .padding(.vertical, Theme.Space.s)
                            .allowsHitTesting(false)
                    }
                }
                .padding(.horizontal, Theme.Space.m)

            HStack(spacing: Theme.Space.s) {
                if let git = folder.git, git.ahead > 0 {
                    Button {
                        Task { await model.push(folder) }
                    } label: {
                        Label("Push \(git.ahead)", systemImage: "arrow.up")
                            .font(.caption)
                    }
                    .disabled(model.isCommitting)
                    .help("Push the current branch")
                }
                Spacer()
                Button {
                    Task { await model.commit(folder) }
                } label: {
                    Text(selectedCount > 0 ? "Commit \(selectedCount)" : "Commit")
                        .font(.system(size: 13, weight: .medium))
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
                .disabled(model.isCommitting || selectedCount == 0)
            }
            .padding(.horizontal, Theme.Space.m)
        }
        .padding(.bottom, Theme.Space.m)
        .background(Theme.sidebarMaterial)
    }
}
#endif

/// One changed file: a tick for the next commit, and the name opens its diff.
private struct ChangeRow: View {
    var file: FileChange
    var isStaged: Bool
    var isOpen: Bool
    var isExpanded: Bool
    var onToggle: () -> Void
    var onToggleDiff: () -> Void
    var onOpen: () -> Void

    var body: some View {
        HStack(spacing: Theme.Space.s) {
            #if os(macOS)
            Button(action: onToggle) {
                Image(systemName: isStaged ? "checkmark.square.fill" : "square")
                    .font(.system(size: 12))
                    .foregroundStyle(isStaged ? Theme.accent : Color.secondary)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .help(isStaged ? "Will be committed" : "Include in the next commit")
            #endif

            Image(systemName: file.kind.symbol)
                .font(.system(size: 11))
                .foregroundStyle(file.kind.tint)
            Button(action: onOpen) {
                Text(file.fileName)
                    .font(.system(size: 13, weight: isOpen ? .medium : .regular))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .help("Open the diff")
            Button(action: onToggleDiff) {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help(isExpanded ? "Collapse diff" : "Expand diff")
            Spacer(minLength: Theme.Space.xs)
            if let added = file.added, added > 0 {
                Text("+\(added)").font(Theme.numeric(11)).foregroundStyle(Theme.success)
            }
            if let removed = file.removed, removed > 0 {
                Text("−\(removed)").font(Theme.numeric(11)).foregroundStyle(Theme.danger)
            }
            if file.added == nil {
                // A dash, not a zero. The difference matters here as much as it
                // does for token counters.
                Text("n/a").font(Theme.numeric(11)).foregroundStyle(.tertiary)
            }
        }
        .help(file.path)
    }
}
