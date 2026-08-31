// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

#if !os(macOS)
import SwiftUI

/// iPad workspace for a folder's graphs: list, board, run column.
///
/// Regular width only. Compact uses the stacked phone screens.
struct ClientWorkflowWorkspace: View {
    let peer: String
    let workspaceID: String
    let hostName: String
    let folderName: String

    @State private var session: ClientWorkflowSession

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
    }

    var body: some View {
        GeometryReader { geo in
            let stackRun = geo.size.width < 800
            HStack(spacing: 0) {
                list
                    .frame(width: min(280, geo.size.width * 0.32))
                ThemeRule.vertical
                if stackRun {
                    VStack(spacing: 0) {
                        board
                        ThemeRule()
                        runColumn
                            .frame(minHeight: 220)
                    }
                } else {
                    board
                    ThemeRule.vertical
                    runColumn
                        .frame(width: min(320, geo.size.width * 0.34))
                }
            }
        }
        .background(Theme.background)
        .navigationTitle("Workflows")
        .navigationBarTitleDisplayMode(.inline)
        .task { await session.appeared() }
        .onDisappear { session.disappeared() }
    }

    private var list: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
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
                    ClientSectionEmpty(
                        text: "No workflows here",
                        art: .workflows,
                        message: "Graphs are drawn on the Mac. Bind one to this folder and its runs land here."
                    )
                } else {
                    ForEach(session.graphs) { graph in
                        Button {
                            session.selectGraph(graph.id)
                        } label: {
                            ClientJobRow(
                                title: graph.name,
                                subtitle: ClientJobCopy.lastRunPhrase(
                                    session.lastRun(for: graph)?.startedAt ?? graph.lastRun
                                ),
                                isLive: session.runs.contains { $0.workflowID == graph.id && $0.isLive },
                                isEnabled: graph.enabled,
                                graph: graph,
                                liveRun: session.runs.first { $0.workflowID == graph.id && $0.isLive },
                                showsChevron: false,
                                isSelected: session.selectedGraphID == graph.id
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(Theme.Space.m)
        }
        .refreshable {
            await ClientRefresh.pull("workspace-workflows-\(workspaceID)") {
                await session.load()
            }
        }
    }

    @ViewBuilder
    private var board: some View {
        if let graph = session.selectedGraph {
            ClientWorkflowBoard(
                graph: graph,
                run: session.liveRun ?? session.selectedRun,
                selectedNodeID: session.selectedNodeID,
                onSelect: { session.selectNode($0) }
            )
        } else {
            ClientSectionEmpty(text: "Pick a workflow", message: "Its graph and its last runs open here.")
                .padding(Theme.Space.m)
        }
    }

    private var runColumn: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                if let graph = session.selectedGraph {
                    Text(graph.name)
                        .font(ClientType.sectionTitle)
                    Text(graph.schedule.summary)
                        .font(ClientType.caption)
                        .foregroundStyle(.secondary)
                    ClientWorkflowActions(session: session)
                    if let run = session.selectedRun {
                        StatusPill(status: run.status, text: run.endedLabel)
                        TranscriptView(
                            text: session.transcriptText,
                            empty: run.isLive ? "Waiting for output…" : "No readable output."
                        )
                    }
                    let history = session.runs(of: graph).prefix(5)
                    if !history.isEmpty {
                        Text("Recent runs")
                            .font(ClientType.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                            .padding(.top, Theme.Space.xs)
                        ForEach(Array(history)) { run in
                            Button {
                                session.selectRun(run)
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
            .padding(Theme.Space.m)
        }
        .background(Theme.background)
    }
}

#endif
