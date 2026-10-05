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
    @Bindable var ssh: SSHLibraryModel
    @Bindable var sshSessions: SSHSessionsModel
    var onManageServers: () -> Void
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
    /// Whether the remote folder's owner reports no display layer, per peer.
    /// Probed live: the account record carries no platform, so there is
    /// nothing local to gate the viewer on. Keyed by peer because one view
    /// can show folders from several machines; a single Bool lets the last
    /// probe win and hides (or shows) View screen on the wrong folder.
    @State private var ownerHeadless: [String: Bool] = [:]
    @Environment(\.openWindow) private var openWindow
    #endif

    var body: some View {
        VStack(spacing: 0) {
            // Same leading toggles as every other destination, and the
            // project's name, branch and sections from the shell. Trailing
            // is empty because session actions sit on the terminal's row.
            DetailChromeBar {
                EmptyView()
            }
            if let folder = model.selected {
                #if os(macOS)
                // What that computer is doing, where you are working in its
                // folders. This block only existed on Devices, so somebody who
                // opened a machine's workspace could see its files and not
                // whether it was awake or what it was busy with.
                if folder.isRemote, let peer = folder.machineID, !peer.isEmpty {
                    remoteMachine(folder, peer: peer)
                    ThemeRule()
                }
                #else
                ThemeRule()
                #endif
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
                    ssh: ssh,
                    sshSessions: sshSessions,
                    onManageServers: onManageServers,
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
        .task(id: isActive ? model.selectedID : nil) {
            guard isActive, let id = model.selectedID else { return }
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            await chat.warmWorkspacePreviews(id)
        }
        #endif
    }

    #if os(macOS)
    /// Power, CPU and memory for the machine this folder lives on, and the way
    /// on to its screen.
    ///
    /// The same readings the Devices page shows, from the same `HostStatsBar`,
    /// so the two cannot report different things about one computer. The
    /// header also carries Disconnect, because a folder is where a connected
    /// machine is actually used and there was no way back from it. The
    /// auto-connect switch lives on Devices, beside the connection itself.
    private func remoteMachine(_ folder: WorkspaceFolder, peer: String) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            HStack(spacing: Theme.Space.s) {
                Image(systemName: "laptopcomputer")
                    .foregroundStyle(Theme.accent)
                Text(folder.machineLabel ?? L10n.text("apple.workspacesview.remote_machine.d9dd1af3"))
                    .font(Theme.fit(12, weight: .medium))
                Spacer(minLength: 0)
                // A headless server has no display layer. Offering a viewer
                // for it only ends in the viewer's own error, so the button
                // stays off the header entirely.
                if !(ownerHeadless[peer] ?? false) {
                    Button(L10n.text("apple.workspacesview.view_screen.56dea3b5"), .preview) {
                        openWindow(value: RemoteScreenTarget(
                            peer: peer,
                            name: folder.machineLabel ?? L10n.text("apple.workspacesview.remote_machine.d9dd1af3"),
                            tier: tier
                        ))
                    }
                    .buttonStyle(SecondaryButtonStyle(small: true))
                    .fixedSize()
                }
                Button(L10n.text("common.disconnect"), .disconnect) {
                    NotificationCenter.default.post(name: .remotePeerDidDisconnect, object: peer)
                }
                .buttonStyle(SecondaryButtonStyle(small: true))
                .fixedSize()
                .help(L10n.text("apple.workspacesview.stops_showing_this_computer_s_folders_in_t.fae41fce"))
            }
            HostStatsBar(peer: peer, online: true)
        }
        .padding(.horizontal, Theme.Space.m)
        .padding(.bottom, Theme.Space.s)
        .task(id: peer) {
            // An older host that cannot answer leaves the button where it
            // was rather than hiding a viewer that works.
            if let headless = try? await Bridge.peerHeadless(peer) {
                ownerHeadless[peer] = headless
            }
        }
    }
    #endif

    private func terminalPlaceholder(_ folder: WorkspaceFolder) -> some View {
        VStack(spacing: Theme.Space.m) {
            Spacer()
            Image(systemName: "terminal")
                .font(Theme.font(34, weight: .light))
                .foregroundStyle(Theme.accent.opacity(0.65))
            Text(L10n.text("apple.workspacesview.no_terminal_yet.df27bfbb"))
                .font(Theme.title3.weight(.medium))
            Text(L10n.text("apple.workspacesview.this_is_where_sessions_run_claude_code_cod.7d562ef4"))
            .font(Theme.callout)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: 400)
            Text(L10n.text("apple.workspacesview.sessions_are_ready_when_you_are.379c6d86"))
                .font(Theme.caption)
                .foregroundStyle(.tertiary)

            if folder.exists {
                #if os(macOS)
                Button(L10n.text("apple.workspacesview.reveal_in_finder.cc849385"), .reveal) { model.revealInFinder(folder) }
                    .padding(.top, Theme.Space.s)
                #endif
            } else {
                Label(L10n.text("apple.workspacesview.this_folder_is_missing_it_is_kept_in_case.fe3bde5c"),
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
            Text(L10n.text("apple.workspacesview.no_workspaces_yet.97d0b117"))
                .font(Theme.title3.weight(.medium))
            Text(L10n.text("apple.workspacesview.add_a_project_folder_tokenstat_reads_its_g.eced99eb"))
            .font(Theme.callout)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: 360)
            #if os(macOS)
            Button(L10n.text("apple.workspacesview.add_project.44b7ce21"), .create) {
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
                    title: L10n.text("apple.workspacesview.folder_missing.f06c68a6"),
                    subtitle: L10n.text("apple.workspacesview.the_folder_no_longer_exists_on_disk.54b54492"),
                    tint: Theme.warning
                )
            } else if let git = folder.git, git.isRepo, !git.files.isEmpty {
                // Only show the scroll list when there is real content.
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: Theme.Space.m) {
                            content(folder)
                        }
                        .padding(Theme.Space.m)
                    }
                    .onChange(of: model.changeFocus, initial: true) { _, focus in
                        reveal(focus, in: folder, git: git, proxy: proxy)
                    }
                }
            } else {
                // All other states (clean tree, not a git repo) are centred.
                content(folder)
            }
        } else {
            InspectorEmptyState(
                systemImage: "square.stack.3d.up",
                title: L10n.text("apple.workspacesview.no_workspace_selected.12b33b8c"),
                subtitle: L10n.text("apple.workspacesview.pick_a_workspace_from_the_list_on_the_left.ba048561")
            )
        }
    }

    @ViewBuilder
    private func content(_ folder: WorkspaceFolder) -> some View {
        if !folder.exists {
            InspectorEmptyState(
                systemImage: "exclamationmark.triangle",
                title: L10n.text("apple.workspacesview.folder_missing.f06c68a6"),
                subtitle: L10n.text("apple.workspacesview.the_folder_no_longer_exists_on_disk.54b54492"),
                tint: Theme.warning
            )
        } else if let git = folder.git, git.isRepo {
            if git.files.isEmpty {
                InspectorEmptyState(
                    systemImage: "checkmark.seal",
                    title: L10n.text("apple.workspacesview.working_tree_clean.95a0dabb"),
                    subtitle: L10n.text("apple.workspacesview.no_uncommitted_changes_everything_is_up_to.28598d50"),
                    tint: Theme.accent
                )
            } else {
                HStack(alignment: .top, spacing: Theme.Space.s) {
                    summary(git)
                    Spacer(minLength: Theme.Space.s)
                    Button(L10n.text("apple.workspacesview.review_all.d05163fa"), .preview) {
                        model.reviewWorkingTree(in: folder.id)
                    }
                    .buttonStyle(AccentButtonStyle(small: true))
                    .fixedSize()
                    .help(L10n.text("apple.workspacesview.review_all_changes_including_files_not_sel.aa125b4a"))
                    .accessibilityLabel(L10n.text("apple.workspacesview.review_all_changes.24320120"))
                }
                diffControls(git, in: folder)
                changeSection(L10n.text("apple.workspacesview.selected_for_commit.938f04f0"), files: git.files.filter { model.isStaged($0.path, in: folder.id) }, in: folder)
                changeSection(L10n.text("apple.workspacesview.not_selected.df12aeba"), files: git.files.filter { !model.isStaged($0.path, in: folder.id) }, in: folder)
            }
        } else {
            InspectorEmptyState(
                systemImage: "arrow.triangle.branch",
                title: L10n.text("apple.workspacesview.not_a_git_repository.f903b388"),
                subtitle: L10n.text("apple.workspacesview.this_folder_has_no_branch_files_are_still.ec672a00")
            )
        }
    }

    #if os(macOS)
    /// Tick or clear everything at once. The label says which way it will go,
    /// rather than being a tri-state box that makes you guess.
    private func selectAll(_ git: GitStatus, in folder: WorkspaceFolder) -> some View {
        let selected = (model.stagedSelection[folder.id] ?? []).intersection(git.files.map(\.path)).count
        let all = selected == git.files.count
        return HStack(spacing: Theme.Space.s) {
            Toggle(L10n.text("apple.workspacesview.select_all.1fc9a387"), isOn: Binding(
                get: { all },
                set: { model.setAllStaged($0, in: folder) }
            ))
            .toggleStyle(.brandCheckbox)
            Spacer(minLength: 0)
            Text(L10n.text("apple.workspacesview.0_of_1_selected.d06c59a5", "\(selected)", "\(git.files.count)"))
                .foregroundStyle(.secondary)
        }
        .font(Theme.caption)
        .help(L10n.text("apple.workspacesview.choose_which_files_the_commit_button_inclu.6bbf708b"))
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
                Text((git.files.count == 1 ? L10n.text("apple.workspacesview.0_file_1.ac963029.one", "\(git.files.count)") : L10n.text("apple.workspacesview.0_file_1.ac963029.other", "\(git.files.count)")))
                    .font(Theme.caption)
                    .foregroundStyle(.secondary)
            }
            if git.partial {
                // Untracked and binary files have no line counts, so saying
                // "+120" flat would be a number nobody measured.
                Text(L10n.text("apple.workspacesview.some_files_have_no_line_counts_so_these_to.9aa88eb4"))
                    .font(Theme.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func diffControls(_ git: GitStatus, in folder: WorkspaceFolder) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            Menu {
            Button(L10n.text("apple.workspacesview.expand_all.a3e586be"), .more) {
                expandedDiffs.formUnion(git.files.map { diffKey($0, in: folder) })
            }
            .buttonStyle(.borderless)
            Button(L10n.text("apple.workspacesview.collapse_all.25f7b372"), .collapse) {
                expandedDiffs.subtract(git.files.map { diffKey($0, in: folder) })
            }
            .buttonStyle(.borderless)
            } label: {
                Label(L10n.text("apple.workspacesview.inline_previews.b3aaf348"), systemImage: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            #if os(macOS)
            ThemeRule()
            selectAll(git, in: folder)
            #endif
        }
        .font(Theme.caption)
        .padding(.top, Theme.Space.s)
    }

    @ViewBuilder
    private func changeSection(_ title: String, files: [FileChange], in folder: WorkspaceFolder) -> some View {
        if !files.isEmpty {
            HStack {
                Text(title.uppercased()).font(Theme.sectionHeader).foregroundStyle(.tertiary)
                Text("\(files.count)").font(Theme.caption2).foregroundStyle(.tertiary)
                Spacer()
            }.padding(.top, Theme.Space.s)
            ForEach(files) { file in
                let key = diffKey(file, in: folder)
                VStack(alignment: .leading, spacing: Theme.Space.xs) {
                    ChangeRow(
                        file: file,
                        isStaged: model.isStaged(file.path, in: folder.id),
                        isOpen: model.isFront(.file(file.path), in: folder.id),
                        isExpanded: expandedDiffs.contains(key),
                        onToggle: { model.toggleStaged(file.path, in: folder.id) },
                        onToggleDiff: {
                            if expandedDiffs.contains(key) { expandedDiffs.remove(key) }
                            else { expandedDiffs.insert(key) }
                        },
                        onOpen: { Task { await model.openFile(file.path, in: folder.id) } }
                    )
                    if expandedDiffs.contains(key) {
                        VStack(alignment: .leading, spacing: Theme.Space.xs) {
                            if let error = model.diffError(for: file.path, in: folder.id) {
                                Text(error).font(Theme.callout).foregroundStyle(Theme.danger)
                                Button(L10n.text("common.retry"), .refresh) {
                                    Task { await model.loadDiff(file.path, in: folder.id) }
                                }.buttonStyle(SecondaryButtonStyle(small: true))
                            } else if let diff = model.diff(for: file.path, in: folder.id) {
                                InlineDiffView(diff: diff) { model.reviewWorkingTree(in: folder.id) }
                            } else {
                                ProgressView().controlSize(.small)
                            }
                        }
                        .padding(.leading, Theme.Space.l)
                        .onAppear { model.retainDiffPreview(file.path, in: folder.id) }
                        .task(id: "\(key)|\(model.diffRefreshRevisions[folder.id] ?? 0)") {
                            await model.loadPreviewDiff(file.path, in: folder.id)
                        }
                        .onDisappear { model.releaseDiffPreview(file.path, in: folder.id) }
                    }
                }
                .id(key)
            }
        }
    }

    private func diffKey(_ file: FileChange, in folder: WorkspaceFolder) -> String {
        "\(folder.id):\(file.path)"
    }

    /// Open and show the file a chat asked for. An agent names files by
    /// absolute path and git by path inside the repository, so the match is
    /// on the end of the path.
    private func reveal(_ focus: WorkspacesModel.ChangeFocus?, in folder: WorkspaceFolder, git: GitStatus, proxy: ScrollViewProxy) {
        guard let focus, focus.folderID == folder.id else { return }
        model.consumeChangeFocus(focus)
        guard let path = ChangePathMatch.path(focus.path, in: git.files.map(\.path)),
              let file = git.files.first(where: { $0.path == path }) else { return }
        let key = diffKey(file, in: folder)
        expandedDiffs.insert(key)
        withAnimation(.easeOut(duration: 0.2)) {
            proxy.scrollTo(key, anchor: .top)
        }
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
    @State private var showingCommitHelp = false
    @State private var commitSession: GitCommitSession?
    @State private var savedCommitSession: GitCommitSession?

    private var title: Binding<String> {
        Binding(
            get: { model.commitMessage[folder.id] ?? "" },
            set: {
                model.commitMessage[folder.id] = $0
                saveInlineDraft()
            }
        )
    }

    private var description: Binding<String> {
        Binding(
            get: { model.commitDescription[folder.id] ?? "" },
            set: {
                model.commitDescription[folder.id] = $0
                saveInlineDraft()
            }
        )
    }

    private var selectedCount: Int {
        model.stagedSelection[folder.id]?.count ?? 0
    }

    private func saveInlineDraft() {
        guard let session = savedCommitSession, session.loaded,
              session.target == Bridge.reviewedGitTarget(id: folder.id),
              !session.working, session.draft.submitted == nil, commitSession == nil else { return }
        session.draft.title = model.commitMessage[folder.id, default: ""]
        session.draft.details = model.commitDescription[folder.id, default: ""]
        session.setSelection(model.stagedSelection[folder.id] ?? [])
        Task { await session.persist() }
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

    var body: some View {
        Group {
            if folder.git?.isRepo == true || model.gitOutcome(for: folder.id) != nil || savedCommitSession?.draft.submitted != nil {
                box
            }
        }
        .task(id: folder.id) {
            savedCommitSession = nil
            let target = Bridge.reviewedGitTarget(id: folder.id)
            if target.peer == nil { await WorkSessionContext.shared.resolveLocalHostIdentity() }
            guard !Task.isCancelled else { return }
            let saved = GitCommitSessions.session(target: target)
            await saved.load()
            guard !Task.isCancelled else { return }
            savedCommitSession = saved
            if model.commitMessage[folder.id, default: ""].isEmpty {
                model.commitMessage[folder.id] = saved.draft.title
                model.commitDescription[folder.id] = saved.draft.details
            }
            if model.stagedSelection[folder.id] == nil {
                model.stagedSelection[folder.id] = saved.draft.paths.intersection(Set((folder.git?.files ?? []).map(\.path)))
            }
            if automations.backends.isEmpty {
                await automations.load()
            }
        }
        .onChange(of: model.stagedSelection[folder.id]) { _, _ in saveInlineDraft() }
        .sheet(item: $commitSession) { session in
            GitCommitComposer(session: session, folderName: folder.name, hostName: "", onCommitted: {
                await model.commitCompleted(folder)
            })
            .onDisappear {
                model.commitMessage[folder.id] = session.draft.title
                model.commitDescription[folder.id] = session.draft.details
            }
        }
    }

    private var box: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            if let saved = savedCommitSession, saved.draft.submitted != nil {
                Button(L10n.text("apple.workspacesview.check_submitted_commit.47abb7aa"), .refresh) { commitSession = saved }
                    .buttonStyle(AccentButtonStyle(comfortable: true))
            }
            if let outcome = model.gitOutcome(for: folder.id) {
                let action = model.gitOutcomeAction(for: folder.id)
                Banner(
                    text: outcome.ok
                        ? (action?.done ?? L10n.text("apple.workspacesview.done.ed251864"))
                        : (action?.failed ?? L10n.text("apple.workspacesview.that_did_not_work.8816661d")),
                    severity: outcome.ok ? .success : .danger,
                    detail: outcome.message,
                    onDismiss: { model.dismissGitOutcome(for: folder.id) }
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
                        .disabled(savedCommitSession?.loaded != true || savedCommitSession?.working == true || savedCommitSession?.draft.submitted != nil)
                    hairline
                    actions
                    hairline
                    syncRow
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
            } else if folder.git?.isRepo == true {
                VStack(spacing: 0) {
                    syncRow
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
            TextField(L10n.text("apple.workspacesview.commit_title.30459372"), text: title)
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
                        Text(L10n.text("apple.workspacesview.description_optional.f6cbe2f0"))
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
            Button {
                Task { commitSession = await model.prepareCommit(folder) }
            } label: {
                ActionIcon.commit.label(selectedCount > 0 ? L10n.text("apple.workspacesview.commit_0.20f6d192", "\(selectedCount)") : L10n.text("apple.workspacesview.commit.82a9c46f"))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(AccentButtonStyle(comfortable: true))
            .disabled(model.isCommitting || selectedCount == 0)
        }
        .padding(Theme.Space.s)
    }

    /// Bring commits in, send them out, and the pull request they belong
    /// to. One row, so the whole round trip is in one place.
    private var syncRow: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: Theme.Space.s) { syncControls }
            VStack(alignment: .leading, spacing: Theme.Space.s) { syncControls }
        }
        .padding(Theme.Space.s)
    }

    @ViewBuilder
    private var syncControls: some View {
        GitPullControl(target: Bridge.reviewedGitTarget(id: folder.id), folderName: folder.name,
                       hostName: "", incoming: folder.git?.behind ?? 0,
                       onPulled: { await model.pullRefreshed(folder) })
        pushControl
        GitBranchPullControl(workspaceID: folder.id, peer: nil, branch: folder.git?.branch,
                             folderName: folder.name, hostName: "")
    }

    private var pushControl: some View {
        GitPushControl(target: Bridge.reviewedGitTarget(id: folder.id), folderName: folder.name,
                       hostName: "", outgoing: folder.git?.ahead ?? 0,
                       onPushed: { await model.pushCompleted(folder) })
    }

    private var autoCommitRunning: Bool {
        automations.isAutoCommitRunning(in: folder.id)
    }

    private var autoCommitRow: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
          HStack(spacing: Theme.Space.s) {
            Button {
                Task { await runAutoCommit() }
            } label: {
                ActionIcon.run.label(autoCommitRunning ? L10n.text("apple.workspacesview.running.46c54136") : L10n.text("apple.workspacesview.auto_commit.2559934f"))
            }
            .buttonStyle(SecondaryButtonStyle())
            .disabled(model.isCommitting || selectedBackend == nil || autoCommitRunning)
            .help(
                autoCommitRunning
                    ? L10n.text("apple.workspacesview.auto_commit_is_already_running_in_this_fol.eba93f91")
                    : L10n.text("apple.workspacesview.one_time_automation_the_chosen_agent_commi.983f2690")
            )
            .fixedSize()
            Spacer(minLength: 0)
            Button { showingCommitHelp = true } label: {
                Image(systemName: ActionIcon.help.symbol)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.accent)
            .accessibilityLabel(L10n.text("apple.workspacesview.about_commit_actions.5c3bba32"))
            .help(L10n.text("apple.workspacesview.about_commit_actions.5c3bba32"))
            .popover(isPresented: $showingCommitHelp) {
                VStack(alignment: .leading, spacing: Theme.Space.m) {
                    Text(L10n.text("apple.workspacesview.commit_actions.2b927b6f")).font(Theme.headline)
                    Text(L10n.text("apple.workspacesview.commit_stages_the_selected_files_and_commi.de1a6db4"))
                    Text(L10n.text("apple.workspacesview.push_publishes_existing_local_commits_to_t.a9bbfe5a"))
                    Text(L10n.text("apple.workspacesview.auto_commit_runs_the_chosen_agent_once_in.2f7d19c7"))
                }
                .font(Theme.callout)
                .padding(Theme.Space.l)
                .frame(width: 320)
            }
          }
          HStack(spacing: Theme.Space.s) {
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
            .help(isStaged ? L10n.text("apple.workspacesview.will_be_committed.e9764743") : L10n.text("apple.workspacesview.include_in_the_next_commit.5d7f428d"))
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
            .help(L10n.text("apple.workspacesview.open_the_diff.55d1e169"))
            Button(action: onToggleDiff) {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(Theme.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help(isExpanded ? L10n.text("apple.workspacesview.collapse_diff.b5d061d1") : L10n.text("apple.workspacesview.expand_diff.ad6cc669"))
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
                Text(L10n.text("apple.workspacesview.n_a.a683c5c5")).font(Theme.numeric(11)).foregroundStyle(.tertiary)
            }
        }
        .help(file.path)
    }
}

#if os(macOS)
/// The machine whose screen the viewer is showing.
///
/// A value rather than a pair of `@State` strings, so "which machine" and
/// "is the viewer up" cannot disagree. `Codable` because this is also the
/// identity of the viewer's own window: a sheet cannot go full screen.
struct RemoteScreenTarget: Identifiable, Hashable, Codable {
    var peer: String
    var name: String
    var tier: String?
    var id: String { peer }
}
#endif
