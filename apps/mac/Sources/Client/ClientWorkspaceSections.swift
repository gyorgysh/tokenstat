// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

#if !os(macOS)
import SwiftUI

/// One folder on a connected host, as its sections.
///
/// The same seven the Mac's sidebar lists, in the same order and with the same
/// counts, because they are the same folder. The phone has no sidebar and no
/// tab strip, so a section pushes instead of opening a tab: list, workspace,
/// section, and a document is the fourth and last level.
///
/// Read-only past Sessions. Starting an agent and watching one are what the
/// phone is for. Editing a graph on a 390 point screen is not, and pretending
/// otherwise would be four cramped copies of a desktop screen.
struct ClientWorkspaceDetailView: View {
    let peer: String
    let hostName: String
    let folder: WorkspaceFolder

    @State private var counts = WorkspaceSectionCounts()
    @State private var errorMessage: String?
    @State private var showPort = false
    @State private var portText = "5173"
    @State private var forwardedPort: Int?
    @State private var browserURL: String?
    @State private var isOpeningPort = false

    private var workspaceID: String {
        ClientRemote.rawWorkspaceID(of: folder) ?? folder.id
    }

    var body: some View {
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
        .navigationTitle(folder.name)
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
            Text(folder.path)
                .font(ClientType.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .truncationMode(.middle)
            if let subtitle = folder.subtitle {
                Text(subtitle)
                    .font(ClientType.caption)
                    .foregroundStyle(Theme.accent)
            }
        }
        .padding(Theme.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
    }

    /// The seven, in the Mac's order. Files and Browser are a sheet and a
    /// cover rather than a push: one is the host's disk and the other is a web
    /// page, and neither is a level of this folder to come back up from.
    @ViewBuilder
    private var sections: some View {
        VStack(spacing: Theme.Space.s) {
            NavigationLink {
                ClientWorkspaceSessionsView(peer: peer, hostName: hostName, folder: folder)
            } label: {
                ClientSectionRow(section: .sessions, count: counts.sessions)
            }
            .buttonStyle(.plain)

            NavigationLink {
                ClientWorkspaceChangesView(folder: folder, hostName: hostName)
            } label: {
                ClientSectionRow(section: .changes, count: counts.changes)
            }
            .buttonStyle(.plain)

            NavigationLink {
                ClientWorkspaceTasksView(peer: peer, workspaceID: workspaceID, folder: folder)
            } label: {
                ClientSectionRow(section: .todo, count: counts.todo)
            }
            .buttonStyle(.plain)

            NavigationLink {
                ClientWorkspaceWorkflowsView(peer: peer, workspaceID: workspaceID, folder: folder)
            } label: {
                ClientSectionRow(section: .workflows, count: counts.workflows)
            }
            .buttonStyle(.plain)

            NavigationLink {
                ClientWorkspaceAutomationsView(peer: peer, workspaceID: workspaceID, folder: folder)
            } label: {
                ClientSectionRow(section: .automations, count: counts.automations)
            }
            .buttonStyle(.plain)

            NavigationLink {
                ClientFilesView(peer: peer, workspace: workspaceID, folderName: folder.name)
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

    /// Every count in one pass, so the screen fills in together rather than a
    /// badge at a time. A host that cannot answer one of them leaves that
    /// badge blank instead of failing the screen.
    private func reload() async {
        counts.changes = folder.git?.files.count ?? 0
        async let sessions = try? ClientRemote.ptyList(peer: peer)
        async let cards = try? ClientRemote.todoCards(peer: peer)
        async let jobs = try? ClientRemote.automations(peer: peer)
        async let graphs = try? ClientRemote.workflows(peer: peer)
        async let runs = try? ClientRemote.workflowRuns(peer: peer)

        let mine = (await sessions ?? []).filter { session in
            if let ws = session.workspaceID, !ws.isEmpty { return ws == workspaceID }
            return session.cwd == folder.path || session.cwd.hasPrefix(folder.path + "/")
        }
        counts.sessions = mine.count
        counts.todo = (await cards ?? []).filter {
            $0.workspaceID == workspaceID && $0.column != "done" && $0.column != "archive"
        }.count
        counts.automations = (await jobs ?? []).filter { $0.workspaceID == workspaceID }.count
        let live = (await runs ?? []).filter { $0.workspaceID == workspaceID && $0.isLive }.count
        counts.workflows = live > 0
            ? live
            : (await graphs ?? []).filter { $0.workspaceID == workspaceID }.count
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
private struct WorkspaceSectionCounts {
    var sessions = 0
    var changes = 0
    var todo = 0
    var automations = 0
    var workflows = 0
}

/// One section row on the phone.
///
/// The same glyph and the same word as the Mac's sidebar row, at the size a
/// thumb needs. Zero draws nothing, for the reason it draws nothing there: a
/// zero is not news, and seven grey zeroes is a wall of them.
private struct ClientSectionRow: View {
    let section: WorkspaceSection
    let count: Int?

    var body: some View {
        HStack(spacing: Theme.Space.m) {
            Image(systemName: section.symbol)
                .font(.title3)
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
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(Theme.Space.m)
        .frame(maxWidth: .infinity)
        .cardSurface()
        .contentShape(.rect)
    }
}

// MARK: - Changes

/// What is uncommitted in this folder, as the host last reported it.
///
/// No diff and no commit button. The counts come with the folder, so this
/// screen costs nothing to open, and a phone is where you check whether the
/// agent has been busy rather than where you review a patch.
struct ClientWorkspaceChangesView: View {
    let folder: WorkspaceFolder
    let hostName: String

    private var files: [FileChange] { folder.git?.files ?? [] }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                if let git = folder.git, git.isRepo {
                    branchCard(git)
                }
                if files.isEmpty {
                    ClientSectionEmpty(text: "Nothing uncommitted in this folder.")
                } else {
                    ForEach(files) { file in
                        HStack(spacing: Theme.Space.s) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(file.path.split(separator: "/").last.map(String.init) ?? file.path)
                                    .font(ClientType.label)
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
                        .padding(Theme.Space.m)
                        .frame(maxWidth: .infinity)
                        .cardSurface()
                    }
                }
            }
            .padding(.horizontal, Theme.Space.m)
            .padding(.top, Theme.Space.s)
            .padding(.bottom, 96)
        }
        .background(Theme.background)
        .navigationTitle("Changes")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func branchCard(_ git: GitStatus) -> some View {
        HStack(spacing: Theme.Space.s) {
            Image(systemName: "arrow.triangle.branch")
                .foregroundStyle(Theme.accent)
            Text(git.branch.map { $0.isEmpty ? "detached" : $0 } ?? "detached")
                .font(ClientType.label.weight(.medium))
            Spacer()
            if git.ahead > 0 {
                Text("⇡\(git.ahead)").font(ClientType.rowFigure).foregroundStyle(Theme.accent)
            }
            if git.behind > 0 {
                Text("⇣\(git.behind)").font(ClientType.rowFigure).foregroundStyle(Theme.accent)
            }
        }
        .padding(Theme.Space.m)
        .frame(maxWidth: .infinity)
        .cardSurface()
    }
}

// MARK: - Tasks

/// This folder's cards, on the host that owns them.
struct ClientWorkspaceTasksView: View {
    let peer: String
    let workspaceID: String
    let folder: WorkspaceFolder

    @State private var cards: [TodoCard] = []
    @State private var errorMessage: String?
    @State private var loaded = false

    private static let columns = [("backlog", "To Do"), ("doing", "Doing"), ("done", "Done")]

    var body: some View {
        ClientSectionList(
            title: "Tasks",
            errorMessage: errorMessage,
            isLoaded: loaded,
            isEmpty: cards.isEmpty,
            emptyText: "No cards in this folder yet.",
            reload: { await load() }
        ) {
            ForEach(Self.columns, id: \.0) { id, label in
                let group = cards.filter { $0.column == id }
                if !group.isEmpty {
                    Text(label.uppercased())
                        .font(ClientType.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .padding(.top, Theme.Space.xs)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    ForEach(group) { card in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(card.title)
                                .font(ClientType.label.weight(.medium))
                                .frame(maxWidth: .infinity, alignment: .leading)
                            if !card.notes.isEmpty {
                                Text(card.notes)
                                    .font(ClientType.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        .padding(Theme.Space.m)
                        .frame(maxWidth: .infinity)
                        .cardSurface()
                    }
                }
            }
        }
        .task { await load() }
    }

    private func load() async {
        do {
            cards = try await ClientRemote.todoCards(peer: peer)
                .filter { $0.workspaceID == workspaceID && $0.column != "archive" }
            errorMessage = nil
        } catch {
            errorMessage = ClientTunnelCopy.display(error.localizedDescription, host: folder.name)
        }
        loaded = true
    }
}

// MARK: - Workflows

/// This folder's graphs, and whether one is running right now.
struct ClientWorkspaceWorkflowsView: View {
    let peer: String
    let workspaceID: String
    let folder: WorkspaceFolder

    @State private var graphs: [WorkflowGraph] = []
    @State private var runs: [WorkflowRunRecord] = []
    @State private var errorMessage: String?
    @State private var loaded = false

    var body: some View {
        ClientSectionList(
            title: "Workflows",
            errorMessage: errorMessage,
            isLoaded: loaded,
            isEmpty: graphs.isEmpty && runs.isEmpty,
            emptyText: "No workflows bound to this folder.",
            reload: { await load() }
        ) {
            ForEach(graphs) { graph in
                ClientJobRow(
                    title: graph.name,
                    subtitle: "\(graph.nodes.count) step\(graph.nodes.count == 1 ? "" : "s")",
                    isLive: runs.contains { $0.workflowID == graph.id && $0.isLive },
                    isEnabled: graph.enabled
                )
            }
        }
        .task { await load() }
    }

    private func load() async {
        do {
            async let all = ClientRemote.workflows(peer: peer)
            async let history = ClientRemote.workflowRuns(peer: peer)
            graphs = try await all.filter { $0.workspaceID == workspaceID }
            runs = try await history.filter { $0.workspaceID == workspaceID }
            errorMessage = nil
        } catch {
            errorMessage = ClientTunnelCopy.display(error.localizedDescription, host: folder.name)
        }
        loaded = true
    }
}

// MARK: - Automations

/// This folder's scheduled jobs, and whether one is running right now.
struct ClientWorkspaceAutomationsView: View {
    let peer: String
    let workspaceID: String
    let folder: WorkspaceFolder

    @State private var jobs: [Automation] = []
    @State private var runs: [RunRecord] = []
    @State private var errorMessage: String?
    @State private var loaded = false

    var body: some View {
        ClientSectionList(
            title: "Automations",
            errorMessage: errorMessage,
            isLoaded: loaded,
            isEmpty: jobs.isEmpty,
            emptyText: "No automations set up in this folder.",
            reload: { await load() }
        ) {
            ForEach(jobs) { job in
                ClientJobRow(
                    title: job.name,
                    subtitle: job.backend,
                    isLive: runs.contains { $0.jobId == job.id && $0.isRunning },
                    isEnabled: job.enabled
                )
            }
        }
        .task { await load() }
    }

    private func load() async {
        do {
            async let all = ClientRemote.automations(peer: peer)
            async let history = ClientRemote.automationRuns(peer: peer)
            jobs = try await all.filter { $0.workspaceID == workspaceID }
            runs = try await history.filter { $0.workspaceID == workspaceID }
            errorMessage = nil
        } catch {
            errorMessage = ClientTunnelCopy.display(error.localizedDescription, host: folder.name)
        }
        loaded = true
    }
}

// MARK: - Shared section chrome

/// A job or a graph: a name, one quiet line, and whether it is going.
private struct ClientJobRow: View {
    let title: String
    let subtitle: String
    let isLive: Bool
    let isEnabled: Bool

    var body: some View {
        HStack(spacing: Theme.Space.s) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(ClientType.label.weight(.medium))
                    .lineLimit(1)
                Text(subtitle)
                    .font(ClientType.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if isLive {
                HStack(spacing: 5) {
                    Circle()
                        .fill(Theme.stateWorking)
                        .frame(width: 7, height: 7)
                    Text("Running")
                        .font(ClientType.caption)
                        .foregroundStyle(Theme.stateWorking)
                }
            } else if !isEnabled {
                Text("Paused")
                    .font(ClientType.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(Theme.Space.m)
        .frame(maxWidth: .infinity)
        .cardSurface()
    }
}

private struct ClientSectionEmpty: View {
    let text: String

    var body: some View {
        Text(text)
            .font(ClientType.body)
            .foregroundStyle(.secondary)
            .padding(Theme.Space.m)
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardSurface()
    }
}

/// The shell every pushed section shares: one scroll view, one error card, one
/// empty state, and pull to refresh. Written once so a folder's five sections
/// cannot each arrive at their own idea of what a loading screen looks like.
private struct ClientSectionList<Content: View>: View {
    let title: String
    let errorMessage: String?
    let isLoaded: Bool
    let isEmpty: Bool
    let emptyText: String
    let reload: () async -> Void
    @ViewBuilder var content: Content

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
                    // before the question has been asked.
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.top, Theme.Space.xl)
                } else if isEmpty {
                    ClientSectionEmpty(text: emptyText)
                } else {
                    content
                }
            }
            .padding(.horizontal, Theme.Space.m)
            .padding(.top, Theme.Space.s)
            .padding(.bottom, 96)
        }
        .background(Theme.background)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await reload() }
    }
}

#endif
