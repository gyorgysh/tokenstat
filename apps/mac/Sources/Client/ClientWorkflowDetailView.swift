// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

#if !os(macOS)
import SwiftUI

/// One graph on a phone: the picture, a prompt, Run / Stop / Continue.
struct ClientWorkflowDetailView: View {
    let peer: String
    let workspaceID: String
    let hostName: String
    let folderName: String
    let graphID: String

    @State private var session: ClientWorkflowSession
    @State private var editor: WorkflowEditorRoute?
    @State private var pendingDelete = false

    init(peer: String, workspaceID: String, hostName: String, folderName: String, graphID: String) {
        self.peer = peer
        self.workspaceID = workspaceID
        self.hostName = hostName
        self.folderName = folderName
        self.graphID = graphID
        _session = State(
            initialValue: ClientWorkflowSession(
                peer: peer,
                workspaceID: workspaceID,
                hostName: hostName,
                folderName: folderName,
                graphID: graphID
            )
        )
    }

    init(session: ClientWorkflowSession) {
        peer = session.peer
        workspaceID = session.workspaceID
        hostName = session.hostName
        folderName = session.folderName
        graphID = session.selectedGraphID ?? ""
        _session = State(initialValue: session)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                if let errorMessage = session.errorMessage {
                    ClientErrorCard(message: errorMessage) {
                        Task { await session.load() }
                    }
                }
                if let graph = session.selectedGraph {
                    facts(graph)
                    picture(graph)
                    ClientWorkflowActions(session: session, shortcutsEnabled: editor == nil)
                        .padding(Theme.Space.m)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .cardSurface()
                    runs(of: graph)
                } else if session.loaded {
                    ClientSectionEmpty(
                        text: L10n.text("apple.clientworkflowdetailview.this_workflow_is_gone.f1012e17"),
                        message: L10n.text("apple.clientworkflowdetailview.it_is_not_in_the_folder_any_more.ff5d54d4")
                    )
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.top, Theme.Space.xl)
                }
            }
            .padding(.horizontal, Theme.Space.m)
            .padding(.top, Theme.Space.s)
            .padding(.bottom, 96)
        }
        .background(Theme.background)
        .navigationTitle(session.selectedGraph?.name ?? L10n.text("apple.clientworkflowdetailview.workflow.2e2d5c56"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let graph = session.selectedGraph {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(L10n.text("common.edit"), .edit) {
                        editor = WorkflowEditorRoute(
                            workspaceID: workspaceID, folderName: folderName, graph: graph
                        )
                    }
                    .labelStyle(.iconOnly)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(L10n.text("common.delete"), .delete, role: .destructive) { pendingDelete = true }
                        .labelStyle(.iconOnly)
                }
            }
        }
        .fullScreenCover(item: $editor) { route in
            WorkflowEditorDestination(
                target: WorkflowEditorTarget(peer: peer),
                workspaceID: route.workspaceID,
                folderName: route.folderName,
                hostName: hostName,
                existing: route.graph
            ) { _ in
                await session.load()
            }
        }
        .confirmationDialog(
            L10n.text("apple.clientworkflowdetailview.delete_0.dc6c5ae4", "\(session.selectedGraph?.name ?? L10n.text("apple.clientworkflowdetailview.this_workflow.a7b5fc94"))"),
            isPresented: $pendingDelete,
            titleVisibility: .visible
        ) {
            Button(L10n.text("common.delete"), role: .destructive) {
                if let graph = session.selectedGraph {
                    Task { await session.remove(graph) }
                }
            }
            Button(L10n.text("apple.clientworkflowdetailview.keep_it.fdce5da2"), role: .cancel) {}
        } message: {
            Text(L10n.text("apple.clientworkflowdetailview.the_graph_is_removed_past_runs_stay_on_thi.63fef9bc"))
        }
        .onReceive(NotificationCenter.default.publisher(for: WorkflowEditorSession.didChange)) { _ in
            Task { await session.load() }
        }
        .refreshable {
            await ClientRefresh.pull("workflow-detail-\(graphID)") { await session.load() }
        }
        .task { await session.appeared() }
        .onDisappear { session.disappeared() }
    }

    private func facts(_ graph: WorkflowGraph) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Text(hostName)
                .font(ClientType.caption)
                .foregroundStyle(.secondary)
            HStack(alignment: .top, spacing: Theme.Space.m) {
                ClientFactRow(label: L10n.text("apple.clientworkflowdetailview.schedule.f4830a1d"), value: graph.schedule.summary)
                ClientFactRow(label: L10n.text("apple.clientworkflowdetailview.budget.1c6225ec"), value: ClientJobCopy.budget(graph.budgetSeconds))
            }
            if HostScheduleClock.clock(session.schedulerTimezone) != nil
                || (graph.nextRun != nil && graph.enabled) {
                HStack(alignment: .top, spacing: Theme.Space.m) {
                    if let clock = HostScheduleClock.clock(session.schedulerTimezone) {
                        ClientFactRow(label: L10n.text("apple.clientworkflowdetailview.time_zone.b9fe1464"), value: clock)
                    }
                    if let next = graph.nextRun, graph.enabled {
                        ClientFactRow(
                            label: L10n.text("common.next"),
                            value: HostScheduleClock.nextRun(next, timezone: session.schedulerTimezone)
                        )
                    }
                }
            }
            ClientFactRow(
                label: L10n.text("apple.clientworkflowdetailview.last.eb970eb0"),
                value: ClientJobCopy.lastRunWhen(
                    session.lastRun(for: graph)?.startedAt ?? graph.lastRun
                )
            )
        }
        .padding(Theme.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
    }

    private func picture(_ graph: WorkflowGraph) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            MiniGraph(
                nodes: graph.nodes,
                edges: graph.edges,
                steps: session.liveRun?.steps ?? [],
                currentNodeID: session.liveRun?.currentNodeID,
                maxColumns: 6,
                dot: 26
            )
            WorkflowStepStrip(nodes: graph.nodes, edges: graph.edges)
        }
        .padding(Theme.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
        .accessibilityLabel(WorkflowLayering.sentence(nodes: graph.nodes, edges: graph.edges))
    }

    @ViewBuilder
    private func runs(of graph: WorkflowGraph) -> some View {
        let all = session.runs(of: graph)
        let history = AutomationRunHistory.preview(
            all, id: \.id, startedAtMs: \.startedAtMs, isLive: \.isLive
        )
        if !history.isEmpty {
            Text(L10n.text("apple.clientworkflowdetailview.recent_runs.237112b8"))
                .font(ClientType.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
                .padding(.top, Theme.Space.xs)
            if AutomationRunHistory.showsAllRuns(all.count) {
                NavigationLink {
                    ClientWorkflowHistoryView(session: session, graphID: graph.id)
                } label: {
                    ClientAllRunsRow(count: all.count)
                }
                .buttonStyle(.plain)
            }
            ForEach(history) { run in
                NavigationLink {
                    ClientWorkflowRunView(session: session, runID: run.id)
                } label: {
                    ClientPastRunRow(
                        title: run.name,
                        status: run.status,
                        label: run.endedLabel,
                        started: run.startedAt,
                        timezone: session.schedulerTimezone,
                        showsChevron: true
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }
}

#endif
