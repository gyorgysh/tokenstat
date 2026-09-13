// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

#if !os(macOS)
import SwiftUI
import UIKit

/// One folder on a connected host, as its sections.
///
/// The same ones the Mac's sidebar lists, in the same order and with the same
/// counts, because they are the same folder. Notes are the exception: they
/// live on the machine that owns the folder and a client cannot read them yet.
///
/// The phone has no sidebar and no tab strip, so a section pushes instead of
/// opening a tab: list, workspace, section, and a document is the fourth and
/// last level.
///
/// Sessions, workflows and automations can start and stop work on the
/// machine that owns the folder. Construction stays on the Mac: a phone
/// can run a graph, it cannot draw one.
struct ClientWorkspaceDetailView: View {
    let peer: String
    let hostName: String
    /// What the list this was pushed from knew when it was tapped. A seed, not
    /// the truth: an agent writing files changes it a second later.
    let folder: WorkspaceFolder

    /// The folder as the owning machine last described it. Only the parts that
    /// go stale are taken, because the peer answers with its own local id and
    /// this side addresses a remote folder as `remote:<peer>:<id>`.
    @State private var live: WorkspaceFolder?
    @State private var counts = WorkspaceSectionCounts()
    @State private var pullCounts = PullCountStore.shared
    @State private var errorMessage: String?
    @State private var showPort = false
    @State private var portText = "5173"
    @State private var forwardedPort: Int?
    @State private var browserURL: String?
    @State private var isOpeningPort = false

    private var workspaceID: String {
        ClientRemote.rawWorkspaceID(of: folder) ?? folder.id
    }

    /// The folder to draw: the fresh read when there is one.
    private var current: WorkspaceFolder {
        guard var merged = live else { return folder }
        merged.id = folder.id
        merged.machineID = folder.machineID
        merged.machineLabel = folder.machineLabel
        return merged
    }

    @Environment(\.horizontalSizeClass) private var sizeClass

    /// iPad regular width only. A large iPhone in landscape is regular, and
    /// that is still a phone surface.
    private var usesWorkspaceLayout: Bool {
        sizeClass == .regular && UIDevice.current.userInterfaceIdiom == .pad
    }

    var body: some View {
        Group {
            if usesWorkspaceLayout {
                ClientFolderSplit(peer: peer, hostName: hostName, folder: folder)
            } else {
                stacked
            }
        }
        .rememberWorkspace(peer: peer, folder: folder)
        .onReceive(NotificationCenter.default.publisher(for: GitCommitTarget.didChange)) { note in
            guard !usesWorkspaceLayout,
                  note.object as? GitCommitTarget == GitCommitTarget(peer: peer, workspaceID: workspaceID) else { return }
            Task { await reload() }
        }
        .toolbar {
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
        .sheet(isPresented: $showPort) { portSheet }
        .fullScreenCover(item: Binding(
            get: { browserURL.map { BrowserURL(url: $0) } },
            set: { browserURL = $0?.url }
        )) { item in
            ClientBrowserScreen(url: item.url) {
                browserURL = nil
                if let port = forwardedPort {
                    forwardedPort = nil
                    Task { await Bridge.proxyUnlisten(peer: peer, host: "127.0.0.1", port: port) }
                }
            }
        }
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

    /// In the Mac's order. Files, Changes and the rest push.
    /// Browser is a cover: it is a web page, not a level of this folder.
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

            // Under Sessions, the same place the Mac puts it. This list is
            // written out rather than driven from `WorkspaceSection.allCases`,
            // which is why adding the case alone left the phone without it.
            NavigationLink {
                RemoteHostFeatureGate(feature: .chat, peer: peer, hostName: hostName) {
                    ClientChatView(peer: peer, workspaceID: workspaceID, folderName: current.name, hostName: hostName)
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

            NavigationLink {
                PullsView(
                    workspaceID: workspaceID,
                    peer: peer,
                    connectionHostName: hostName,
                    workspaceName: folder.name,
                    workspaceIsRemote: true
                )
                    .navigationTitle("Pull requests")
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
                    TextField("Port", text: $portText)
                        .keyboardType(.numberPad)
                } footer: {
                    Text("Opens a loopback bridge to that port on \(hostName) and shows it in the in-app browser.")
                }
            }
            .navigationTitle("Browse port")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showPort = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Open") { Task { await openPort() } }
                        .disabled(isOpeningPort || UInt16(portText) == nil)
                }
            }
        }
        .presentationDetents([.medium])
    }

    /// Two calls, not six.
    ///
    /// `workspace.summary` answers every badge at once, and `workspace.status`
    /// re-reads the git state the header and the Changes row need. This used
    /// to read five whole lists over the tunnel and count them on the phone,
    /// which is five round trips for a screen that is mostly numbers and a
    /// second opinion about what a folder contains.
    private func reload() async {
        async let status = try? ClientRemote.status(peer: peer, workspace: workspaceID)
        async let counted = ClientRemote.summaries(peer: peer)

        if let fresh = await status { live = fresh }
        let summaries: [WorkspaceSummary]
        do {
            summaries = try await counted
        } catch {
            // Say so. Every badge comes from this one call now, so a failure
            // leaves all of them stale rather than one of them blank, and a
            // screen of ten-minute-old numbers presented as current is worse
            // than a screen that admits it could not ask.
            errorMessage = ClientTunnelCopy.display(error.localizedDescription, host: hostName)
            return
        }
        guard let summary = summaries.first(where: { $0.id == workspaceID }) else {
            // The host answered but does not have this folder, or is too old
            // to know the method. Badges stay as they were: "we could not ask"
            // is not the same as "nothing here".
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

    private func openPort() async {
        guard let port = UInt16(portText.trimmingCharacters(in: .whitespaces)) else { return }
        isOpeningPort = true
        defer { isOpeningPort = false }
        do {
            let result = try await Bridge.proxyListen(peer: peer, host: "127.0.0.1", port: Int(port))
            showPort = false
            forwardedPort = Int(port)
            browserURL = result.url
        } catch {
            errorMessage = ClientTunnelCopy.display(error.localizedDescription, host: hostName)
            showPort = false
        }
    }
}

/// What the badges say. One value each, filled by one pass.
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

/// One section row on the phone.
///
/// The same glyph and the same word as the Mac's sidebar row, at the size a
/// thumb needs. Zero draws nothing, for the reason it draws nothing there: a
/// zero is not news, and a column of grey zeroes is a wall of them.
struct ClientSectionRow: View {
    let section: WorkspaceSection
    let count: Int?
    var isSelected: Bool = false
    var showsChevron: Bool = true

    var body: some View {
        HStack(spacing: Theme.Space.m) {
            Image(systemName: section.symbol)
                .font(Theme.title3)
                .foregroundStyle(Theme.accent)
                .frame(width: 28)
            Text(section.label)
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

// MARK: - Changes

/// What is uncommitted in this folder, as the host last reported it.
///
/// Tapping a file opens its diff. Selection stays local until the person
/// submits the reviewed content to the computer that owns the repository.
struct ClientWorkspaceChangesView: View {
    let peer: String
    let workspaceID: String
    /// What the section list had. Replaced by this screen's own read, so a
    /// file written while it is open shows up here rather than on the next
    /// visit.
    let folder: WorkspaceFolder
    let hostName: String
    /// Inspector panes already name this surface. Compact pushes still need the title.
    var showsNavigationTitle: Bool = true

    @State private var live: WorkspaceFolder?
    @State private var errorMessage: String?
    @State private var session: GitCommitSession
    @State private var autoCommit: AutoCommitSession
    @State private var showingComposer = false
    @State private var openedRun: AutoCommitRunRoute?

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
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                HStack {
                    Text(current.git?.branch ?? "Changes")
                        .font(ClientType.label.weight(.semibold))
                    Spacer()
                    if files.count > 1 {
                        NavigationLink {
                            ClientReviewAllView(peer: peer, workspaceID: workspaceID, hostName: hostName, files: files)
                        } label: {
                            Text("Review all")
                                .font(ClientType.caption.weight(.medium))
                                .foregroundStyle(Theme.accent)
                        }
                        .buttonStyle(.plain)
                        .disabled(!session.loaded)
                    }
                    if !files.isEmpty {
                        Button(session.draft.paths == Set(files.map(\.path)) ? "Deselect all" : "Select all", .done) {
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
                if files.isEmpty {
                    ClientSectionEmpty(
                        text: "Nothing to commit",
                        art: .changes,
                        message: "Every file in this folder matches the last commit."
                    )
                } else {
                    ClientAutoCommitCard(session: autoCommit) { openedRun = $0 }
                    ForEach(files) { file in
                        HStack(spacing: Theme.Space.xs) {
                            Toggle("Select \(file.path)", isOn: Binding(
                                get: { session.draft.paths.contains(file.path) },
                                set: { _ in session.select(file.path) }
                            ))
                            .toggleStyle(BrandCheckboxStyle(iconOnly: true))
                            .accessibilityLabel("Select \(file.path)")
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
        .modifier(ClientOptionalNavigationTitle(showsNavigationTitle ? "Changes" : nil))
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: Theme.Space.s) {
                ThemeRule()
                if !files.isEmpty || session.draft.submitted != nil {
                    HStack(spacing: Theme.Space.m) {
                        Text("\(session.draft.paths.count) of \(files.count) selected")
                            .font(ClientType.caption).foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                        Button(session.draft.submitted == nil ? "Review and commit" : "Check commit", .commit) {
                            showingComposer = true
                        }
                        .buttonStyle(AccentButtonStyle(comfortable: true))
                        .disabled(!session.loaded || (session.draft.paths.isEmpty && session.draft.submitted == nil))
                    }.padding(.horizontal, Theme.Space.m)
                }
                HStack(spacing: Theme.Space.m) {
                    Text(current.git?.branch ?? "Current branch")
                        .font(ClientType.caption).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    GitPushControl(target: session.target, folderName: current.name, hostName: hostName,
                                   outgoing: current.git?.ahead ?? 0, onPushed: { await load() })
                }.padding(.horizontal, Theme.Space.m).padding(.bottom, Theme.Space.s)
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
        .task { await session.load(); await autoCommit.load(); await load() }
        .onChange(of: session.draft) { _, _ in Task { await session.persist() } }
    }

    private func load() async {
        do {
            live = try await session.service.status()
            session.reconcileAvailablePaths(Set((live?.git?.files ?? []).map(\.path)))
            errorMessage = nil
        } catch {
            errorMessage = ClientTunnelCopy.display(error.localizedDescription, host: hostName)
        }
    }

}

/// The branch this folder is on, and the way to switch it.
///
/// One selector per folder, drawn in the folder header: the same line that
/// used to show the branch as plain text. A plain folder keeps its plain
/// line. Same control the Mac workspace header carries.
struct ClientFolderBranchRow: View {
    let peer: String
    let workspaceID: String
    let folder: WorkspaceFolder
    let onChanged: () async -> Void

    /// Named, not just valued: a bare "v1.0" beside two plain header lines
    /// never said it opens the picker.
    private var branchLabel: String {
        "Branch \(folder.subtitle ?? "detached")"
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
                    Text("Switch")
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

/// One changed file, and the way into its diff.
///
/// Its own view rather than a label inline: the compiler gave up type-checking
/// the stack once it was nested inside a `NavigationLink` inside a `ForEach`.
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

// MARK: - Tasks

/// This folder's cards, on the host that owns them.
struct ClientWorkspaceTasksView: View {
    let peer: String
    let workspaceID: String
    let hostName: String
    var folderName = ""

    var body: some View {
        ClientTaskBoardDestination(peer: peer, hostName: hostName, folder: workspaceID, folderName: folderName)
    }
}

// MARK: - Jobs

/// Both phone navigation and iPad sections mount the same session owner.
/// Window width only changes its presentation.
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

// MARK: - Shared section chrome

/// A job or a graph: a name, one quiet line, and whether it is going.
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
                        Text("Running")
                            .font(ClientType.caption)
                            .foregroundStyle(Theme.stateWorking)
                    }
                } else if isPaused {
                    Text("Paused")
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

/// Nothing here, said properly.
///
/// A wrapper over `ClientEmptyState` rather than its own card, so a section's
/// empty screen cannot drift back into a grey sentence while Home and Devices
/// draw something considered. The title is the state, the line under it is the
/// next move.
struct ClientSectionEmpty: View {
    let text: String
    /// The picture. Nil falls back to the kind's mark, which is what an
    /// incidental empty state inside a detail screen wants.
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

/// The shell every pushed section shares: one scroll view, one error card, one
/// empty state, and pull to refresh. Written once so a folder's five sections
/// cannot each arrive at their own idea of what a loading screen looks like.
/// The same screen as `ClientSectionList`, built on a `List`.
///
/// **`swipeActions` only exists inside a `List`.** Attached to a row in a
/// `ScrollView` it compiles, renders and does nothing, which is how the first
/// cut of the phone's task board shipped gestures that could not be performed.
/// Any screen whose rows can be swiped has to be here rather than there.
///
/// The loading, empty and error states are the same ones, drawn as rows so a
/// screen does not change shape when its data lands.
struct ClientCardList<Content: View>: View {
    let title: String
    let errorMessage: String?
    let isLoaded: Bool
    let isEmpty: Bool
    let emptyText: String
    /// What the empty screen draws, and what it offers. Every section passes
    /// one: a folder with no jobs deserves the same care as a folder with no
    /// activity, which is the surface these three used to be the exception to.
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

    /// The empty screen this list was configured with. One place, so the two
    /// list shells cannot describe the same folder differently.
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
        // Rows carry the gap below them and nothing above, so without this the
        // first card sits flush against whatever the screen puts over the list.
        // On notes that is the composer's own border, and an empty state that
        // touches the field it belongs to reads as part of it.
        .contentMargins(.top, Theme.Space.m, for: .scrollContent)
        .contentMargins(.bottom, Theme.Space.l, for: .scrollContent)
        .background(Theme.background)
        .animation(.easeInOut(duration: 0.22), value: isLoaded)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        // Keyed on `isLoaded` so the timer restarts when it changes. A plain
        // `.task` closure captures the value it started with, which for a
        // `let` means it never sees the load finish.
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

/// Compact folder sections need a title. Inspector panes already name the surface.
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
    /// A card as a list row: our spacing, no separator, no system fill.
    ///
    /// The gap lives below the row rather than around it, so the list's own
    /// content margins own both ends and cards cannot end up twice as far
    /// apart as they are from the top of the screen.
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

/// Shared by every section screen that only scrolls.
struct ClientSectionList<Content: View>: View {
    let title: String
    let errorMessage: String?
    let isLoaded: Bool
    let isEmpty: Bool
    let emptyText: String
    /// What the empty screen draws, and what it offers. Every section passes
    /// one: a folder with no jobs deserves the same care as a folder with no
    /// activity, which is the surface these three used to be the exception to.
    var emptyArt: EmptyArtKind? = nil
    var emptyMessage: String? = nil
    var emptyActionTitle: String? = nil
    var emptyActionIcon: ActionIcon = .next
    var emptyAction: (() -> Void)? = nil
    var refreshKey: String? = nil
    let reload: () async -> Void
    @ViewBuilder var content: Content
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The first read has been outstanding long enough to say so.
    @State private var waitedTooLong = false

    /// The empty screen this list was configured with. One place, so the two
    /// list shells cannot describe the same folder differently.
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
                    // Nothing yet is an answer, and it must not be given
                    // before the question has been asked. A wireframe says
                    // "rows are coming" and holds their shape, where a spinner
                    // said nothing and then let the list appear all at once.
                    ClientWireframe.Rows(count: 4)
                        .transition(.smoothIn(reduceMotion: reduceMotion))
                    // But a wireframe promises the answer is coming, so it
                    // must not pulse forever when the machine never replies.
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
        // Keyed on `isLoaded`: a plain `.task` closure keeps the value it
        // started with, so the guard would fire on every screen whether or not
        // the load had already finished.
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
