// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

#if !os(macOS)
import SwiftUI

/// The exact task run, with a door into that folder's files and history.
///
/// This is not a chat. The transcript stays the selected result. Compact
/// layouts push Changes or History and return here. Wide iPad keeps the run
/// visible and reviews the folder beside it.
struct ClientTaskResultView: View {
    let peer: String
    let hostName: String
    let folderName: String
    let workspaceID: String
    let runID: String
    var seedFolder: WorkspaceFolder? = nil
    var gitSession: GitCommitSession? = nil

    @State private var session: ClientAutomationSession
    @State private var liveFolder: WorkspaceFolder?
    @State private var folderMissing = false
    @State private var inspectorSurface: TaskResultWorkspaceSurface = .changes
    @State private var pushedSurface: TaskResultWorkspaceSurface?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var typeSize

    init(
        peer: String,
        hostName: String,
        folderName: String,
        workspaceID: String,
        runID: String,
        seedFolder: WorkspaceFolder? = nil,
        gitSession: GitCommitSession? = nil,
        service: any ClientJobService = ClientRemoteJobService()
    ) {
        self.peer = peer
        self.hostName = hostName
        self.folderName = folderName
        self.workspaceID = workspaceID
        self.runID = runID
        self.seedFolder = seedFolder
        self.gitSession = gitSession
        _session = State(initialValue: ClientAutomationSession(
            peer: peer, workspaceID: workspaceID, hostName: hostName, folderName: folderName,
            runID: runID, service: service
        ))
        _liveFolder = State(initialValue: seedFolder)
        if let seedFolder { _folderMissing = State(initialValue: !seedFolder.exists) }
    }

    private var run: RunRecord? {
        session.runs.first { $0.id == runID }
    }

    private var folder: WorkspaceFolder {
        if var live = liveFolder ?? seedFolder {
            live.id = workspaceID.isEmpty ? live.id : workspaceID
            if live.name.isEmpty { live.name = folderName }
            return live
        }
        return WorkspaceFolder(
            id: workspaceID, path: "", name: folderName, addedAtMs: 0, exists: !folderMissing
        )
    }

    private var route: TaskResultRoute {
        TaskResultRoute(
            runID: runID,
            workspaceID: workspaceID,
            folderName: folder.name.isEmpty ? folderName : folder.name,
            hostName: hostName,
            folderMissing: folderMissing,
            changeCount: folder.git?.files.count
        )
    }

    var body: some View {
        GeometryReader { geometry in
            let wide = geometry.size.width >= 760 && !typeSize.isAccessibilitySize && route.canReviewWorkspace
            Group {
                if wide {
                    wideLayout(width: geometry.size.width)
                } else {
                    NavigationStack {
                        resultColumn(showsFolderLinks: true, wide: false)
                            .navigationTitle(run?.name ?? "Result")
                            .navigationBarTitleDisplayMode(.inline)
                            .toolbarBackground(Theme.background, for: .navigationBar)
                            .toolbarBackground(.visible, for: .navigationBar)
                            .toolbar {
                                ToolbarItem(placement: .topBarTrailing) {
                                    Button("Done", .done) { dismiss() }
                                }
                            }
                            .navigationDestination(item: $pushedSurface) { surface in
                                reviewDestination(surface, showsTitle: true)
                            }
                    }
                }
            }
            .onChange(of: wide) { _, isWide in
                if isWide { pushedSurface = nil }
            }
        }
        .background(Theme.background)
        .task {
            if let run = session.runs.first(where: { $0.id == runID }) {
                session.selectRun(run)
            }
            await session.appeared()
            await refreshFolder()
        }
        .onDisappear { session.disappeared() }
        .onReceive(NotificationCenter.default.publisher(for: GitCommitTarget.didChange)) { note in
            guard note.object as? GitCommitTarget == GitCommitTarget(peer: peer, workspaceID: workspaceID) else { return }
            Task { await refreshFolder() }
        }
    }

    private func resultColumn(showsFolderLinks: Bool, wide: Bool) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                if let errorMessage = session.errorMessage {
                    ClientErrorCard(message: errorMessage) {
                        Task { await session.load() }
                    }
                }
                if let run {
                    header(run)
                    if session.liveRun?.id == runID {
                        ClientAutomationActions(session: session, pinnedRunID: runID)
                            .padding(Theme.Space.m)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .cardSurface()
                    }
                    TranscriptView(
                        text: session.transcriptText,
                        empty: run.isRunning ? "Waiting for output…" : "No readable output."
                    )
                    .padding(Theme.Space.m)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .cardSurface()
                } else if session.loaded {
                    ClientSectionEmpty(
                        text: "This run is unavailable",
                        message: "It is no longer in this folder's run history. The folder's files and commits are still available below."
                    )
                }
                if showsFolderLinks {
                    TaskResultWorkspaceLinks(route: route) { surface in
                        open(surface, wide: wide)
                    }
                }
            }
            .padding(.horizontal, Theme.Space.m)
            .padding(.top, Theme.Space.s)
            .padding(.bottom, 96)
        }
        .background(Theme.background)
        .refreshable {
            await ClientRefresh.pull("task-result-\(runID)") {
                await session.load()
                await refreshFolder()
            }
        }
    }

    private func wideLayout(width: CGFloat) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: Theme.Space.m) {
                Text(run?.name ?? "Result")
                    .font(ClientType.screenTitle)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Button("Done", .done) { dismiss() }
                    .labelStyle(.iconOnly)
                    .foregroundStyle(Theme.controlGlyph)
                    .frame(width: 44, height: 44)
                    .background(Theme.controlSeat, in: Circle())
                    .overlay(Circle().strokeBorder(Theme.border))
                    .contentShape(Circle())
                    .accessibilityLabel("Done")
            }
            .padding(.horizontal, Theme.Space.m)
            .padding(.top, Theme.Space.m)
            .padding(.bottom, Theme.Space.s)
            .background(Theme.background)
            ThemeRule()
            HStack(spacing: 0) {
                resultColumn(showsFolderLinks: false, wide: true)
                ThemeRule.vertical
                reviewPane
                    .frame(width: min(400, max(300, width * 0.38)))
            }
        }
        .background(Theme.background)
    }

    private var reviewPane: some View {
        VStack(spacing: 0) {
            HStack(spacing: 3) {
                ForEach(TaskResultWorkspaceSurface.allCases) { surface in
                    Button {
                        inspectorSurface = surface
                    } label: {
                        Text(surface.title)
                            .font(Theme.callout.weight(inspectorSurface == surface ? .semibold : .medium))
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .foregroundStyle(inspectorSurface == surface ? Theme.accent : Theme.controlGlyph)
                            .background(
                                inspectorSurface == surface ? Theme.accentSoft : .clear,
                                in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                            )
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(inspectorSurface == surface ? [.isSelected] : [])
                }
            }
            .padding(.horizontal, Theme.Space.s)
            .padding(.vertical, Theme.Space.s)
            ThemeRule()
            NavigationStack {
                reviewDestination(inspectorSurface, showsTitle: false)
            }
            .id(inspectorSurface)
        }
        .background(Theme.background)
    }

    @ViewBuilder
    private func reviewDestination(_ surface: TaskResultWorkspaceSurface, showsTitle: Bool) -> some View {
        switch surface {
        case .changes:
            ClientWorkspaceChangesView(
                peer: peer,
                workspaceID: workspaceID,
                folder: folder,
                hostName: hostName,
                session: gitSession,
                showsNavigationTitle: showsTitle
            )
            .id(GitCommitTarget(peer: peer, workspaceID: workspaceID))
        case .history:
            ClientWorkspaceHistoryView(
                peer: peer,
                workspaceID: workspaceID,
                folder: folder,
                hostName: hostName,
                showsNavigationTitle: showsTitle
            )
        }
    }

    private func header(_ run: RunRecord) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack {
                StatusPill(status: run.status, text: run.endedLabel)
                Spacer()
                Text(run.startedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(ClientType.caption)
                    .foregroundStyle(Theme.controlGlyph)
            }
            ClientFactRow(label: "Agent", value: run.backend)
            ClientFactRow(label: "Folder", value: route.folderLabel)
            if run.isRunning {
                Text("This run continues on \(hostName).")
                    .font(ClientType.caption)
                    .foregroundStyle(Theme.controlGlyph)
            }
        }
        .padding(Theme.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
    }

    private func open(_ surface: TaskResultWorkspaceSurface, wide: Bool) {
        guard route.canReviewWorkspace else { return }
        if wide {
            inspectorSurface = surface
        } else {
            pushedSurface = surface
        }
    }

    private func refreshFolder() async {
        if let seedFolder {
            liveFolder = seedFolder
            folderMissing = !seedFolder.exists
            return
        }
        guard !workspaceID.isEmpty else {
            folderMissing = false
            return
        }
        do {
            let fresh = try await ClientRemote.status(peer: peer, workspace: workspaceID)
            guard !Task.isCancelled else { return }
            var merged = fresh
            merged.id = workspaceID
            if merged.name.isEmpty { merged.name = folderName }
            liveFolder = merged
            folderMissing = !merged.exists
        } catch {
            guard !Task.isCancelled else { return }
        }
    }
}
#endif
