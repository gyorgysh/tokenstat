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
                    ClientWorkflowActions(session: session)
                        .padding(Theme.Space.m)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .cardSurface()
                    runs(of: graph)
                } else if session.loaded {
                    ClientSectionEmpty(
                        text: "This workflow is gone",
                        message: "It is not in the folder any more."
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
        .navigationTitle(session.selectedGraph?.name ?? "Workflow")
        .navigationBarTitleDisplayMode(.inline)
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
                ClientFactRow(label: "Schedule", value: graph.schedule.summary)
                ClientFactRow(label: "Budget", value: ClientJobCopy.budget(graph.budgetSeconds))
            }
            if let next = graph.nextRun, graph.enabled {
                ClientFactRow(
                    label: "Next",
                    value: next.formatted(date: .abbreviated, time: .shortened)
                )
            }
            ClientFactRow(
                label: "Last",
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
        let history = session.runs(of: graph).prefix(6)
        if !history.isEmpty {
            Text("Recent runs")
                .font(ClientType.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
                .padding(.top, Theme.Space.xs)
            ForEach(Array(history)) { run in
                NavigationLink {
                    ClientWorkflowRunView(session: session, runID: run.id)
                } label: {
                    ClientPastRunRow(
                        title: run.name,
                        status: run.status,
                        label: run.endedLabel,
                        started: run.startedAt
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }
}

#endif
