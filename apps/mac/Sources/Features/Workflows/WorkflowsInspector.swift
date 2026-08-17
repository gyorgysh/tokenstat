// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

import SwiftUI

/// The selected workflow or run. The list stays an overview.
///
/// The outline is the VoiceOver representation of the graph. The canvas
/// that will edit the same IR is not this pane.
struct WorkflowsInspector: View {
    @Bindable var model: WorkflowsModel
    var folders: [WorkspaceFolder]
    var onClose: () -> Void

    @AppStorage("workflows.followLive") private var followLive = true
    @State private var running: WorkflowGraph?

    var body: some View {
        VStack(spacing: 0) {
            InspectorChromeBar(onClose: onClose) {
                FeatureMark(name: "mark_workflow", tint: Theme.accent, size: 16)
                    .padding(.leading, Theme.Space.m)
                Text(chromeTitle)
                    .font(.system(size: 13, weight: .semibold))
                Spacer(minLength: 0)
            }
            Group {
                if let run = model.selectedRun, model.selectedFocus == .run {
                    runBody(run)
                } else if let graph = model.selectedGraph {
                    graphBody(graph)
                } else {
                    InspectorEmptyState(
                        mark: "mark_workflow",
                        title: "Pick a workflow or a run",
                        subtitle: "The node outline and step transcript open here."
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.background)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.background)
        .sheet(item: $running) { graph in
            RunWorkflowSheet(model: model, graph: graph, folders: folders)
        }
    }

    private var chromeTitle: String {
        switch model.selectedFocus {
        case .run: return "Run"
        case .graph: return "Workflow"
        case .none: return "Workflows"
        }
    }

    private func graphBody(_ graph: WorkflowGraph) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                if graph.id.isEmpty {
                    TextField("Name", text: Binding(
                        get: { model.draft?.name ?? graph.name },
                        set: { model.draft?.name = $0 }
                    ))
                    .textFieldStyle(.roundedBorder)
                    Text("Unsaved draft. It will not run until you save and press Run.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text(graph.name)
                        .font(.system(size: 15, weight: .semibold))
                }

                labeled("Scope", graph.scope.label)
                if let folder = folders.first(where: { $0.id == graph.workspaceID }) {
                    labeled("Folder", folder.name)
                }
                labeled("Budget", budgetLabel(graph.budgetSeconds))
                labeled("Nodes", "\(graph.nodes.count)")
                if let last = model.lastRun(for: graph) {
                    labeled("Last", last.startedAt.formatted(date: .abbreviated, time: .shortened))
                }

                WorkflowOutline(nodes: graph.nodes, edges: graph.edges)

                HStack(spacing: Theme.Space.s) {
                    if graph.id.isEmpty {
                        Button("Save", .save) { Task { await model.saveDraft() } }
                            .buttonStyle(AccentButtonStyle())
                        Button("Discard", .dismiss) { model.discardDraft() }
                            .buttonStyle(SecondaryButtonStyle())
                    } else if let last = model.lastRun(for: graph), last.isLive {
                        if last.isWaiting {
                            Button("Continue", .next) { Task { await model.continueRun(last) } }
                                .buttonStyle(AccentButtonStyle())
                        }
                        Button("Stop", .stop) { Task { await model.stop(last) } }
                            .buttonStyle(SecondaryButtonStyle())
                    } else {
                        Button("Run", .run) { running = graph }
                            .buttonStyle(AccentButtonStyle())
                    }
                }
            }
            .padding(Theme.Space.m)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func runBody(_ run: WorkflowRunRecord) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                HStack {
                    Text(run.name)
                        .font(.system(size: 15, weight: .semibold))
                    Spacer()
                    if run.isWaiting {
                        Button("Continue", .next) { Task { await model.continueRun(run) } }
                            .buttonStyle(AccentButtonStyle())
                    }
                    if run.isLive {
                        Button("Stop", .stop) { Task { await model.stop(run) } }
                            .buttonStyle(SecondaryButtonStyle())
                            .help("Kill this run now")
                    }
                    StatusPill(status: run.status, text: run.endedLabel)
                }
                if !run.input.isEmpty {
                    Text(run.input)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
                Text(run.startedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                BrandToggleChip(title: "Follow", isOn: $followLive)
                    .help("Keep the transcript pinned to the newest line")
            }
            .padding(Theme.Space.m)

            if let graph = model.graphs.first(where: { $0.id == run.workflowID }) ?? model.selectedGraph {
                WorkflowOutline(
                    nodes: graph.nodes,
                    edges: graph.edges,
                    steps: run.steps,
                    selectedID: model.selectedStepID,
                    onSelect: { model.selectStep($0) }
                )
                .padding(.horizontal, Theme.Space.m)
            }

            ScrollViewReader { proxy in
                ScrollView {
                    TranscriptView(
                        text: model.transcriptText,
                        empty: run.isLive ? "Waiting for output…" : "(No readable output)"
                    )
                    .padding(Theme.Space.m)
                    Color.clear
                        .frame(height: 1)
                        .id("workflow-transcript-tail")
                }
                .background(Theme.background)
                .onChange(of: model.transcriptText) { _, _ in
                    guard followLive else { return }
                    proxy.scrollTo("workflow-transcript-tail", anchor: .bottom)
                }
            }
        }
    }

    private func labeled(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 72, alignment: .leading)
            Text(value)
                .font(.callout)
                .textSelection(.enabled)
        }
    }

    private func budgetLabel(_ seconds: UInt64) -> String {
        if seconds == 0 { return "No limit" }
        let minutes = max(1, seconds / 60)
        return "\(minutes) min"
    }
}
