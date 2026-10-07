// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

#if !os(macOS)
import SwiftUI

/// A project workbench. Sections sit above the content, like the Mac, leaving
/// the available width to the work instead of a second navigation column.
struct ClientFolderSplit: View {
    let peer: String
    let hostName: String
    let folder: WorkspaceFolder

    var selection: Binding<WorkspaceSection>? = nil
    @Environment(ClientNavigationModel.self) private var navigation
    @State private var owner = WorkSessionContext.shared.scope
    @State private var reloadRevision = UUID()
    @State private var live: WorkspaceFolder?
    @State private var counts = WorkspaceSectionCounts()
    @State private var pullCounts = PullCountStore.shared
    @State private var errorMessage: String?
    @State private var showPort = false
    @State private var showWorktrees = false
    @State private var portText = "5173"
    @State private var browserSession: ProjectBrowserSession?
    @State private var isOpeningPort = false

    private var workspaceID: String {
        ClientRemote.rawWorkspaceID(of: folder) ?? folder.id
    }

    private var browserOwner: WorkReference? {
        WorkViewedChange.owner(folderID: workspaceID, peer: peer)
    }


    private var current: WorkspaceFolder {
        guard var merged = live else { return folder }
        merged.id = folder.id
        merged.machineID = folder.machineID
        merged.machineLabel = folder.machineLabel
        return merged
    }

    private var section: WorkspaceSection {
        get { selection?.wrappedValue ?? navigation.projectSections[.init(peer: peer, workspace: workspaceID)] ?? .sessions }
        nonmutating set {
            navigation.projectSections[.init(peer: peer, workspace: workspaceID)] = newValue
            selection?.wrappedValue = newValue
        }
    }

    var body: some View {
        split
        .background(Theme.background)
        .navigationTitle(current.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                ClientProjectRenameButton(peer: peer, folder: current, onChanged: { await reload() })
            }
        }
        .refreshable {
            await ClientRefresh.pull("workspace-\(workspaceID)") { await reload() }
        }
        .task { await reload() }
        .onReceive(NotificationCenter.default.publisher(for: GitCommitTarget.didChange)) { note in
            guard note.object as? GitCommitTarget == GitCommitTarget(peer: peer, workspaceID: workspaceID) else { return }
            Task { await reload() }
        }
        .sheet(isPresented: $showPort) { portSheet.onAppear { portText = BrowserHistory.shared.portSuggestion(for: browserOwner) } }
        .sheet(isPresented: $showWorktrees) {
            RemoteHostFeatureGate(feature: .worktrees, peer: peer, hostName: hostName) {
                ProjectWorktreeSheet(folder: remoteFolder) { created in
                    showWorktrees = false
                    var remote = created
                    remote.id = "remote:\(peer):\(created.id)"
                    remote.machineID = peer
                    remote.machineLabel = hostName
                    navigation.pushFolder(peerKey: peer, hostName: hostName, folder: remote, section: .sessions)
                }
            }
        }
        .fullScreenCover(item: Binding(
            get: { browserSession },
            set: { if $0 == nil { closeBrowser() } }
        )) { session in
            ClientBrowserScreen(session: session) { closeBrowser() }
        }
        .onChange(of: WorkSessionContext.shared.scope) { _, _ in closeBrowser() }
        .onChange(of: folder.id) { _, _ in closeBrowser() }
    }

    private var split: some View {
        VStack(spacing: 0) {
            if section == .sessions {
                ClientFolderBranchRow(peer: peer, workspaceID: workspaceID, folder: current,
                                      onChanged: { await reload() })
                    .padding(.horizontal, Theme.Space.m)
                    .padding(.vertical, Theme.Space.xs)
            }
            if let errorMessage {
                ClientErrorCard(message: errorMessage) { Task { await reload() } }
                    .padding(Theme.Space.s)
            }
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .clientHideScrollEdgeEffect(for: .top)
        }
        .clientTopBar {
            VStack(spacing: 0) {
                sectionsStrip
                ThemeRule()
            }
            .background(Theme.background)
        }
    }

    private var sectionsStrip: some View {
        ViewThatFits(in: .horizontal) {
            sectionButtons(WorkspaceSection.allCases, showsCounts: true)
            sectionButtons(WorkspaceSection.allCases, showsCounts: false)
            sectionButtons([.sessions, .chat, .changes], showsCounts: false,
                           more: WorkspaceSection.allCases.filter { ![.sessions, .chat, .changes].contains($0) })
            sectionButtons([section], showsCounts: false,
                           more: WorkspaceSection.allCases.filter { $0 != section })
            sectionMenu(WorkspaceSection.allCases)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Theme.Space.s)
        .padding(.vertical, Theme.Space.xs)
    }

    private func sectionButtons(_ choices: [WorkspaceSection], showsCounts: Bool,
                                more: [WorkspaceSection] = []) -> some View {
        HStack(spacing: Theme.Space.xs) {
            ForEach(choices) { item in
                Button { choose(item) } label: {
                    HStack(spacing: Theme.Space.xs) {
                        Label(item.label, systemImage: item.symbol)
                        if showsCounts, let value = count(for: item), value > 0 {
                            Text("\(value)").monospacedDigit().foregroundStyle(.secondary)
                        }
                    }
                    .font(ClientType.caption.weight(item == section ? .semibold : .regular))
                    .foregroundStyle(item == section ? Theme.accent : Color.secondary)
                    .padding(.horizontal, Theme.Space.s)
                    .frame(minHeight: Theme.Control.heightComfortable)
                    .background(item == section ? Theme.accentSoft : Color.clear,
                                in: RoundedRectangle(cornerRadius: 8))
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(item == section ? .isSelected : [])
            }
            if !more.isEmpty {
                sectionMenu(more)
            } else if current.git?.isRepo == true {
                Button { showWorktrees = true } label: {
                    Label(L10n.text("apple.clientworkspacesections.worktrees.aec2f93d"), systemImage: "arrow.triangle.branch")
                        .font(ClientType.caption)
                        .padding(.horizontal, Theme.Space.s)
                        .frame(minHeight: Theme.Control.heightComfortable)
                }
                .buttonStyle(.plain)
            }
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private func sectionMenu(_ choices: [WorkspaceSection]) -> some View {
        let selected = choices.first { $0 == section }
        return Menu {
            ForEach(choices) { item in
                Button { choose(item) } label: {
                    Label(count(for: item).flatMap { $0 > 0 ? "\(item.label), \($0)" : nil } ?? item.label,
                          systemImage: item.symbol)
                }
                .accessibilityAddTraits(item == section ? .isSelected : [])
            }
            if current.git?.isRepo == true {
                Button(L10n.text("apple.clientworkspacesections.worktrees.aec2f93d"), systemImage: "arrow.triangle.branch") {
                    showWorktrees = true
                }
            }
        } label: {
            Label(selected?.label ?? L10n.text("apple.shellchrome.more.d47d7cb0"),
                  systemImage: selected?.symbol ?? "ellipsis")
                .font(ClientType.caption.weight(selected == nil ? .regular : .semibold))
                .foregroundStyle(selected == nil ? Color.secondary : Theme.accent)
                .padding(.horizontal, Theme.Space.s)
                .frame(minHeight: Theme.Control.heightComfortable)
                .background(selected == nil ? Color.clear : Theme.accentSoft,
                            in: RoundedRectangle(cornerRadius: 8))
        }
        .accessibilityLabel(selected?.label ?? L10n.text("apple.shellchrome.more_sections.a8e35e36"))
        .accessibilityAddTraits(selected == nil ? [] : .isSelected)
    }

    private func choose(_ item: WorkspaceSection) {
        if item == .browser { showPort = true }
        else {
            if item != section { navigation.chooseNavigation() }
            section = item
        }
    }

    private var remoteFolder: WorkspaceFolder {
        var remote = current
        remote.id = "remote:\(peer):\(workspaceID)"
        remote.machineID = peer
        remote.machineLabel = hostName
        return remote
    }

    @ViewBuilder
    private var detail: some View {
        ClientWorkspaceSectionDetail(
            peer: peer,
            hostName: hostName,
            folder: folder,
            current: current,
            section: section,
            workbench: true
        )
    }

    private func count(for section: WorkspaceSection) -> Int? {
        switch section {
        case .sessions: return counts.sessions
        case .chat: return counts.chats
        case .changes: return counts.changes
        case .history: return nil
        case .pulls: return counts.pulls > 0
            ? counts.pulls
            : pullCounts.count(workspaceID: workspaceID, peer: peer)
        case .todo: return counts.todo
        case .workflows: return counts.workflows
        case .automations: return counts.automations
        case .notes: return counts.notes
        case .files, .browser: return nil
        }
    }

    private var portSheet: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(L10n.text("apple.clientfoldersplit.port.72e9a59f"), text: $portText)
                        .keyboardType(.numberPad)
                    ClientRecentBrowserPorts(owner: browserOwner, portText: $portText)
                } footer: {
                    Text(L10n.text("apple.clientfoldersplit.opens_a_loopback_bridge_to_that_port_on_0.53f0e3cb", "\(hostName)"))
                }
            }
            .navigationTitle(L10n.text("apple.clientfoldersplit.browse_port.d3b57f13"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.text("common.cancel")) { showPort = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.text("common.open")) { Task { await openPort() } }
                        .disabled(isOpeningPort || BrowserTarget.parsePort(portText) == nil)
                }
            }
        }
        .presentationDetents([.medium])
    }

    private func reload() async {
        let revision = UUID()
        reloadRevision = revision
        let owner = owner
        guard owner != nil, owner == WorkSessionContext.shared.scope else { return }
        async let status = try? ClientRemote.status(peer: peer, workspace: workspaceID)
        async let counted = ClientRemote.summaries(peer: peer)
        let fresh = await status
        let summaries: [WorkspaceSummary]
        do {
            summaries = try await counted
        } catch {
            guard !Task.isCancelled, owner == WorkSessionContext.shared.scope, reloadRevision == revision else { return }
            errorMessage = ClientTunnelCopy.display(error.localizedDescription, host: hostName)
            return
        }
        guard !Task.isCancelled, owner == WorkSessionContext.shared.scope, reloadRevision == revision else { return }
        if let fresh, fresh != live { live = fresh }
        errorMessage = nil
        guard let summary = summaries.first(where: { $0.id == workspaceID }) else {
            counts.changes = current.git?.files.count ?? counts.changes
            return
        }
        counts = WorkspaceSectionCounts(
            sessions: summary.sessions,
            chats: summary.chats ?? 0,
            changes: summary.changed ?? current.git?.files.count ?? 0,
            pulls: summary.pulls ?? pullCounts.count(workspaceID: workspaceID, peer: peer) ?? 0,
            todo: summary.tasks,
            notes: summary.notes ?? 0,
            automations: summary.automations,
            workflows: summary.workflowsRunning > 0 ? summary.workflowsRunning : summary.workflows
        )
        errorMessage = nil
    }

    private func closeBrowser() {
        browserSession?.close()
        browserSession = nil
    }

    private func openPort() async {
        guard !isOpeningPort, let port = BrowserTarget.parsePort(portText),
              let target = BrowserHistory.shared.target(for: browserOwner, port: port) else { return }
        isOpeningPort = true
        defer { isOpeningPort = false }
        let session = ProjectBrowserOwner.make(workspaceID: workspaceID, peer: peer)
        await session.open(target.url)
        guard session.owner == browserOwner, !Task.isCancelled else {
            session.close()
            return
        }
        if let error = session.error {
            errorMessage = ClientTunnelCopy.display(error, host: hostName)
            session.close()
            return
        }
        guard !session.transportURL.isEmpty else { return }
        closeBrowser()
        browserSession = session
        showPort = false
    }
}


/// One of a folder's sections, drawn on its own.
///
/// Shared by compact pushes and the project workbench's section strip.
struct ClientWorkspaceSectionDetail: View {
    let peer: String
    let hostName: String
    /// What the list this came from knew, and the freshest read of it. The
    /// split view has both, and the sidebar passes the same folder twice.
    let folder: WorkspaceFolder
    var current: WorkspaceFolder?
    let section: WorkspaceSection
    var workbench = false
    private var workspaceID: String {
        ClientRemote.rawWorkspaceID(of: folder) ?? folder.id
    }

    private var folderNow: WorkspaceFolder { current ?? folder }

    var body: some View {
        sectionContent.rememberWorkspace(peer: peer, folder: folder, section: section)
    }

    @ViewBuilder private var sectionContent: some View {
        switch section {
        case .sessions:
            ClientWorkspaceSessionsView(peer: peer, hostName: hostName, folder: folder,
                title: workbench ? folderNow.name : nil)
        case .chat:
            RemoteHostFeatureGate(feature: .chat, peer: peer, hostName: hostName) {
                ClientChatView(peer: peer, workspaceID: workspaceID, folderName: folderNow.name, hostName: hostName, folder: folderNow)
            }
        case .changes:
            ClientWorkspaceChangesView(
                peer: peer,
                workspaceID: workspaceID,
                folder: folderNow,
                hostName: hostName
            )
            .id(GitCommitTarget(peer: peer, workspaceID: workspaceID))
        case .history:
            ClientWorkspaceHistoryView(
                peer: peer,
                workspaceID: workspaceID,
                folder: folderNow,
                hostName: hostName
            )
        case .pulls:
            PullsView(
                workspaceID: workspaceID,
                peer: peer,
                connectionHostName: hostName,
                workspaceName: folder.name,
                workspaceIsRemote: true
            )
        case .todo:
            ClientWorkspaceTasksView(
                peer: peer,
                workspaceID: workspaceID,
                hostName: hostName,
                folderName: folderNow.name
            )
        case .workflows:
            ClientWorkflowWorkspace(
                peer: peer,
                workspaceID: workspaceID,
                hostName: hostName,
                folderName: folderNow.name
            )
            .id(ClientJobWorkspaceID(peer: peer, workspace: workspaceID))
        case .automations:
            ClientAutomationWorkspace(
                peer: peer,
                workspaceID: workspaceID,
                hostName: hostName,
                folderName: folderNow.name
            )
            .id(ClientJobWorkspaceID(peer: peer, workspace: workspaceID))
        case .notes:
            ClientWorkspaceNotesView(
                peer: peer,
                workspaceID: workspaceID,
                hostName: hostName,
                folderName: folderNow.name
            )
        case .files:
            ClientFilesView(peer: peer, workspace: workspaceID, folderName: folder.name)
        case .browser:
            ClientWorkspaceSessionsView(peer: peer, hostName: hostName, folder: folder)
        }
    }
}

#endif
