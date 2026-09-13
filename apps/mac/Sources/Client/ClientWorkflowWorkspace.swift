// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

#if !os(macOS)
import SwiftUI
import UIKit

/// One session, presented as a phone list or an iPad workbench.
struct ClientWorkflowWorkspace: View {
    let peer: String
    let workspaceID: String
    let hostName: String
    let folderName: String

    @State private var session: ClientWorkflowSession
    @State private var search = ""
    @State private var navigation = ClientJobNavigation()
    @State private var editor: WorkflowEditorRoute?
    @State private var pendingDelete: WorkflowGraph?
    @State private var showingHistory = false
    @Environment(\.dynamicTypeSize) private var typeSize
    private let opensDetailWhenReady: Bool

    init(peer: String, workspaceID: String, hostName: String, folderName: String) {
        self.peer = peer
        self.workspaceID = workspaceID
        self.hostName = hostName
        self.folderName = folderName
        _session = State(
            initialValue: ClientWorkflowSession(
                peer: peer,
                workspaceID: workspaceID,
                hostName: hostName,
                folderName: folderName
            )
        )
        opensDetailWhenReady = false
    }

    init(session: ClientWorkflowSession, opensDetail: Bool = false) {
        peer = session.peer
        workspaceID = session.workspaceID
        hostName = session.hostName
        folderName = session.folderName
        _session = State(initialValue: session)
        _navigation = State(initialValue: ClientJobNavigation())
        opensDetailWhenReady = opensDetail
    }

    var body: some View {
        GeometryReader { geo in
            let layout = ClientJobLayout.resolve(
                width: geo.size.width,
                prefersStack: UIDevice.current.userInterfaceIdiom != .pad || typeSize.isAccessibilitySize
            )
            workspace(layout)
                .navigationDestination(isPresented: Binding(
                    get: { navigation.presentsDetail(in: layout) },
                    set: { navigation.presentedDetailChanged($0, in: layout) }
                )) {
                    ClientWorkflowDetailView(session: session)
                }
        }
        .background(Theme.background)
        .navigationTitle("Workflows")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("New workflow", .create) {
                    editor = WorkflowEditorRoute(
                        workspaceID: workspaceID, folderName: folderName, graph: nil
                    )
                }
                .labelStyle(.iconOnly)
                .keyboardShortcut("n", modifiers: .command)
                .disabled(editor != nil || showingHistory)
            }
        }
        .fullScreenCover(item: $editor) { route in
            WorkflowEditorDestination(
                target: WorkflowEditorTarget(peer: peer),
                workspaceID: route.workspaceID,
                folderName: route.folderName,
                hostName: hostName,
                existing: route.graph
            ) { created in
                await session.load()
                if let created { session.selectGraph(created.id) }
            }
        }
        .sheet(isPresented: $showingHistory) {
            if let graph = session.selectedGraph {
                ClientWorkflowHistorySheet(session: session, graphID: graph.id) { run in
                    session.selectRun(run)
                }
                .modifier(HistorySheetPresentation())
            }
        }
        .confirmationDialog(
            "Delete \(pendingDelete?.name ?? "this workflow")?",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let graph = pendingDelete {
                    pendingDelete = nil
                    Task { await session.remove(graph) }
                }
            }
            Button("Keep it", role: .cancel) { pendingDelete = nil }
        } message: {
            Text("The graph is removed. Past runs stay on this computer.")
        }
        .onReceive(NotificationCenter.default.publisher(for: WorkflowEditorSession.didChange)) { _ in
            Task { await session.load() }
        }
        .task {
            await session.appeared()
            if opensDetailWhenReady { navigation.openDetail() }
            #if WORKBENCH_QA
            if ProcessInfo.processInfo.environment["WORKBENCH_HISTORY"] == "1" {
                showingHistory = true
            }
            #endif
        }
        .onDisappear { session.disappeared() }
        .onChange(of: session.input) { _, _ in navigation.openDetail() }
    }

    @ViewBuilder
    private func workspace(_ layout: ClientJobLayout) -> some View {
        if layout.arrangement == .compact {
            list(layout)
        } else {
            HStack(spacing: 0) {
                list(layout).frame(width: layout.listWidth)
                ThemeRule.vertical
                if layout.arrangement == .twoColumns {
                    ScrollView {
                        VStack(spacing: 0) {
                            board(fitsContent: true)
                            ThemeRule()
                            runContent
                        }
                    }
                } else {
                    board(fitsContent: false)
                    ThemeRule.vertical
                    ScrollView { runContent }.frame(width: layout.runWidth)
                }
            }
        }
    }

    private var listSummary: String {
        "\(session.graphs.count) workflows · \(session.runs.filter(\.isLive).count) running"
    }

    private var filteredGraphs: [WorkflowGraph] {
        session.graphs.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }
    }

    private var emptyState: some View {
        ClientSectionEmpty(
            text: "No workflows here",
            art: .workflows,
            message: "Create a workflow for this folder. It runs on the connected computer.",
            actionTitle: "New workflow",
            actionIcon: .create,
            action: {
                editor = WorkflowEditorRoute(
                    workspaceID: workspaceID, folderName: folderName, graph: nil
                )
            }
        )
    }

    @ViewBuilder
    private func list(_ layout: ClientJobLayout) -> some View {
        if layout.arrangement == .compact {
            compactList
        } else {
            splitList
        }
    }

    private var compactList: some View {
        List {
            TextField("Search workflows", text: $search)
                .textFieldStyle(.themed)
                .accessibilityLabel("Search workflows")
                .clientCardRow()
            if session.loaded, !session.graphs.isEmpty {
                Text(listSummary)
                    .font(ClientType.caption)
                    .foregroundStyle(Theme.controlGlyph)
                    .clientCardRow()
            }
            if let errorMessage = session.errorMessage {
                ClientErrorCard(message: errorMessage) {
                    Task { await session.load() }
                }
                .clientCardRow()
            }
            if !session.loaded {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .padding(.top, Theme.Space.xl)
                    .clientCardRow()
            } else if session.graphs.isEmpty {
                emptyState.clientCardRow()
            } else if filteredGraphs.isEmpty {
                Text("No matching workflows")
                    .font(ClientType.body)
                    .foregroundStyle(Theme.controlGlyph)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, Theme.Space.l)
                    .clientCardRow()
            } else {
                ForEach(filteredGraphs) { graph in
                    graphButton(graph, showsChevron: true, isSelected: false)
                        .clientCardRow()
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button("Delete", role: .destructive) { pendingDelete = graph }
                            Button("Edit") { openEditor(graph) }
                                .tint(Theme.accent)
                        }
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Theme.background)
        .contentMargins(.top, Theme.Space.m, for: .scrollContent)
        .refreshable {
            await ClientRefresh.pull("workspace-workflows-\(workspaceID)") {
                await session.load()
            }
        }
    }

    private var splitList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Theme.Space.s) {
                TextField("Search workflows", text: $search).textFieldStyle(.themed)
                    .accessibilityLabel("Search workflows")
                if session.loaded, !session.graphs.isEmpty {
                    Text(listSummary)
                        .font(ClientType.caption)
                        .foregroundStyle(Theme.controlGlyph)
                }
                if let errorMessage = session.errorMessage {
                    ClientErrorCard(message: errorMessage) {
                        Task { await session.load() }
                    }
                }
                if !session.loaded {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.top, Theme.Space.xl)
                } else if session.graphs.isEmpty {
                    emptyState
                } else if filteredGraphs.isEmpty {
                    Text("No matching workflows")
                        .font(ClientType.body)
                        .foregroundStyle(Theme.controlGlyph)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, Theme.Space.l)
                } else {
                    ForEach(filteredGraphs) { graph in
                        graphButton(
                            graph,
                            showsChevron: false,
                            isSelected: session.selectedGraphID == graph.id
                        )
                    }
                }
            }
            .padding(Theme.Space.m)
        }
        .scrollBounceBehavior(.always)
        .refreshable {
            await ClientRefresh.pull("workspace-workflows-\(workspaceID)") {
                await session.load()
            }
        }
    }

    private func graphButton(_ graph: WorkflowGraph, showsChevron: Bool, isSelected: Bool) -> some View {
        Button {
            session.selectGraph(graph.id)
            navigation.openDetail()
        } label: {
            ClientJobRow(
                title: graph.name,
                subtitle: HostScheduleClock.listSubtitle(
                    cadence: graph.schedule.summary,
                    next: graph.nextRun,
                    enabled: graph.enabled,
                    repeats: graph.schedule.repeats,
                    timezone: session.schedulerTimezone
                ),
                isLive: session.runs.contains { $0.workflowID == graph.id && $0.isLive },
                isEnabled: graph.enabled,
                graph: graph,
                liveRun: session.runs.first { $0.workflowID == graph.id && $0.isLive },
                cadence: graph.schedule,
                showsChevron: showsChevron,
                isSelected: isSelected
            )
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Edit workflow") { openEditor(graph) }
            Button("Delete workflow", role: .destructive) { pendingDelete = graph }
        }
    }

    private func openEditor(_ graph: WorkflowGraph) {
        editor = WorkflowEditorRoute(
            workspaceID: workspaceID, folderName: folderName, graph: graph
        )
    }

    @ViewBuilder
    private func board(fitsContent: Bool) -> some View {
        if let graph = session.selectedGraph {
            ClientWorkflowBoard(
                graph: graph,
                run: session.selectedRun,
                selectedNodeID: session.selectedNodeID,
                fitsContent: fitsContent,
                onSelect: {
                    session.selectNode($0)
                    navigation.openDetail()
                }
            )
        } else {
            ClientSectionEmpty(text: "Pick a workflow", message: "Its graph and its last runs open here.")
                .padding(Theme.Space.m)
        }
    }

    private var runContent: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Text("Run details").font(ClientType.sectionTitle)
            if let graph = session.selectedGraph {
                HStack(spacing: Theme.Space.s) {
                    Text(graph.name)
                        .font(ClientType.sectionTitle)
                    Spacer(minLength: 0)
                    Button("Edit", .edit) { openEditor(graph) }
                        .buttonStyle(SecondaryButtonStyle(small: true))
                    Button("Delete", .delete) { pendingDelete = graph }
                        .buttonStyle(SecondaryButtonStyle(small: true))
                }
                Text(graph.schedule.summary)
                    .font(ClientType.caption)
                    .foregroundStyle(Theme.controlGlyph)
                ClientWorkflowActions(session: session, shortcutsEnabled: editor == nil && !showingHistory)
                if let run = session.selectedRun {
                    StatusPill(status: run.status, text: run.endedLabel)
                    TranscriptView(
                        text: session.transcriptText,
                        empty: run.isLive ? "Waiting for output…" : "No readable output."
                    )
                }
                let history = AutomationRunHistory.preview(
                    session.runs(of: graph),
                    id: \.id, startedAtMs: \.startedAtMs, isLive: \.isLive
                )
                if !history.isEmpty {
                    Text("Recent runs")
                        .font(ClientType.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .padding(.top, Theme.Space.xs)
                    if AutomationRunHistory.showsAllRuns(session.runs(of: graph).count) {
                        Button {
                            showingHistory = true
                        } label: {
                            ClientAllRunsRow(count: session.runs(of: graph).count)
                        }
                        .buttonStyle(.plain)
                    }
                    ForEach(history) { run in
                        Button {
                            session.selectRun(run)
                            navigation.openDetail()
                        } label: {
                            ClientPastRunRow(
                                title: run.name,
                                status: run.status,
                                label: run.endedLabel,
                                started: run.startedAt,
                                timezone: session.schedulerTimezone,
                                isSelected: session.selectedRunID == run.id
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(Theme.Space.m)
        .background(Theme.background)
    }
}

#endif
