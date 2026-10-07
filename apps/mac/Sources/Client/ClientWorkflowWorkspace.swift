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
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    private var hasRoom: Bool {
        ClientLayout.hasRoom(horizontal: horizontalSizeClass, vertical: verticalSizeClass)
    }
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
                prefersStack: !hasRoom || typeSize.isAccessibilitySize
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
        .navigationTitle(L10n.text("common.workflows"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(L10n.text("apple.clientworkflowworkspace.new_workflow.750c4da4"), .create) {
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
                .modifier(HistorySheetPresentation(hasRoom: hasRoom))
            }
        }
        .confirmationDialog(
            L10n.text("apple.clientworkflowworkspace.delete_0.dc6c5ae4", "\(pendingDelete?.name ?? L10n.text("apple.clientworkflowworkspace.this_workflow.a7b5fc94"))"),
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(L10n.text("common.delete"), role: .destructive) {
                if let graph = pendingDelete {
                    pendingDelete = nil
                    Task { await session.remove(graph) }
                }
            }
            Button(L10n.text("apple.clientworkflowworkspace.keep_it.fdce5da2"), role: .cancel) { pendingDelete = nil }
        } message: {
            Text(L10n.text("apple.clientworkflowworkspace.the_graph_is_removed_past_runs_stay_on_thi.63fef9bc"))
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
        L10n.text("apple.clientworkflowworkspace.0_workflows_1_running.3c6bc0ea", "\(session.graphs.count)", "\(session.runs.filter(\.isLive).count)")
    }

    private var filteredGraphs: [WorkflowGraph] {
        session.graphs.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }
    }

    private var emptyState: some View {
        ClientSectionEmpty(
            text: L10n.text("apple.clientworkflowworkspace.no_workflows_here.e58560d8"),
            art: .workflows,
            message: L10n.text("apple.clientworkflowworkspace.create_a_workflow_for_this_folder_it_runs.b0f95793"),
            actionTitle: L10n.text("apple.clientworkflowworkspace.new_workflow.750c4da4"),
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
            TextField(L10n.text("apple.clientworkflowworkspace.search_workflows.e827cf3e"), text: $search)
                .textFieldStyle(.themed)
                .accessibilityLabel(L10n.text("apple.clientworkflowworkspace.search_workflows.e827cf3e"))
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
                Text(L10n.text("apple.clientworkflowworkspace.no_matching_workflows.2b5eeb7d"))
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
                            Button(L10n.text("common.delete"), role: .destructive) { pendingDelete = graph }
                            Button(L10n.text("common.edit")) { openEditor(graph) }
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
                TextField(L10n.text("apple.clientworkflowworkspace.search_workflows.e827cf3e"), text: $search).textFieldStyle(.themed)
                    .accessibilityLabel(L10n.text("apple.clientworkflowworkspace.search_workflows.e827cf3e"))
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
                    Text(L10n.text("apple.clientworkflowworkspace.no_matching_workflows.2b5eeb7d"))
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
            Button(L10n.text("apple.clientworkflowworkspace.edit_workflow.f5dd71b2")) { openEditor(graph) }
            Button(L10n.text("apple.clientworkflowworkspace.delete_workflow.b438c4a8"), role: .destructive) { pendingDelete = graph }
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
            ClientSectionEmpty(text: L10n.text("apple.clientworkflowworkspace.pick_a_workflow.b8b2a4dd"), message: L10n.text("apple.clientworkflowworkspace.its_graph_and_its_last_runs_open_here.f62091d4"))
                .padding(Theme.Space.m)
        }
    }

    private var runContent: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Text(L10n.text("apple.clientworkflowworkspace.run_details.7bbc3690")).font(ClientType.sectionTitle)
            if let graph = session.selectedGraph {
                HStack(spacing: Theme.Space.s) {
                    Text(graph.name)
                        .font(ClientType.sectionTitle)
                    Spacer(minLength: 0)
                    Button(L10n.text("common.edit"), .edit) { openEditor(graph) }
                        .buttonStyle(SecondaryButtonStyle(small: true))
                    Button(L10n.text("common.delete"), .delete) { pendingDelete = graph }
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
                        empty: run.isLive ? L10n.text("apple.clientworkflowworkspace.waiting_for_output.f05fefe2") : L10n.text("apple.clientworkflowworkspace.no_readable_output.cd218ba3")
                    )
                }
                let history = AutomationRunHistory.preview(
                    session.runs(of: graph),
                    id: \.id, startedAtMs: \.startedAtMs, isLive: \.isLive
                )
                if !history.isEmpty {
                    Text(L10n.text("apple.clientworkflowworkspace.recent_runs.237112b8"))
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
