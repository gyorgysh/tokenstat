// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available: source sharing and own builds are permitted.
// Store and commercial distribution of builds is reserved. See LICENSE.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

#if !os(macOS)
import SwiftUI
import UIKit

struct ClientWorkspaceDetailView: View {
    let peer: String
    let hostName: String
    let folder: WorkspaceFolder

    @State private var live: WorkspaceFolder?
    @State private var counts = WorkspaceSectionCounts()
    @State private var pullCounts = PullCountStore.shared
    @State private var errorMessage: String?
    @State private var showPort = false
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

    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(ClientNavigationModel.self) private var navigation

    private var usesWorkspaceLayout: Bool {
        ClientLayout.hasRoom(horizontal: sizeClass, vertical: verticalSizeClass)
    }

    var body: some View {
        Group {
            if usesWorkspaceLayout {
                ClientFolderSplit(peer: peer, hostName: hostName, folder: folder)
            } else {
                stacked
            }
        }
        .rememberWorkspace(peer: peer, folder: folder,
            section: usesWorkspaceLayout ? navigation.projectSections[.init(peer: peer, workspace: workspaceID)] ?? .sessions : nil)
        .onReceive(NotificationCenter.default.publisher(for: GitCommitTarget.didChange)) { note in
            guard !usesWorkspaceLayout,
                  note.object as? GitCommitTarget == GitCommitTarget(peer: peer, workspaceID: workspaceID) else { return }
            Task { await reload() }
        }
        .toolbar {
            if !usesWorkspaceLayout {
                ToolbarItem(placement: .primaryAction) {
                    ClientProjectRenameButton(peer: peer, folder: current, onChanged: { await reload() })
                }
            }
            ToolbarItem(placement: .primaryAction) {
                WorkFolderCacheButton(folderID: workspaceID, peer: peer, name: folder.name)
            }
        }
    }

    private var stacked: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                if let errorMessage {
                    ClientErrorCard(message: errorMessage) {
                        Task { await reload() }
                    }
                }
                headerCard
                sections
            }
            .padding(.horizontal, Theme.Space.m)
            .padding(.top, Theme.Space.s)
            .padding(.bottom, 96)
        }
        .background(Theme.background)
        .navigationTitle(current.name)
        .navigationBarTitleDisplayMode(.inline)
        .refreshable {
            await ClientRefresh.pull("workspace-\(workspaceID)") { await reload() }
        }
        .task { await reload() }
        .sheet(isPresented: $showPort) { portSheet.onAppear { portText = BrowserHistory.shared.portSuggestion(for: browserOwner) } }
        .fullScreenCover(item: Binding(
            get: { browserSession },
            set: { if $0 == nil { closeBrowser() } }
        )) { session in
            ClientBrowserScreen(session: session) { closeBrowser() }
        }
        .onChange(of: WorkSessionContext.shared.scope) { _, _ in closeBrowser() }
        .onChange(of: folder.id) { _, _ in closeBrowser() }
    }

    private var headerCard: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            Text(hostName)
                .font(ClientType.caption)
                .foregroundStyle(.secondary)
            Text(current.path)
                .font(ClientType.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .truncationMode(.middle)
            ClientFolderBranchRow(
                peer: peer,
                workspaceID: workspaceID,
                folder: current,
                onChanged: { await reload() }
            )
        }
        .padding(Theme.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
    }

    @ViewBuilder
    private var sections: some View {
        VStack(spacing: Theme.Space.s) {
            NavigationLink {
                ClientWorkspaceSessionsView(peer: peer, hostName: hostName, folder: folder)
                .rememberWorkspace(peer: peer, folder: folder, section: .sessions)
            } label: {
                ClientSectionRow(section: .sessions, count: counts.sessions)
            }
            .buttonStyle(.plain)

            ClientOwnedNavigationLink {
                RemoteHostFeatureGate(feature: .chat, peer: peer, hostName: hostName) {
                    ClientChatView(peer: peer, workspaceID: workspaceID, folderName: current.name, hostName: hostName, folder: current)
                }
                .rememberWorkspace(peer: peer, folder: folder, section: .chat)
            } label: {
                ClientSectionRow(section: .chat, count: counts.chats)
            }
            .buttonStyle(.plain)

            NavigationLink {
                ClientWorkspaceChangesView(
                    peer: peer,
                    workspaceID: workspaceID,
                    folder: current,
                    hostName: hostName
                )
                .id(GitCommitTarget(peer: peer, workspaceID: workspaceID))
                .rememberWorkspace(peer: peer, folder: folder, section: .changes)
            } label: {
                ClientSectionRow(section: .changes, count: counts.changes)
            }
            .buttonStyle(.plain)

            NavigationLink {
                ClientWorkspaceHistoryView(
                    peer: peer,
                    workspaceID: workspaceID,
                    folder: current,
                    hostName: hostName
                )
                .rememberWorkspace(peer: peer, folder: folder, section: .history)
            } label: {
                ClientSectionRow(section: .history, count: nil)
            }
            .buttonStyle(.plain)

            if current.git?.isRepo == true {
                ClientProjectWorktreesButton(peer: peer, hostName: hostName, folder: current)
            }

            NavigationLink {
                PullsView(
                    workspaceID: workspaceID,
                    peer: peer,
                    connectionHostName: hostName,
                    workspaceName: folder.name,
                    workspaceIsRemote: true
                )
                    .navigationTitle(L10n.text("apple.clientworkspacesections.pull_requests.d9e3f260"))
                    .navigationBarTitleDisplayMode(.inline)
                .rememberWorkspace(peer: peer, folder: folder, section: .pulls)
            } label: {
                ClientSectionRow(
                    section: .pulls,
                    count: counts.pulls > 0
                        ? counts.pulls
                        : pullCounts.count(workspaceID: workspaceID, peer: peer)
                )
            }
            .buttonStyle(.plain)

            NavigationLink {
                ClientWorkspaceTasksView(
                    peer: peer,
                    workspaceID: workspaceID,
                    hostName: hostName,
                    folderName: folder.name
                )
                .rememberWorkspace(peer: peer, folder: folder, section: .todo)
            } label: {
                ClientSectionRow(section: .todo, count: counts.todo)
            }
            .buttonStyle(.plain)

            NavigationLink {
                ClientWorkspaceNotesView(
                    peer: peer,
                    workspaceID: workspaceID,
                    hostName: hostName,
                    folderName: current.name
                )
                .rememberWorkspace(peer: peer, folder: folder, section: .notes)
            } label: {
                ClientSectionRow(section: .notes, count: counts.notes)
            }
            .buttonStyle(.plain)

            NavigationLink {
                ClientWorkspaceWorkflowsView(
                    peer: peer,
                    workspaceID: workspaceID,
                    hostName: hostName,
                    folderName: current.name
                )
                .rememberWorkspace(peer: peer, folder: folder, section: .workflows)
            } label: {
                ClientSectionRow(section: .workflows, count: counts.workflows)
            }
            .buttonStyle(.plain)

            NavigationLink {
                ClientWorkspaceAutomationsView(
                    peer: peer,
                    workspaceID: workspaceID,
                    hostName: hostName,
                    folderName: current.name
                )
                .rememberWorkspace(peer: peer, folder: folder, section: .automations)
            } label: {
                ClientSectionRow(section: .automations, count: counts.automations)
            }
            .buttonStyle(.plain)

            NavigationLink {
                ClientFilesView(peer: peer, workspace: workspaceID, folderName: folder.name)
                .rememberWorkspace(peer: peer, folder: folder, section: .files)
            } label: {
                ClientSectionRow(section: .files, count: nil)
            }
            .buttonStyle(.plain)

            Button {
                showPort = true
            } label: {
                ClientSectionRow(section: .browser, count: nil)
            }
            .buttonStyle(.plain)
        }
    }

    private var portSheet: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(L10n.text("apple.clientworkspacesections.port.72e9a59f"), text: $portText)
                        .keyboardType(.numberPad)
                    ClientRecentBrowserPorts(owner: browserOwner, portText: $portText)
                } footer: {
                    Text(L10n.text("apple.clientworkspacesections.opens_a_loopback_bridge_to_that_port_on_0.53f0e3cb", "\(hostName)"))
                }
            }
            .navigationTitle(L10n.text("apple.clientworkspacesections.browse_port.d3b57f13"))
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
        async let status = try? ClientRemote.status(peer: peer, workspace: workspaceID)
        async let counted = ClientRemote.summaries(peer: peer)

        if let fresh = await status { live = fresh }
        let summaries: [WorkspaceSummary]
        do {
            summaries = try await counted
        } catch {
            errorMessage = ClientTunnelCopy.display(error.localizedDescription, host: hostName)
            return
        }
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

struct WorkspaceSectionCounts {
    var sessions = 0
    var chats = 0
    var changes = 0
    var pulls = 0
    var todo = 0
    var notes = 0
    var automations = 0
    var workflows = 0
}

struct ClientSectionRow: View {
    let section: WorkspaceSection
    let count: Int?
    var isSelected: Bool = false
    var showsChevron: Bool = true

    var body: some View {
        ClientProjectSectionRow(title: section.label, symbol: section.symbol, count: count,
                                isSelected: isSelected, showsChevron: showsChevron)
    }
}

struct ClientProjectSectionRow: View {
    let title: String
    let symbol: String
    var count: Int? = nil
    var isSelected = false
    var showsChevron = true

    var body: some View {
        HStack(spacing: Theme.Space.m) {
            Image(systemName: symbol)
                .font(Theme.title3)
                .foregroundStyle(Theme.accent)
                .frame(width: 28)
            Text(title)
                .font(ClientType.label.weight(.medium))
                .foregroundStyle(.primary)
            Spacer()
            if let count, count > 0 {
                Text("\(count)")
                    .font(ClientType.rowFigure)
                    .foregroundStyle(.secondary)
            }
            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(Theme.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(Theme.Space.m)
        .frame(maxWidth: .infinity, minHeight: 44)
        .background(
            isSelected ? Theme.rowSelected : Theme.panel,
            in: RoundedRectangle(cornerRadius: Theme.cardRadius)
        )
        .overlay {
            RoundedRectangle(cornerRadius: Theme.cardRadius)
                .strokeBorder(isSelected ? Theme.accent.opacity(0.45) : Theme.border, lineWidth: 1)
        }
        .contentShape(.rect)
    }
}

struct ClientProjectWorktreesButton: View {
    let peer: String
    let hostName: String
    let folder: WorkspaceFolder
    @State private var showing = false
    @Environment(ClientNavigationModel.self) private var navigation

    var body: some View {
        Button { showing = true } label: {
            ClientProjectSectionRow(title: L10n.text("apple.clientworkspacesections.worktrees.aec2f93d"),
                                    symbol: "arrow.triangle.branch")
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $showing) {
            RemoteHostFeatureGate(feature: .worktrees, peer: peer, hostName: hostName) {
                ProjectWorktreeSheet(folder: remoteFolder) { created in
                    showing = false
                    var remote = created
                    remote.id = "remote:\(peer):\(created.id)"
                    remote.machineID = peer
                    remote.machineLabel = hostName
                    navigation.pushFolder(peerKey: peer, hostName: hostName, folder: remote, section: .sessions)
                }
            }
        }
    }

    private var remoteFolder: WorkspaceFolder {
        var remote = folder
        remote.id = "remote:\(peer):\(ClientRemote.rawWorkspaceID(of: folder) ?? folder.id)"
        remote.machineID = peer
        remote.machineLabel = hostName
        return remote
    }
}


struct ClientWorkspaceChangesView: View {
    let peer: String
    let workspaceID: String
    let folder: WorkspaceFolder
    let hostName: String
    var showsNavigationTitle: Bool = true

    @State private var live: WorkspaceFolder?
    @State private var errorMessage: String?
    @State private var session: GitCommitSession
    @State private var autoCommit: AutoCommitSession
    @State private var showingComposer = false
    @State private var openedRun: AutoCommitRunRoute?
    @State private var loaded = false
    @State private var loadRevision = 0
    @Environment(\.scenePhase) private var scenePhase

    init(
        peer: String,
        workspaceID: String,
        folder: WorkspaceFolder,
        hostName: String,
        session: GitCommitSession? = nil,
        autoCommit: AutoCommitSession? = nil,
        showsNavigationTitle: Bool = true
    ) {
        self.peer = peer
        self.workspaceID = workspaceID
        self.folder = folder
        self.hostName = hostName
        self.showsNavigationTitle = showsNavigationTitle
        _session = State(initialValue: session ?? GitCommitSessions.session(target: GitCommitTarget(peer: peer, workspaceID: workspaceID)))
        _autoCommit = State(initialValue: autoCommit ?? AutoCommitSession(
            peer: peer,
            workspaceID: workspaceID,
            folderName: folder.name,
            hostName: hostName,
            scope: WorkSessionContext.shared.scope,
            hostIdentity: peer,
            service: RemoteAutoCommitService(peer: peer)
        ))
    }

    private var current: WorkspaceFolder { live ?? folder }
    private var files: [FileChange] { current.git?.files ?? [] }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Theme.Space.s) {
                HStack {
                    Text(current.git?.branch ?? L10n.text("apple.clientworkspacesections.changes.bbd4b6a8"))
                        .font(ClientType.label.weight(.semibold))
                    Spacer()
                    if files.count > 1 {
                        NavigationLink {
                            ClientReviewAllView(peer: peer, workspaceID: workspaceID, hostName: hostName, files: files)
                        } label: {
                            Text(L10n.text("apple.clientworkspacesections.review_all.d05163fa"))
                                .font(ClientType.caption.weight(.medium))
                                .foregroundStyle(Theme.accent)
                        }
                        .buttonStyle(.plain)
                        .disabled(!session.loaded)
                    }
                    if !files.isEmpty {
                        Button(session.draft.paths == Set(files.map(\.path)) ? L10n.text("apple.clientworkspacesections.deselect_all.96754949") : L10n.text("apple.clientworkspacesections.select_all.1fc9a387"), .done) {
                            session.selectAll(Set(files.map(\.path)))
                        }
                        .buttonStyle(.plain).foregroundStyle(Theme.accent)
                        .disabled(!session.loaded || session.working || session.draft.submitted != nil)
                    }
                }.frame(minHeight: 44)
                if let errorMessage {
                    ClientErrorCard(message: errorMessage) {
                        Task { await load() }
                    }
                }
                if !loaded && files.isEmpty {
                    ProgressView().frame(maxWidth: .infinity, minHeight: 80)
                } else if files.isEmpty && errorMessage == nil {
                    ClientSectionEmpty(
                        text: L10n.text("apple.clientworkspacesections.nothing_to_commit.f377a9f6"),
                        art: .changes,
                        message: L10n.text("apple.clientworkspacesections.every_file_in_this_folder_matches_the_last.fffbaf63")
                    )
                } else {
                    ClientAutoCommitCard(session: autoCommit) { openedRun = $0 }
                    ForEach(files) { file in
                        HStack(spacing: Theme.Space.xs) {
                            Toggle(L10n.text("apple.clientworkspacesections.select_0.5d348f18", "\(file.path)"), isOn: Binding(
                                get: { session.draft.paths.contains(file.path) },
                                set: { _ in session.select(file.path) }
                            ))
                            .toggleStyle(BrandCheckboxStyle(iconOnly: true))
                            .accessibilityLabel(L10n.text("apple.clientworkspacesections.select_0.5d348f18", "\(file.path)"))
                            .frame(width: 44, height: 44)
                            .disabled(!session.loaded || session.working || session.draft.submitted != nil)
                            NavigationLink {
                                ClientDiffView(peer: peer, workspaceID: workspaceID, hostName: hostName, file: file)
                            } label: { ClientChangedFileRow(file: file) }
                                .buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding(.horizontal, Theme.Space.m)
            .padding(.top, Theme.Space.s)
            .padding(.bottom, 96)
        }
        .background(Theme.background)
        .modifier(ClientOptionalNavigationTitle(showsNavigationTitle ? L10n.text("apple.clientworkspacesections.changes.bbd4b6a8") : nil))
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: Theme.Space.s) {
                ThemeRule()
                if !files.isEmpty || session.draft.submitted != nil {
                    HStack(spacing: Theme.Space.m) {
                        Text(L10n.text("apple.clientworkspacesections.0_of_1_selected.d06c59a5", "\(session.draft.paths.count)", "\(files.count)"))
                            .font(ClientType.caption).foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                        Button(session.draft.submitted == nil ? L10n.text("apple.clientworkspacesections.review_and_commit.96f097b7") : L10n.text("apple.clientworkspacesections.check_commit.d65b2b26"), .commit) {
                            showingComposer = true
                        }
                        .buttonStyle(AccentButtonStyle(comfortable: true))
                        .disabled(!session.loaded || (session.draft.paths.isEmpty && session.draft.submitted == nil))
                    }.padding(.horizontal, Theme.Space.m)
                }
                HStack(spacing: Theme.Space.m) {
                    Text(current.git?.branch ?? L10n.text("apple.clientworkspacesections.current_branch.7c5b2da1"))
                        .font(ClientType.caption).foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }.padding(.horizontal, Theme.Space.m)
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: Theme.Space.s) { syncControls(current) }
                    VStack(alignment: .leading, spacing: Theme.Space.s) { syncControls(current) }
                }
                .padding(.horizontal, Theme.Space.m).padding(.bottom, Theme.Space.s)
            }.background(Theme.background)
        }
        .fullScreenCover(isPresented: $showingComposer) {
            GitCommitComposer(session: session, folderName: current.name, hostName: hostName, onCommitted: { await load() })
        }
        .navigationDestination(item: $openedRun) { route in
            ClientAutomationWorkspace(
                session: ClientAutomationSession(
                    peer: peer,
                    workspaceID: workspaceID,
                    hostName: hostName,
                    folderName: current.name,
                    jobID: route.jobID,
                    runID: route.runID
                ),
                opensDetail: true
            )
        }
        .onReceive(NotificationCenter.default.publisher(for: .clientFileDidChange)) { note in
            guard let change = note.object as? ClientFileChangeNotice,
                  change.peer == peer, change.workspace == workspaceID else { return }
            Task { await load() }
        }
        .refreshable {
            await ClientRefresh.pull("workspace-changes-\(workspaceID)") {
                await load()
                await autoCommit.load()
            }
        }
        .task { await load() }
        .task { await session.load() }
        .task { await autoCommit.load() }
        .onReceive(NotificationCenter.default.publisher(for: GitCommitTarget.didChange)) { note in
            guard note.object as? GitCommitTarget == session.target else { return }
            Task { await load() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .connectivityRestored)) { _ in
            Task { await load() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await load() } }
        }
        .onChange(of: session.loaded) { _, ready in
            if ready && loaded { session.reconcileAvailablePaths(Set(files.map(\.path))) }
        }
        .onChange(of: session.draft) { _, _ in Task { await session.persist() } }
    }

    @ViewBuilder
    private func syncControls(_ current: WorkspaceFolder) -> some View {
        GitPullControl(target: session.target, folderName: current.name, hostName: hostName,
                       incoming: current.git?.behind ?? 0, onPulled: { await load() })
        GitPushControl(target: session.target, folderName: current.name, hostName: hostName,
                       outgoing: current.git?.ahead ?? 0, onPushed: { await load() })
        GitBranchPullControl(workspaceID: workspaceID, peer: peer, branch: current.git?.branch,
                             folderName: current.name, hostName: hostName)
    }

    private func load() async {
        loadRevision += 1
        let revision = loadRevision
        let owner = WorkSessionContext.shared.scope
        do {
            let fresh = try await session.service.status()
            guard !Task.isCancelled, revision == loadRevision,
                  owner == WorkSessionContext.shared.scope else { return }
            live = fresh
            session.reconcileAvailablePaths(Set((live?.git?.files ?? []).map(\.path)))
            errorMessage = nil
        } catch {
            guard !Task.isCancelled, revision == loadRevision,
                  owner == WorkSessionContext.shared.scope else { return }
            errorMessage = ClientTunnelCopy.display(error.localizedDescription, host: hostName)
        }
        loaded = true
    }

}

struct ClientFolderBranchRow: View {
    let peer: String
    let workspaceID: String
    let folder: WorkspaceFolder
    let onChanged: () async -> Void

    private var branchLabel: String {
        L10n.text("apple.clientworkspacesections.branch_0.e742d863", "\(folder.subtitle ?? L10n.text("apple.clientworkspacesections.detached.88e34e4c"))")
    }

    var body: some View {
        if let git = folder.git, git.isRepo {
            BranchPickerPresentation(
                workspaceID: "remote:\(peer):\(workspaceID)",
                currentBranch: git.branch,
                onChanged: onChanged
            ) {
                HStack(spacing: Theme.Space.xs) {
                    Image(systemName: "arrow.triangle.branch")
                    Text(branchLabel)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 0)
                    Text(L10n.text("apple.clientworkspacesections.switch.39921a74"))
                    Image(systemName: "chevron.right")
                }
                .font(ClientType.caption)
                .foregroundStyle(Theme.accent)
                .padding(.horizontal, Theme.Space.s)
                .padding(.vertical, 7)
                .background(
                    Theme.accent.opacity(0.09),
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                )
            }
        } else if let subtitle = folder.subtitle {
            Text(subtitle)
                .font(ClientType.caption)
                .foregroundStyle(Theme.accent)
        }
    }
}

private struct ClientChangedFileRow: View {
    let file: FileChange

    var body: some View {
        HStack(spacing: Theme.Space.s) {
            VStack(alignment: .leading, spacing: 2) {
                Text(file.path.split(separator: "/").last.map(String.init) ?? file.path)
                    .font(ClientType.label)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if !file.directory.isEmpty {
                    Text(file.directory)
                        .font(ClientType.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            }
            Spacer()
            counts
            Image(systemName: "chevron.right")
                .font(Theme.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(Theme.Space.m)
        .frame(maxWidth: .infinity)
        .cardSurface()
        .contentShape(.rect)
    }

    @ViewBuilder
    private var counts: some View {
        if let added = file.added, added > 0 {
            Text("+\(added)")
                .font(ClientType.rowFigure)
                .foregroundStyle(Theme.diffAdded)
        }
        if let removed = file.removed, removed > 0 {
            Text("−\(removed)")
                .font(ClientType.rowFigure)
                .foregroundStyle(Theme.diffRemoved)
        }
    }
}


struct ClientWorkspaceTasksView: View {
    let peer: String
    let workspaceID: String
    let hostName: String
    var folderName = ""

    var body: some View {
        ClientTaskBoardDestination(peer: peer, hostName: hostName, folder: workspaceID, folderName: folderName)
    }
}


struct ClientWorkspaceWorkflowsView: View {
    let peer: String
    let workspaceID: String
    let hostName: String
    let folderName: String

    var body: some View {
        ClientWorkflowWorkspace(
            peer: peer, workspaceID: workspaceID,
            hostName: hostName, folderName: folderName
        )
        .id(ClientJobWorkspaceID(peer: peer, workspace: workspaceID))
    }
}

struct ClientWorkspaceAutomationsView: View {
    let peer: String
    let workspaceID: String
    let hostName: String
    let folderName: String

    var body: some View {
        ClientAutomationWorkspace(
            peer: peer, workspaceID: workspaceID,
            hostName: hostName, folderName: folderName
        )
        .id(ClientJobWorkspaceID(peer: peer, workspace: workspaceID))
    }
}


struct ClientJobRow: View {
    let title: String
    let subtitle: String
    let isLive: Bool
    let isEnabled: Bool
    var graph: WorkflowGraph? = nil
    var liveRun: WorkflowRunRecord? = nil
    var cadence: AutomationSchedule? = nil
    var showsChevron: Bool = true
    var isSelected: Bool = false

    private var isPaused: Bool {
        !isEnabled && (cadence?.repeats ?? graph?.schedule.repeats ?? false)
    }

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Space.s) {
            if let cadence {
                CadenceGlyph(
                    schedule: cadence,
                    enabled: isEnabled,
                    size: 22,
                    summary: cadence.summary
                )
                .padding(.top, 2)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(ClientType.label.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                Text(subtitle)
                    .font(ClientType.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let graph {
                    MiniGraph(
                        nodes: graph.nodes,
                        edges: graph.edges,
                        steps: liveRun?.steps ?? [],
                        currentNodeID: liveRun?.currentNodeID,
                        maxColumns: 5,
                        dot: 18
                    )
                    .accessibilityHidden(true)
                }
            }
            Spacer(minLength: 0)
            VStack(alignment: .trailing, spacing: 4) {
                if isLive {
                    HStack(spacing: 5) {
                        Circle()
                            .fill(Theme.stateWorking)
                            .frame(width: 7, height: 7)
                        Text(L10n.text("common.running"))
                            .font(ClientType.caption)
                            .foregroundStyle(Theme.stateWorking)
                    }
                } else if isPaused {
                    Text(L10n.text("common.paused"))
                        .font(ClientType.caption)
                        .foregroundStyle(.tertiary)
                }
                if showsChevron {
                    Image(systemName: "chevron.right")
                        .font(Theme.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(Theme.Space.m)
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .background(
            isSelected ? Theme.rowSelected : Theme.panel,
            in: RoundedRectangle(cornerRadius: Theme.cardRadius)
        )
        .overlay {
            RoundedRectangle(cornerRadius: Theme.cardRadius)
                .strokeBorder(isSelected ? Theme.accent.opacity(0.45) : Theme.border, lineWidth: 1)
        }
        .contentShape(.rect)
    }
}

struct ClientSectionEmpty: View {
    let text: String
    var art: EmptyArtKind?
    var message: String?
    var actionTitle: String?
    var actionIcon: ActionIcon = .next
    var action: (() -> Void)?

    var body: some View {
        ClientEmptyState(
            kind: .nothingYet,
            title: text,
            message: message,
            actionTitle: actionTitle,
            actionIcon: actionIcon,
            action: action,
            art: art
        )
    }
}

struct ClientCardList<Content: View>: View {
    let title: String
    let errorMessage: String?
    let isLoaded: Bool
    let isEmpty: Bool
    let emptyText: String
    var emptyArt: EmptyArtKind? = nil
    var emptyMessage: String? = nil
    var emptyActionTitle: String? = nil
    var emptyActionIcon: ActionIcon = .next
    var emptyAction: (() -> Void)? = nil
    var refreshKey: String? = nil
    let reload: () async -> Void
    @ViewBuilder var content: Content

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var waitedTooLong = false

    private var emptyState: some View {
        ClientSectionEmpty(
            text: emptyText,
            art: emptyArt,
            message: emptyMessage,
            actionTitle: emptyActionTitle,
            actionIcon: emptyActionIcon,
            action: emptyAction
        )
    }

    var body: some View {
        List {
            if let errorMessage {
                ClientErrorCard(message: errorMessage) {
                    Task { await reload() }
                }
                .clientCardRow()
            }
            if !isLoaded {
                ClientWireframe.Rows(count: 4)
                    .clientCardRow()
                if waitedTooLong {
                    ClientSectionEmpty(text: ClientTunnelCopy.waiting(nil), art: .waiting)
                        .clientCardRow()
                }
            } else if isEmpty {
                emptyState
                    .clientCardRow()
                    .transition(.smoothIn(reduceMotion: reduceMotion))
            } else {
                content
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .contentMargins(.top, Theme.Space.m, for: .scrollContent)
        .contentMargins(.bottom, Theme.Space.l, for: .scrollContent)
        .background(Theme.background)
        .animation(.easeInOut(duration: 0.22), value: isLoaded)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: isLoaded) {
            guard !isLoaded else {
                waitedTooLong = false
                return
            }
            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled else { return }
            waitedTooLong = true
        }
        .refreshable {
            if let refreshKey {
                await ClientRefresh.pull(refreshKey) { await reload() }
            } else {
                await reload()
            }
        }
    }
}

struct ClientOptionalNavigationTitle: ViewModifier {
    var title: String?

    init(_ title: String?) { self.title = title }

    @ViewBuilder
    func body(content: Content) -> some View {
        if let title, !title.isEmpty {
            content.navigationTitle(title).navigationBarTitleDisplayMode(.inline)
        } else {
            content
        }
    }
}

extension View {
    func clientCardRow() -> some View {
        listRowInsets(EdgeInsets(
            top: 0,
            leading: Theme.Space.m,
            bottom: Theme.Space.m,
            trailing: Theme.Space.m
        ))
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
    }
}

struct ClientSectionList<Content: View>: View {
    let title: String
    let errorMessage: String?
    let isLoaded: Bool
    let isEmpty: Bool
    let emptyText: String
    var emptyArt: EmptyArtKind? = nil
    var emptyMessage: String? = nil
    var emptyActionTitle: String? = nil
    var emptyActionIcon: ActionIcon = .next
    var emptyAction: (() -> Void)? = nil
    var refreshKey: String? = nil
    let reload: () async -> Void
    @ViewBuilder var content: Content
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var waitedTooLong = false

    private var emptyState: some View {
        ClientSectionEmpty(
            text: emptyText,
            art: emptyArt,
            message: emptyMessage,
            actionTitle: emptyActionTitle,
            actionIcon: emptyActionIcon,
            action: emptyAction
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                if let errorMessage {
                    ClientErrorCard(message: errorMessage) {
                        Task { await reload() }
                    }
                }
                if !isLoaded {
                    ClientWireframe.Page()
                        .transition(.smoothIn(reduceMotion: reduceMotion))
                    if waitedTooLong {
                        ClientSectionEmpty(text: ClientTunnelCopy.waiting(nil), art: .waiting)
                    }
                } else if isEmpty {
                    emptyState
                        .transition(.smoothIn(reduceMotion: reduceMotion))
                } else {
                    content
                        .transition(.smoothIn(reduceMotion: reduceMotion))
                }
            }
            .padding(.horizontal, Theme.Space.m)
            .padding(.top, Theme.Space.s)
            .padding(.bottom, 96)
        }
        .background(Theme.background)
        .task(id: isLoaded) {
            guard !isLoaded else {
                waitedTooLong = false
                return
            }
            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled else { return }
            waitedTooLong = true
        }
        .animation(.easeInOut(duration: 0.22), value: isLoaded)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .refreshable {
            if let refreshKey {
                await ClientRefresh.pull(refreshKey) { await reload() }
            } else {
                await reload()
            }
        }
    }
}

#endif
