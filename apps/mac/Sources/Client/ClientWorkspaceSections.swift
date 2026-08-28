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
            if let subtitle = current.subtitle {
                Text(subtitle)
                    .font(ClientType.caption)
                    .foregroundStyle(Theme.accent)
            }
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
            } label: {
                ClientSectionRow(section: .sessions, count: counts.sessions)
            }
            .buttonStyle(.plain)

            // Under Sessions, the same place the Mac puts it. This list is
            // written out rather than driven from `WorkspaceSection.allCases`,
            // which is why adding the case alone left the phone without it.
            NavigationLink {
                ChatComingSoonView(folderName: current.name)
                    .navigationTitle("Chat")
                    .navigationBarTitleDisplayMode(.inline)
            } label: {
                ClientSectionRow(section: .chat, count: nil)
            }
            .buttonStyle(.plain)

            NavigationLink {
                ClientWorkspaceChangesView(
                    peer: peer,
                    workspaceID: workspaceID,
                    folder: current,
                    hostName: hostName
                )
            } label: {
                ClientSectionRow(section: .changes, count: counts.changes)
            }
            .buttonStyle(.plain)

            NavigationLink {
                PullsView(workspaceID: workspaceID, peer: peer, connectionHostName: hostName)
                    .navigationTitle("Pull requests")
                    .navigationBarTitleDisplayMode(.inline)
            } label: {
                ClientSectionRow(section: .pulls, count: nil)
            }
            .buttonStyle(.plain)

            NavigationLink {
                ClientWorkspaceTasksView(
                    peer: peer,
                    workspaceID: workspaceID,
                    hostName: hostName,
                    folderName: folder.name
                )
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
            changes: summary.changed ?? current.git?.files.count ?? 0,
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
    var changes = 0
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
/// The list is cheap to open. Tapping a file pushes its diff. No staging
/// and no commit: those stay on the Mac.
struct ClientWorkspaceChangesView: View {
    let peer: String
    let workspaceID: String
    /// What the section list had. Replaced by this screen's own read, so a
    /// file written while it is open shows up here rather than on the next
    /// visit.
    let folder: WorkspaceFolder
    let hostName: String

    @State private var live: WorkspaceFolder?
    @State private var errorMessage: String?

    private var current: WorkspaceFolder { live ?? folder }
    private var files: [FileChange] { current.git?.files ?? [] }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                if let errorMessage {
                    ClientErrorCard(message: errorMessage) {
                        Task { await load() }
                    }
                }
                if let git = current.git, git.isRepo {
                    branchCard(git)
                }
                if files.isEmpty {
                    ClientSectionEmpty(
                        text: "Nothing to commit",
                        art: .changes,
                        message: "Every file in this folder matches the last commit."
                    )
                } else {
                    ForEach(files) { file in
                        NavigationLink {
                            ClientDiffView(
                                peer: peer,
                                workspaceID: workspaceID,
                                hostName: hostName,
                                file: file
                            )
                        } label: {
                            ClientChangedFileRow(file: file)
                        }
                        .buttonStyle(.plain)
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
        .refreshable { await ClientRefresh.pull("workspace-changes-\(workspaceID)") { await load() } }
        .task { await load() }
    }

    private func load() async {
        do {
            live = try await ClientRemote.status(peer: peer, workspace: workspaceID)
            errorMessage = nil
        } catch {
            errorMessage = ClientTunnelCopy.display(error.localizedDescription, host: hostName)
        }
    }

    private func branchCard(_ git: GitStatus) -> some View {
        BranchPickerPresentation(
            workspaceID: "remote:\(peer):\(workspaceID)",
            currentBranch: git.branch,
            onChanged: { await load() }
        ) {
            HStack(spacing: Theme.Space.s) {
                ZStack {
                    RoundedRectangle(cornerRadius: Theme.Space.xs)
                        .fill(Theme.accent.opacity(0.12))
                        .frame(width: 32, height: 32)
                    Image(systemName: "arrow.triangle.branch")
                        .foregroundStyle(Theme.accent)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Branch").font(ClientType.caption).foregroundStyle(.secondary)
                    Text(git.branch.map { $0.isEmpty ? "detached" : $0 } ?? "detached")
                        .font(ClientType.label.weight(.medium))
                }
                Spacer()
                if git.ahead > 0 {
                    Text("⇡\(git.ahead)").font(ClientType.rowFigure).foregroundStyle(Theme.accent)
                }
                if git.behind > 0 {
                    Text("⇣\(git.behind)").font(ClientType.rowFigure).foregroundStyle(Theme.warning)
                }
                Image(systemName: "chevron.right")
                    .font(ClientType.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(Theme.Space.m)
            .frame(maxWidth: .infinity)
            .cardSurface()
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
    var folderName: String = ""

    @State private var cards: [TodoCard] = []
    @State private var errorMessage: String?
    @State private var loaded = false
    @State private var composing = false
    /// Finished work, off by default. The board hides it on the Mac too, but
    /// the phone had no way to ask for it at all.
    @State private var showingArchive = false

    private static let columns = [("backlog", "To Do"), ("doing", "Doing"), ("done", "Done")]

    /// This folder's cards. Notes are not cards and have their own screen:
    /// see `ClientWorkspaceNotesView`. A list of work with a second list of
    /// things to remember underneath it was two screens in a trench coat.
    private var tasks: [TodoCard] {
        cards.filter { $0.kind != .note && ($0.column == "archive") == showingArchive }
    }

    var body: some View {
        ClientCardList(
            title: "Tasks",
            errorMessage: errorMessage,
            isLoaded: loaded,
            isEmpty: tasks.isEmpty,
            emptyText: showingArchive ? "Nothing archived" : "No cards yet",
            emptyArt: .tasks,
            emptyMessage: showingArchive
                ? "Cards you put away in this folder show up here."
                : "Capture the next thing to do in \(folderName.isEmpty ? "this folder" : folderName).",
            emptyActionTitle: showingArchive ? nil : "Add a card",
            emptyActionIcon: .create,
            emptyAction: showingArchive ? nil : { composing = true },
            reload: { await load() }
        ) {
            ForEach(Self.columns, id: \.0) { id, label in
                let group = tasks.filter { showingArchive || $0.column == id }
                if !showingArchive, !group.isEmpty {
                    sectionHeading(label)
                    ForEach(group) { card in
                        row(card)
                    }
                }
            }
            if showingArchive, !tasks.isEmpty {
                sectionHeading("Archived")
                ForEach(tasks) { card in
                    row(card)
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Add", .create) { composing = true }
                    .labelStyle(.iconOnly)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button(
                    showingArchive ? "Show open cards" : "Show archive",
                    showingArchive ? .restore : .archive
                ) {
                    showingArchive.toggle()
                }
                .labelStyle(.iconOnly)
            }
        }
        .sheet(isPresented: $composing) {
            ClientTaskComposer(
                peer: peer,
                workspaceID: workspaceID,
                folderName: folderName,
                hostName: hostName
            ) {
                await load()
            }
        }
        .task { await load() }
    }

    private func sectionHeading(_ text: String) -> some View {
        Text(text.uppercased())
            .font(ClientType.caption.weight(.semibold))
            .foregroundStyle(.tertiary)
            .padding(.top, Theme.Space.xs)
            .frame(maxWidth: .infinity, alignment: .leading)
            .clientCardRow()
    }

    /// One card, with the moves a phone can make on it.
    ///
    /// Swipes rather than a detail screen: moving a card along and putting it
    /// away are the two things somebody does from a phone, and both are one
    /// gesture. Editing stays on the Mac, where the prompt and the agent live.
    private func row(_ card: TodoCard) -> some View {
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
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if card.column == "archive" {
                Button("Restore") { Task { await move(card, to: "backlog") } }
            } else {
                Button("Archive") { Task { await move(card, to: "archive") } }
            }
            Button("Delete", role: .destructive) { Task { await remove(card) } }
        }
        .swipeActions(edge: .leading, allowsFullSwipe: false) {
            if card.column != "done" {
                Button("Done") { Task { await move(card, to: "done") } }
                if card.column == "backlog" {
                    Button("Doing") { Task { await move(card, to: "doing") } }
                }
            }
        }
        .clientCardRow()
    }

    private func move(_ card: TodoCard, to column: String) async {
        do {
            _ = try await ClientRemote.todoMove(peer: peer, id: card.id, column: column)
            await load()
        } catch {
            errorMessage = ClientTunnelCopy.display(error.localizedDescription, host: hostName)
        }
    }

    private func remove(_ card: TodoCard) async {
        do {
            try await ClientRemote.todoRemove(peer: peer, id: card.id)
            await load()
        } catch {
            errorMessage = ClientTunnelCopy.display(error.localizedDescription, host: hostName)
        }
    }

    private func load() async {
        do {
            cards = try await ClientRemote.todoCards(peer: peer)
                .filter { $0.workspaceID == workspaceID }
            errorMessage = nil
        } catch {
            errorMessage = ClientTunnelCopy.display(error.localizedDescription, host: hostName)
        }
        loaded = true
    }
}

/// Capture a task from the phone.
///
/// A task can carry a prompt, but the agent, model and time limit stay on the
/// Mac, where the run is actually started.
///
/// **Tasks only.** This used to ask which kind you meant before it asked for
/// the text, which is a question about the app rather than about the thing
/// being written down. Notes have their own screen, where writing one costs a
/// line and a return.
struct ClientTaskComposer: View {
    let peer: String
    let workspaceID: String
    let folderName: String
    let hostName: String
    /// Offered when the composer is opened from somewhere that is not one
    /// folder. Empty means the caller already decided where this goes.
    var folders: [WorkspaceFolder] = []
    let onSaved: () async -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var body_ = ""
    @State private var saving = false
    @State private var errorMessage: String?
    /// Chosen destination when a picker is shown. Starts on what the caller
    /// passed, so opening this from a folder keeps that folder.
    @State private var destination: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Task title", text: $title)
                    TextField("Prompt", text: $body_, axis: .vertical)
                        .lineLimit(2...5)
                    if !folders.isEmpty {
                        Picker("Saving to", selection: destinationBinding) {
                            Text("Uncategorized (no folder)").tag("")
                            ForEach(folders) { folder in
                                Text(folder.name)
                                    .tag(ClientRemote.rawWorkspaceID(of: folder) ?? folder.id)
                            }
                        }
                    }
                } footer: {
                    // The destination, said before Save. The Mac learned this
                    // the hard way: a card that lands somewhere the screen
                    // cannot show reads as one that was never saved.
                    Text("Saving to \(placeName).")
                }
                if let errorMessage {
                    Section {
                        ClientErrorCard(message: errorMessage) {}
                    }
                }
            }
            .navigationTitle("New task")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await save() } }
                        .disabled(saving || title.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }

    private var destinationBinding: Binding<String> {
        Binding(
            get: { destination ?? workspaceID },
            set: { destination = $0 }
        )
    }

    /// What the footer calls where this is going.
    private var placeName: String {
        let chosen = destination ?? workspaceID
        if chosen.isEmpty { return "Uncategorized" }
        if let match = folders.first(where: {
            (ClientRemote.rawWorkspaceID(of: $0) ?? $0.id) == chosen
        }) {
            return match.name
        }
        return folderName.isEmpty ? "this folder" : folderName
    }

    private func save() async {
        saving = true
        defer { saving = false }
        do {
            _ = try await ClientRemote.todoCreate(
                peer: peer,
                title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                kind: .task,
                notes: body_,
                workspaceID: destination ?? workspaceID
            )
            await onSaved()
            dismiss()
        } catch {
            errorMessage = ClientTunnelCopy.display(error.localizedDescription, host: hostName)
        }
    }
}

// MARK: - Workflows

/// This folder's graphs, and whether one is running right now.
struct ClientWorkspaceWorkflowsView: View {
    let peer: String
    let workspaceID: String
    let hostName: String
    let folderName: String

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
            emptyText: "No workflows here",
            emptyArt: .workflows,
            emptyMessage: "Graphs are drawn on the Mac. Bind one to this folder and its runs show up here.",
            refreshKey: "workspace-workflows-\(workspaceID)",
            reload: { await load() }
        ) {
            ForEach(graphs) { graph in
                NavigationLink {
                    ClientWorkflowDetailView(
                        peer: peer,
                        workspaceID: workspaceID,
                        hostName: hostName,
                        folderName: folderName,
                        graphID: graph.id
                    )
                } label: {
                    ClientJobRow(
                        title: graph.name,
                        subtitle: ClientJobCopy.lastRunPhrase(
                            runs.first { $0.workflowID == graph.id }?.startedAt ?? graph.lastRun
                        ),
                        isLive: runs.contains { $0.workflowID == graph.id && $0.isLive },
                        isEnabled: graph.enabled,
                        graph: graph,
                        liveRun: runs.first { $0.workflowID == graph.id && $0.isLive }
                    )
                }
                .buttonStyle(.plain)
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
            errorMessage = ClientTunnelCopy.display(error.localizedDescription, host: hostName)
        }
        loaded = true
    }
}

// MARK: - Automations

/// This folder's scheduled jobs, and whether one is running right now.
struct ClientWorkspaceAutomationsView: View {
    let peer: String
    let workspaceID: String
    let hostName: String
    let folderName: String

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
            emptyText: "Nothing scheduled here",
            emptyArt: .automations,
            emptyMessage: "Jobs are set up on the Mac. This folder's runs and their output land here.",
            refreshKey: "workspace-automations-\(workspaceID)",
            reload: { await load() }
        ) {
            ForEach(jobs) { job in
                NavigationLink {
                    ClientAutomationDetailView(
                        peer: peer,
                        workspaceID: workspaceID,
                        hostName: hostName,
                        folderName: folderName,
                        jobID: job.id
                    )
                } label: {
                    ClientJobRow(
                        title: job.name,
                        subtitle: job.schedule.summary,
                        isLive: runs.contains { $0.jobId == job.id && $0.isRunning },
                        isEnabled: job.enabled,
                        cadence: job.schedule
                    )
                }
                .buttonStyle(.plain)
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
            errorMessage = ClientTunnelCopy.display(error.localizedDescription, host: hostName)
        }
        loaded = true
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
                    .lineLimit(1)
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
                } else if !isEnabled {
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
        .opacity(isEnabled || isLive ? 1 : 0.7)
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
