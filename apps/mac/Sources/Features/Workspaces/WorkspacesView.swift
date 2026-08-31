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
    @Bindable var chat: ChatModel
    /// Workspace destinations live in RootView, outside the terminal surface.
    /// The launcher names what should open and the root performs the route.
    var onOpenSection: (WorkspaceSection, String) -> Void
    /// True when this is the front destination. Root keeps the view mounted
    /// while the user is on Home or elsewhere so terminals are not torn down;
    /// when false the pane must not claim keyboard focus or poll as focused.
    var isActive: Bool = true
    /// The signed-in tier, for the screen viewer a remote workspace offers.
    /// Nil is a tier the viewer refuses, and says so.
    var tier: String?
    /// The peer whose screen the header is offering, while the viewer is up.
    @State private var viewingScreen: RemoteScreenTarget?
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
                #if os(macOS)
                // What that computer is doing, where you are working in its
                // folders. This block only existed on Devices, so somebody who
                // opened a machine's workspace could see its files and not
                // whether it was awake or what it was busy with.
                if folder.isRemote, let peer = folder.machineID, !peer.isEmpty {
                    remoteMachine(folder, peer: peer)
                }
                #endif
                ThemeRule()
                // Remote workspaces run the same terminal surface as local
                // ones: the host forwards every pty call to the machine that
                // owns the folder, so sessions spawn, stream and close there
                // and only the rendering happens here.
                #if os(macOS)
                TerminalPane(
                    folder: folder,
                    terminals: terminals,
                    workspaces: model,
                    chat: chat,
                    onOpenSection: { onOpenSection($0, folder.id) },
                    isSurfaceActive: isActive
                )
                #else
                terminalPlaceholder(folder)
                #endif
            } else {
                empty
            }
        }
        .background(Theme.background)
        #if os(macOS)
        .sheet(item: $viewingScreen) { target in
            ScreenViewerView(peer: target.peer, name: target.name, tier: tier)
                .frame(minWidth: 900, minHeight: 600)
        }
        #endif
    }

    private func header(_ folder: WorkspaceFolder) -> some View {
        HStack(spacing: Theme.Space.m) {
            Image(systemName: "folder.fill")
                .foregroundStyle(Theme.accent)
            VStack(alignment: .leading, spacing: 1) {
                Text(folder.name)
                    .font(Theme.fit(13, weight: .semibold))
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
                BranchChip(workspaceID: folder.id, git: git) {
                    await model.refresh()
                }
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

    #if os(macOS)
    /// Power, CPU and memory for the machine this folder lives on, and the way
    /// on to its screen.
    ///
    /// The same readings the Devices page shows, from the same `HostStatsBar`,
    /// so the two cannot report different things about one computer.
    private func remoteMachine(_ folder: WorkspaceFolder, peer: String) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            HStack(spacing: Theme.Space.s) {
                Image(systemName: "laptopcomputer")
                    .foregroundStyle(Theme.accent)
                Text(folder.machineLabel ?? "Remote machine")
                    .font(Theme.fit(12, weight: .medium))
                Spacer(minLength: 0)
                Button("View screen", .preview) {
                    viewingScreen = RemoteScreenTarget(
                        peer: peer,
                        name: folder.machineLabel ?? "Remote machine"
                    )
                }
                .buttonStyle(SecondaryButtonStyle(small: true))
                .fixedSize()
            }
            HostStatsBar(peer: peer, online: true)
        }
        .padding(.horizontal, Theme.Space.m)
        .padding(.bottom, Theme.Space.s)
    }
    #endif

    private func terminalPlaceholder(_ folder: WorkspaceFolder) -> some View {
        VStack(spacing: Theme.Space.m) {
            Spacer()
            Image(systemName: "terminal")
                .font(Theme.font(34, weight: .light))
                .foregroundStyle(Theme.accent.opacity(0.65))
            Text("No terminal yet")
                .font(Theme.title3.weight(.medium))
            Text("""
            This is where sessions run: Claude Code, Codex, OpenCode and the \
            rest, launched in this folder. Live usage meters are coming next.
            """)
            .font(Theme.callout)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: 400)
            Text("Sessions are ready when you are")
                .font(Theme.caption)
                .foregroundStyle(.tertiary)

            if folder.exists {
                #if os(macOS)
                Button("Reveal in Finder", .reveal) { model.revealInFinder(folder) }
                    .padding(.top, Theme.Space.s)
                #endif
            } else {
                Label("This folder is missing. It is kept in case it comes back.",
                      systemImage: "exclamationmark.triangle")
                    .font(Theme.caption)
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
                .font(Theme.font(34, weight: .light))
                .foregroundStyle(Theme.accent.opacity(0.65))
            Text("No workspaces yet")
                .font(Theme.title3.weight(.medium))
            Text("""
            Add a project folder. tokenstat reads its git state and gives you a \
            place to run your agents.
            """)
            .font(Theme.callout)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: 360)
            #if os(macOS)
            Button("Add Workspace", .create) {
                model.requestAdd()
            }
            .buttonStyle(.borderedProminent)
            #endif
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(Theme.Space.xl)
    }

}

/// The Changes tab of the workspace inspector: what changed, grouped by
/// directory. The tab already says "Changes", so nothing here repeats it.
struct WorkspaceChangesView: View {
    @Bindable var model: WorkspacesModel
    var folder: WorkspaceFolder?
    #if os(macOS)
    @Bindable var automations: AutomationsModel
    /// Opens the Auto commit job on Automations after it starts.
    var onOpenAutomation: ((String, String?) -> Void)? = nil
    #endif
    @State private var expandedDiffs: Set<String> = []

    var body: some View {
        changesSurface
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Theme.background)
    }

    @ViewBuilder
    private var changesSurface: some View {
        #if os(macOS)
        if let folder, folder.exists, folder.git?.isRepo == true {
            changesBody
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    CommitBox(
                        model: model,
                        automations: automations,
                        folder: folder,
                        onOpenAutomation: onOpenAutomation
                    )
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
        .font(Theme.caption)
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
                    .font(Theme.caption)
                    .foregroundStyle(.secondary)
            }
            if git.partial {
                // Untracked and binary files have no line counts, so saying
                // "+120" flat would be a number nobody measured.
                Text("Some files have no line counts, so these totals are a floor.")
                    .font(Theme.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func diffControls(_ git: GitStatus, in folder: WorkspaceFolder) -> some View {
        HStack(spacing: Theme.Space.s) {
            Text("Review")
                .font(Theme.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Spacer()
            Button("Expand all", .more) {
                expandedDiffs.formUnion(git.files.map { diffKey($0, in: folder) })
                Task {
                    for file in git.files {
                        await model.loadDiff(file.path, in: folder.id)
                    }
                }
            }
            .buttonStyle(.borderless)
            Button("Collapse all", .collapse) {
                expandedDiffs.subtract(git.files.map { diffKey($0, in: folder) })
            }
            .buttonStyle(.borderless)
            Button("Review", .preview) {
                model.reviewWorkingTree(in: folder.id)
            }
            // The app's own primary action, not the system blue pill: this
            // button sits in content, beside accent capsules, and a platform
            // control there reads as a different design language on the row.
            .buttonStyle(AccentButtonStyle(small: true))
            .layoutPriority(1)
        }
        .font(Theme.caption)
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
                        .font(Theme.caption2)
                        .foregroundStyle(.tertiary)
                    Spacer()
                }
                .padding(.top, Theme.Space.s)
                ForEach(files) { file in
                    let key = diffKey(file, in: folder)
                    ChangeRow(
                        file: file,
                        isStaged: model.isStaged(file.path, in: folder.id),
                        isOpen: model.isFront(.file(file.path), in: folder.id),
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
    @Bindable var automations: AutomationsModel
    let folder: WorkspaceFolder
    var onOpenAutomation: ((String, String?) -> Void)? = nil

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

    /// Agent backends only. Shell cannot write commit messages from a diff.
    private var commitBackends: [AgentBackend] {
        automations.pickerBackends(keeping: model.autoCommitBackend[folder.id])
            .filter { !$0.models.isEmpty && $0.id != "sh" }
    }

    private var selectedBackend: AgentBackend? {
        let id = model.autoCommitBackend[folder.id]
        return commitBackends.first { $0.id == id } ?? commitBackends.first
    }

    private var selectedModel: String {
        let stored = model.autoCommitModel[folder.id] ?? ""
        if let backend = selectedBackend, backend.models.contains(stored) {
            return stored
        }
        if let backend = selectedBackend, backend.models.contains("haiku") {
            return "haiku"
        }
        return selectedBackend?.models.first ?? ""
    }

    private var hasChanges: Bool {
        guard let git = folder.git, git.isRepo else { return false }
        return !git.files.isEmpty
    }

    private var isAhead: Bool {
        (folder.git?.ahead ?? 0) > 0
    }

    var body: some View {
        Group {
            if hasChanges || isAhead || model.gitOutcome != nil {
                box
            }
        }
        .task {
            if automations.backends.isEmpty {
                await automations.load()
            }
        }
    }

    private var box: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            if let outcome = model.gitOutcome {
                let action = model.gitOutcomeAction
                Banner(
                    text: outcome.ok
                        ? (action?.done ?? "Done.")
                        : (action?.failed ?? "That did not work."),
                    severity: outcome.ok ? .success : .danger,
                    detail: outcome.message
                )
            }
            if let notice = automations.noticeMessage {
                Text(notice)
                    .font(Theme.caption)
                    .foregroundStyle(.secondary)
            }
            if let error = automations.errorMessage {
                Text(error)
                    .font(Theme.caption)
                    .foregroundStyle(Theme.danger)
                    .lineLimit(4)
                    .textSelection(.enabled)
            }

            if hasChanges {
                VStack(spacing: 0) {
                    messageFields
                    hairline
                    actions
                    if !commitBackends.isEmpty {
                        hairline
                        autoCommitRow
                    }
                }
                .background(Theme.panel, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Theme.border, lineWidth: 1)
                )
            } else if isAhead {
                VStack(spacing: 0) {
                    pushOnly
                }
                .background(Theme.panel, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Theme.border, lineWidth: 1)
                )
            }
        }
        .padding(.horizontal, Theme.Space.m)
        .padding(.top, Theme.Space.s)
        .padding(.bottom, Theme.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        // The sidebar surface, like every other footer in the app. On the
        // content's own background the rule above separated nothing and the
        // bar read as loose parts at the bottom of the panel rather than as a
        // place where the actions live.
        .background(Theme.sidebar)
        .overlay(alignment: .top) { ThemeRule() }
    }

    private var hairline: some View { ThemeRule() }

    private var messageFields: some View {
        VStack(spacing: 0) {
            TextField("Commit title", text: title)
                .textFieldStyle(.plain)
                .font(Theme.font(13))
                .lineLimit(1)
                .padding(Theme.Space.s)
            hairline
            TextEditor(text: description)
                .font(Theme.font(12))
                .scrollContentBackground(.hidden)
                .frame(minHeight: 48, maxHeight: 48)
                .padding(.horizontal, Theme.Space.xs)
                .padding(.vertical, 2)
                .overlay(alignment: .topLeading) {
                    if description.wrappedValue.isEmpty {
                        Text("Description (optional)")
                            .font(Theme.font(12))
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, Theme.Space.s)
                            .padding(.vertical, Theme.Space.s)
                            .allowsHitTesting(false)
                    }
                }
        }
    }

    private var actions: some View {
        HStack(spacing: Theme.Space.s) {
            if isAhead {
                Button {
                    Task { await model.push(folder) }
                } label: {
                    ActionIcon.upload.label("Push \(folder.git?.ahead ?? 0)")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(SecondaryButtonStyle())
                .disabled(model.isCommitting)
                .help("Push the current branch")
            }
            Button {
                Task { await model.commit(folder) }
            } label: {
                ActionIcon.commit.label(selectedCount > 0 ? "Commit \(selectedCount)" : "Commit")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(AccentButtonStyle())
            .disabled(model.isCommitting || selectedCount == 0)
        }
        .padding(Theme.Space.s)
    }

    private var pushOnly: some View {
        Button {
            Task { await model.push(folder) }
        } label: {
            ActionIcon.upload.label("Push \(folder.git?.ahead ?? 0)")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(SecondaryButtonStyle())
        .disabled(model.isCommitting)
        .help("Push the current branch")
        .padding(Theme.Space.s)
    }

    private var autoCommitRunning: Bool {
        automations.isAutoCommitRunning(in: folder.id)
    }

    private var autoCommitRow: some View {
        HStack(spacing: Theme.Space.s) {
            Button {
                Task { await runAutoCommit() }
            } label: {
                ActionIcon.run.label(autoCommitRunning ? "Running…" : "Auto commit")
            }
            .buttonStyle(SecondaryButtonStyle())
            .disabled(model.isCommitting || selectedBackend == nil || autoCommitRunning)
            .help(
                autoCommitRunning
                    ? "Auto commit is already running in this folder"
                    : "One-time automation: the chosen agent commits in this folder"
            )
            .fixedSize()

            AppMenuPicker(
                options: commitBackends.map { (value: $0.id, label: $0.label) },
                selection: backendBinding
            )
            if let backend = selectedBackend, !backend.models.isEmpty {
                AppMenuPicker(
                    options: backend.models.map { (value: $0, label: $0) },
                    selection: modelBinding
                )
            }
        }
        .padding(Theme.Space.s)
    }

    private var backendBinding: Binding<String> {
        Binding(
            get: { selectedBackend?.id ?? "" },
            set: { model.autoCommitBackend[folder.id] = $0 }
        )
    }

    private var modelBinding: Binding<String> {
        Binding(
            get: { selectedModel },
            set: { model.autoCommitModel[folder.id] = $0 }
        )
    }

    private func runAutoCommit() async {
        guard let backend = selectedBackend else { return }
        if automations.isAutoCommitRunning(in: folder.id),
           let job = automations.autoCommitJob(in: folder.id)
        {
            onOpenAutomation?(job.id, automations.lastRun(for: job)?.id)
            return
        }
        await automations.startAutoCommit(
            workspaceID: folder.id,
            workspaceName: folder.name,
            backend: backend.id,
            model: selectedModel.isEmpty ? nil : selectedModel
        )
        guard automations.errorMessage == nil,
              let job = automations.autoCommitJob(in: folder.id)
        else { return }
        onOpenAutomation?(job.id, automations.lastRun(for: job)?.id)
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
                    .font(Theme.font(12))
                    .foregroundStyle(isStaged ? Theme.accent : Color.secondary)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .help(isStaged ? "Will be committed" : "Include in the next commit")
            #endif

            Image(systemName: file.kind.symbol)
                .font(Theme.font(11))
                .foregroundStyle(file.kind.tint)
            Button(action: onOpen) {
                Text(file.fileName)
                    .font(Theme.font(13, weight: isOpen ? .medium : .regular))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .help("Open the diff")
            Button(action: onToggleDiff) {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(Theme.caption2.weight(.semibold))
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

#if os(macOS)
/// The machine whose screen the viewer is showing.
///
/// A value rather than a pair of `@State` strings, so "which machine" and
/// "is the viewer up" cannot disagree.
struct RemoteScreenTarget: Identifiable, Hashable {
    let peer: String
    let name: String
    var id: String { peer }
}
#endif
