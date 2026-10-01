// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

import SwiftUI

/// The selected workflow, node, or run. The list stays an overview.
///
/// The outline is the VoiceOver representation of the graph. When the
/// canvas is open, this pane edits the selected node on the same IR.
struct WorkflowsInspector: View {
    @Bindable var model: WorkflowsModel
    var folders: [WorkspaceFolder]
    var onClose: () -> Void

    @AppStorage("workflows.followLive") private var followLive = true
    @State private var running: WorkflowGraph?

    var body: some View {
        VStack(spacing: 0) {
            InspectorChromeBar(onClose: onClose) {
                InspectorTitle(title: chromeTitle, symbol: "point.3.connected.trianglepath.dotted")
                Spacer(minLength: 0)
            }
            Group {
                if let run = model.selectedRun, model.selectedFocus == .run {
                    runBody(run)
                } else if model.isEditing, model.selectedNode != nil {
                    WorkflowNodeInspector(model: model)
                } else if model.isEditing, model.selectedEdgeID != nil {
                    edgeBody
                } else if let graph = model.working ?? model.selectedGraph {
                    graphBody(graph)
                } else {
                    InspectorEmptyState(
                        mark: "mark_workflow",
                        title: L10n.text("apple.workflowsinspector.pick_a_workflow_or_a_run.a4388780"),
                        subtitle: L10n.text("apple.workflowsinspector.the_node_outline_and_step_transcript_open.2652bf3c")
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
        if model.isEditing, model.selectedNode != nil { return L10n.text("apple.workflowsinspector.node.e9337253") }
        if model.isEditing, model.selectedEdgeID != nil { return L10n.text("apple.workflowsinspector.edge.0f82fe72") }
        switch model.selectedFocus {
        case .run: return L10n.text("common.run")
        case .graph: return L10n.text("apple.workflowsinspector.workflow.2e2d5c56")
        case .none: return L10n.text("common.workflows")
        }
    }

    private var edgeBody: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                if let id = model.selectedEdgeID,
                   let edge = model.working?.edges.first(where: { $0.id == id }) {
                    labeled(L10n.text("apple.workflowsinspector.from.21819769"), edge.from)
                    labeled(L10n.text("apple.workflowsinspector.to.f4b06ef6"), edge.to)
                    AppMenuPicker(
                        title: L10n.text("apple.workflowsinspector.when.cf9c7aa2"),
                        options: [
                            (value: WorkflowEdgeWhen.ok, label: WorkflowEdgeWhen.ok.label),
                            (value: .error, label: WorkflowEdgeWhen.error.label),
                            (value: .always, label: WorkflowEdgeWhen.always.label),
                        ],
                        selection: Binding(
                            get: { edge.when },
                            set: { model.updateSelectedEdge(when: $0) }
                        )
                    )
                    Text(L10n.text("apple.workflowsinspector.green_is_on_success_red_is_on_error_always.b7b8bf9c"))
                        .font(Theme.caption)
                        .foregroundStyle(.secondary)
                    Button(L10n.text("apple.workflowsinspector.delete_edge.28a5cf08"), .delete, role: .destructive) {
                        model.deleteSelection()
                    }
                    .buttonStyle(SecondaryButtonStyle())
                }
            }
            .padding(Theme.Space.m)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func graphBody(_ graph: WorkflowGraph) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                if model.isEditing {
                    TextField(L10n.text("apple.workflowsinspector.name.dcd1d522"), text: Binding(
                        get: { model.working?.name ?? graph.name },
                        set: { next in
                            model.beginGroupedEdit()
                            model.writeWorking { $0.name = next }
                        }
                    ))
                    .textFieldStyle(.themed)
                    if graph.id.isEmpty {
                        Text(L10n.text("apple.workflowsinspector.unsaved_draft_it_will_not_run_until_you_sa.0158bab7"))
                            .font(Theme.caption)
                            .foregroundStyle(.secondary)
                    }
                    AppMenuPicker(
                        title: L10n.text("apple.workflowsinspector.scope.b073f6c6"),
                        options: WorkflowScope.allCases.map { (value: $0, label: $0.label) },
                        selection: Binding(
                            get: { model.working?.scope ?? graph.scope },
                            set: { model.setWorkingScope($0, workspaceID: graph.workspaceID ?? folders.first?.id) }
                        )
                    )
                    if (model.working?.scope ?? graph.scope) == .workspace {
                        AppMenuPicker(
                            title: L10n.text("apple.workflowsinspector.folder.74ccd433"),
                            options: folders.map { (value: $0.id, label: $0.name) },
                            selection: Binding(
                                get: { model.working?.workspaceID ?? "" },
                                set: { model.setWorkingScope(.workspace, workspaceID: $0) }
                            )
                        )
                    }
                    WorkflowBudgetField(model: model)
                } else if graph.id.isEmpty {
                    TextField(L10n.text("apple.workflowsinspector.name.dcd1d522"), text: Binding(
                        get: { model.draft?.name ?? graph.name },
                        set: { model.draft?.name = $0 }
                    ))
                    .textFieldStyle(.themed)
                    Text(L10n.text("apple.workflowsinspector.unsaved_draft_it_will_not_run_until_you_sa.0158bab7"))
                        .font(Theme.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text(graph.name)
                        .font(Theme.font(15, weight: .semibold))
                    labeled(L10n.text("apple.workflowsinspector.scope.b073f6c6"), graph.scope.label)
                    if let folder = folders.first(where: { $0.id == graph.workspaceID }) {
                        labeled(L10n.text("apple.workflowsinspector.folder.74ccd433"), folder.name)
                    }
                    labeled(L10n.text("apple.workflowsinspector.budget.1c6225ec"), budgetLabel(graph.budgetSeconds))
                }

                labeled(L10n.text("apple.workflowsinspector.nodes.7ac36206"), "\(graph.nodes.count)")
                if let last = model.lastRun(for: graph) {
                    labeled(L10n.text("apple.workflowsinspector.last.eb970eb0"), last.startedAt.formatted(date: .abbreviated, time: .shortened))
                }

                if !model.designTranscript.isEmpty {
                    Text(L10n.text("apple.workflowsinspector.design_transcript.bb036940"))
                        .font(Theme.caption)
                        .foregroundStyle(.tertiary)
                    TranscriptView(text: model.designTranscript, empty: "")
                        .frame(maxHeight: 160)
                }

                WorkflowOutline(
                    nodes: graph.nodes,
                    edges: graph.edges,
                    selectedID: model.selectedNodeID,
                    onSelect: { model.selectNode($0) }
                )

                HStack(spacing: Theme.Space.s) {
                    if graph.id.isEmpty {
                        Button(L10n.text("common.save"), .save) { Task { await model.saveWorking() } }
                            .buttonStyle(AccentButtonStyle())
                        Button(L10n.text("apple.workflowsinspector.discard.eb1a70e3"), .dismiss) { model.discardDraft() }
                            .buttonStyle(SecondaryButtonStyle())
                    } else if model.isEditing {
                        Button(L10n.text("common.save"), .save) { Task { await model.saveWorking() } }
                            .buttonStyle(AccentButtonStyle())
                            .disabled(!model.isDirty)
                    } else if let last = model.lastRun(for: graph), last.isLive {
                        if last.isWaiting {
                            Button(L10n.text("apple.workflowsinspector.continue.31fbef16"), .next) { Task { await model.continueRun(last) } }
                                .buttonStyle(AccentButtonStyle())
                        }
                        Button(L10n.text("common.stop"), .stop) { Task { await model.stop(last) } }
                            .buttonStyle(SecondaryButtonStyle())
                    } else {
                        Button(L10n.text("common.run"), .run) { running = graph }
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
                        .font(Theme.font(15, weight: .semibold))
                    Spacer()
                    if run.isWaiting {
                        Button(L10n.text("apple.workflowsinspector.continue.31fbef16"), .next) { Task { await model.continueRun(run) } }
                            .buttonStyle(AccentButtonStyle())
                    }
                    if run.isLive {
                        Button(L10n.text("common.stop"), .stop) { Task { await model.stop(run) } }
                            .buttonStyle(SecondaryButtonStyle())
                            .help(L10n.text("apple.workflowsinspector.kill_this_run_now.87db925a"))
                    }
                    StatusPill(status: run.status, text: run.endedLabel)
                }
                if !run.input.isEmpty {
                    Text(run.input)
                        .font(Theme.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
                Text(run.startedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(Theme.caption)
                    .foregroundStyle(.tertiary)
                BrandToggleChip(title: L10n.text("apple.workflowsinspector.follow.641d1ef6"), isOn: $followLive)
                    .help(L10n.text("apple.workflowsinspector.keep_the_transcript_pinned_to_the_newest_l.91faa696"))
            }
            .padding(Theme.Space.m)

            if let graph = model.working ?? model.graphs.first(where: { $0.id == run.workflowID }) ?? model.selectedGraph {
                WorkflowOutline(
                    nodes: graph.nodes,
                    edges: graph.edges,
                    steps: run.steps,
                    selectedID: model.selectedStepID,
                    onSelect: { model.selectStep($0) }
                )
                .padding(.horizontal, Theme.Space.m)
            }

            FollowTranscript(
                text: model.transcriptText,
                empty: run.isLive ? "Waiting for output…" : "(No readable output)",
                follow: followLive,
                tailID: "workflow-transcript-tail"
            )
        }
        .onChange(of: run.currentNodeID) { _, id in
            guard followLive, let id else { return }
            model.selectStep(id)
        }
        .onChange(of: followLive) { _, on in
            if on, let id = run.currentNodeID {
                model.selectStep(id)
            }
        }
    }

    private func labeled(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(Theme.caption)
                .foregroundStyle(.secondary)
                .frame(width: 72, alignment: .leading)
            Text(value)
                .font(Theme.callout)
                .textSelection(.enabled)
        }
    }

    private func budgetLabel(_ seconds: UInt64) -> String {
        if seconds == 0 { return L10n.text("apple.workflowsinspector.no_limit.f7fcff0d") }
        let minutes = max(1, seconds / 60)
        return L10n.text("apple.workflowsinspector.0_min.96d15cf8", "\(minutes)")
    }
}

/// Transcript that can stay pinned to the newest line.
private struct FollowTranscript: View {
    let text: String
    let empty: String
    let follow: Bool
    let tailID: String

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                TranscriptView(text: text, empty: empty)
                    .padding(Theme.Space.m)
                Color.clear
                    .frame(height: 1)
                    .id(tailID)
            }
            .background(Theme.background)
            .onChange(of: text) { _, _ in
                guard follow else { return }
                withAnimation(.easeOut(duration: 0.15)) {
                    proxy.scrollTo(tailID, anchor: .bottom)
                }
            }
            .onChange(of: follow) { _, on in
                guard on else { return }
                proxy.scrollTo(tailID, anchor: .bottom)
            }
            .onAppear {
                if follow {
                    proxy.scrollTo(tailID, anchor: .bottom)
                }
            }
        }
    }
}

/// Minutes on the working graph. 0 means no limit.
private struct WorkflowBudgetField: View {
    @Bindable var model: WorkflowsModel
    @State private var minutes = ""
    @State private var noLimit = false
    @State private var applying = false

    var body: some View {
        HStack(spacing: Theme.Space.xs) {
            Text(L10n.text("apple.workflowsinspector.time_limit.e592a9ca"))
                .font(Theme.caption)
                .foregroundStyle(.secondary)
            TextField("180", text: $minutes)
                .textFieldStyle(.themed)
                .frame(width: 56)
                .multilineTextAlignment(.trailing)
                .disabled(noLimit)
                .onSubmit { commit() }
            Text(L10n.text("apple.workflowsinspector.minutes.90e63d85"))
                .font(Theme.caption)
                .foregroundStyle(.secondary)
            BrandToggleChip(title: L10n.text("apple.workflowsinspector.no_limit.f7fcff0d"), isOn: $noLimit)
                .onChange(of: noLimit) { _, on in
                    guard !applying else { return }
                    if on {
                        model.setWorkingBudgetMinutes(0)
                    } else {
                        commit()
                    }
                }
        }
        .onAppear { load() }
        .onChange(of: model.working?.budgetSeconds) { _, _ in load() }
    }

    private func load() {
        applying = true
        let seconds = model.working?.budgetSeconds ?? 10_800
        noLimit = seconds == 0
        minutes = seconds == 0 ? "180" : String(max(1, seconds / 60))
        applying = false
    }

    private func commit() {
        if noLimit {
            model.setWorkingBudgetMinutes(0)
            return
        }
        let value = min(UInt64(minutes) ?? 180, UInt64.max / 60)
        model.setWorkingBudgetMinutes(value)
    }
}

/// Fields for the selected node. Pickers write immediately. Text is one undo.
private struct WorkflowNodeInspector: View {
    @Bindable var model: WorkflowsModel
    @AppStorage("workflows.followLive") private var followLive = true

    @State private var title = ""
    @State private var prompt = ""
    @State private var waitPattern = ""
    @State private var url = ""
    @State private var bodyText = ""
    @State private var headers = ""
    @State private var command = ""
    @State private var promptOverride = ""
    @State private var conditionPattern = ""
    @State private var loopTimes = ""
    @State private var loopUntil = ""
    @State private var loadedID: String?
    @State private var applying = false

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.m) {
                    if let node = model.selectedNode {
                        fields(node)
                    }
                }
                .padding(Theme.Space.m)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let node = model.selectedNode, let step = step(for: node) {
                ThemeRule()
                HStack {
                    StatusPill(status: step.status, text: step.endedLabel)
                    Spacer(minLength: 0)
                    BrandToggleChip(title: L10n.text("apple.workflowsinspector.follow.641d1ef6"), isOn: $followLive)
                        .help(L10n.text("apple.workflowsinspector.keep_the_newest_output_in_view_and_follow.bf0a2c03"))
                }
                .padding(.horizontal, Theme.Space.m)
                .padding(.vertical, Theme.Space.s)
            }
            if let node = model.selectedNode, showsTranscript(for: node) {
                ThemeRule()
                FollowTranscript(
                    text: model.transcriptText,
                    empty: stepIsLive(step(for: node)) ? "Waiting for output…" : "",
                    follow: followLive,
                    tailID: "workflow-node-transcript-tail"
                )
                .frame(minHeight: 140, maxHeight: 260)
                .clipped()
            }
            if model.selectedNode != nil {
                ThemeRule()
                HStack {
                    Button(L10n.text("apple.workflowsinspector.delete_node.b50c024f"), .delete, role: .destructive) {
                        model.deleteSelection()
                    }
                    .buttonStyle(SecondaryButtonStyle())
                    Spacer(minLength: 0)
                }
                .padding(Theme.Space.m)
            }
        }
        .onAppear {
            if let node = model.selectedNode { load(node) }
            followLiveStep()
        }
        .onChange(of: model.selectedNodeID) { _, _ in
            model.endGroupedEdit()
            if let node = model.selectedNode { load(node) }
        }
        .onChange(of: liveNodeID) { _, _ in
            followLiveStep()
        }
        .onChange(of: followLive) { _, on in
            if on { followLiveStep() }
        }
    }

    /// The node the live run is on, if this graph has one.
    private var liveNodeID: String? {
        guard let working = model.working, let run = model.lastRun(for: working), run.isLive else {
            return nil
        }
        return run.currentNodeID
    }

    private func followLiveStep() {
        guard followLive, let id = liveNodeID, id != model.selectedNodeID else { return }
        model.selectNode(id)
    }

    private func showsTranscript(for node: WorkflowNode) -> Bool {
        guard model.selectedStepID == node.id else { return false }
        if !model.transcriptText.isEmpty { return true }
        return stepIsLive(step(for: node))
    }

    private func stepIsLive(_ step: WorkflowStep?) -> Bool {
        guard let step else { return false }
        return step.status == "running" || step.status == "waiting"
    }

    @ViewBuilder
    private func fields(_ node: WorkflowNode) -> some View {
        Text(node.kind.label)
            .font(Theme.caption.weight(.semibold))
            .foregroundStyle(.tertiary)
        TextField(L10n.text("apple.workflowsinspector.title.7e8cd205"), text: $title)
            .textFieldStyle(.themed)
            .onChange(of: title) { _, next in
                guard !applying else { return }
                write(node.id) { $0.title = next }
            }

        switch node.kind {
        case .input:
            Text(L10n.text("apple.workflowsinspector.the_starting_prompt_fills_input_when_you_p.25eaf312"))
                .font(Theme.caption)
                .foregroundStyle(.secondary)
        case .agent:
            agentFields(node)
        case .automation:
            automationFields(node)
        case .http:
            httpFields(node)
        case .command:
            commandFields(node)
        case .gate:
            Text(L10n.text("apple.workflowsinspector.the_run_pauses_here_continue_or_stop_from.fb46b053"))
                .font(Theme.caption)
                .foregroundStyle(.secondary)
        case .condition:
            conditionFields(node)
        case .loop:
            loopFields(node)
        case .mcp:
            Text(L10n.text("apple.workflowsinspector.reserved_this_kind_cannot_be_saved_yet.3dc62a35"))
                .font(Theme.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func agentFields(_ node: WorkflowNode) -> some View {
        AppMenuPicker(
            title: L10n.text("apple.workflowsinspector.agent.11b39c93"),
            options: model.pickerBackends(keeping: node.backend).map { (value: $0.id, label: $0.label) },
            selection: Binding(
                get: { node.backend ?? "" },
                set: { next in
                    model.updateSelectedNode { item in
                        item.backend = next.isEmpty ? nil : next
                        if let backend = model.backends.first(where: { $0.id == next }) {
                            if let current = item.model, !backend.models.contains(current) {
                                item.model = nil
                            }
                            if let current = item.effort, !backend.efforts.contains(current) {
                                item.effort = nil
                            }
                        }
                    }
                }
            )
        )
        if let backend = model.backends.first(where: { $0.id == (node.backend ?? "") }) {
            if !backend.models.isEmpty {
                FavoriteModelPicker(
                    backendID: backend.id,
                    models: backend.models,
                    extra: node.model ?? "",
                    selection: Binding(
                        get: { node.model ?? "" },
                        set: { next in
                            model.updateSelectedNode { $0.model = next.isEmpty ? nil : next }
                        }
                    )
                )
            }
            if !backend.efforts.isEmpty {
                AppMenuPicker(
                    title: L10n.text("apple.workflowsinspector.effort.4387e5d3"),
                    options: [(value: "", label: L10n.text("apple.workflowsinspector.default.21b111cb"))]
                        + backend.efforts.map { (value: $0, label: $0) },
                    selection: Binding(
                        get: { node.effort ?? "" },
                        set: { next in
                            model.updateSelectedNode { $0.effort = next.isEmpty ? nil : next }
                        }
                    )
                )
            }
        }
        labeledField(L10n.text("apple.workflowsinspector.prompt.5c391238"), text: $prompt, axis: .vertical) { next in
            write(node.id) { $0.prompt = next }
        }
        AppMenuPicker(
            title: L10n.text("apple.workflowsinspector.wait.26b83994"),
            options: [
                (value: "exit", label: L10n.text("apple.workflowsinspector.until_the_process_exits.5c4be6c2")),
                (value: "output", label: L10n.text("apple.workflowsinspector.until_output_matches.6f886c69")),
            ],
            selection: Binding(
                get: { node.wait ?? "exit" },
                set: { next in
                    model.updateSelectedNode { $0.wait = next }
                }
            )
        )
        if node.wait == "output" {
            labeledField(L10n.text("apple.workflowsinspector.match.03c0e806"), text: $waitPattern) { next in
                write(node.id) { $0.waitPattern = next.isEmpty ? nil : next }
            }
        }
        Text(L10n.text("apple.workflowsinspector.input_is_the_starting_prompt_nodeid_output.98d8c50d"))
            .font(Theme.caption)
            .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private func conditionFields(_ node: WorkflowNode) -> some View {
        AppMenuPicker(
            title: L10n.text("apple.workflowsinspector.test.532eaabd"),
            options: [
                (value: "contains", label: L10n.text("apple.workflowsinspector.contains.2eaecb3d")),
                (value: "equals", label: L10n.text("apple.workflowsinspector.equals.f939ae3d")),
                (value: "matches", label: L10n.text("apple.workflowsinspector.matches.98abff28")),
            ],
            selection: Binding(
                get: { node.test ?? "contains" },
                set: { next in
                    model.updateSelectedNode { $0.test = next }
                }
            )
        )
        labeledField(L10n.text("apple.workflowsinspector.pattern.4288ade7"), text: $conditionPattern, axis: .vertical) { next in
            write(node.id) { $0.pattern = next }
        }
        Text(L10n.text("apple.workflowsinspector.then_is_on_success_else_is_on_error_the_te.3401ac56"))
            .font(Theme.caption)
            .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private func loopFields(_ node: WorkflowNode) -> some View {
        labeledField(L10n.text("apple.workflowsinspector.times.0c0fd31c"), text: $loopTimes) { next in
            write(node.id) { $0.times = UInt32(next) ?? 3 }
        }
        labeledField(L10n.text("apple.workflowsinspector.until.7caf856e"), text: $loopUntil) { next in
            write(node.id) { $0.until = next.isEmpty ? nil : next }
        }
        Text(L10n.text("apple.workflowsinspector.the_green_out_is_the_body_the_run_leaves_o.27202079"))
            .font(Theme.caption)
            .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private func automationFields(_ node: WorkflowNode) -> some View {
        AppMenuPicker(
            title: L10n.text("apple.workflowsinspector.automation.d909750b"),
            options: model.jobs.map { (value: $0.id, label: $0.name) },
            selection: Binding(
                get: { node.automationID ?? "" },
                set: { next in
                    model.updateSelectedNode { $0.automationID = next.isEmpty ? nil : next }
                }
            )
        )
        labeledField(L10n.text("apple.workflowsinspector.prompt_override.b992708e"), text: $promptOverride, axis: .vertical) { next in
            write(node.id) { $0.promptOverride = next.isEmpty ? nil : next }
        }
        Text(L10n.text("apple.workflowsinspector.a_timer_cannot_commit_this_step_runs_becau.0f4f14da"))
            .font(Theme.caption)
            .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private func httpFields(_ node: WorkflowNode) -> some View {
        AppMenuPicker(
            title: L10n.text("apple.workflowsinspector.method.52a0f9b6"),
            options: ["GET", "POST", "PUT", "PATCH", "DELETE", "HEAD"].map { (value: $0, label: $0) },
            selection: Binding(
                get: { node.method ?? "GET" },
                set: { next in
                    model.updateSelectedNode { $0.method = next }
                }
            )
        )
        labeledField(L10n.text("apple.workflowsinspector.url.e7a241de"), text: $url) { next in
            write(node.id) { $0.url = next }
        }
        labeledField(L10n.text("apple.workflowsinspector.headers.194e9fe6"), text: $headers, axis: .vertical) { next in
            write(node.id) { $0.headers = Self.parseHeaders(next) }
        }
        labeledField(L10n.text("apple.workflowsinspector.body.6ccaa641"), text: $bodyText, axis: .vertical) { next in
            write(node.id) { $0.body = next.isEmpty ? nil : next }
        }
        Text(L10n.text("apple.workflowsinspector.this_leaves_the_machine_only_because_you_p.902dc077"))
            .font(Theme.caption)
            .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private func commandFields(_ node: WorkflowNode) -> some View {
        labeledField(L10n.text("apple.workflowsinspector.command.71316697"), text: $command, axis: .vertical) { next in
            write(node.id) { $0.command = next }
        }
        Text(L10n.text("apple.workflowsinspector.runs_in_the_folder_as_you_a_timer_cannot_c.c658a7be"))
            .font(Theme.caption)
            .foregroundStyle(.secondary)
    }

    private func labeledField(
        _ title: String,
        text: Binding<String>,
        axis: Axis = .horizontal,
        onChange: @escaping (String) -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(Theme.caption)
                .foregroundStyle(.secondary)
            TextField(
                title,
                text: Binding(
                    get: { text.wrappedValue },
                    set: { next in
                        text.wrappedValue = next
                        onChange(next)
                    }
                ),
                axis: axis == .vertical ? .vertical : .horizontal
            )
            .textFieldStyle(axis == .vertical ? .themedMultiline : .themed)
            .lineLimit(axis == .vertical ? 3...10 : 1...1)
        }
    }

    private func step(for node: WorkflowNode) -> WorkflowStep? {
        if let step = model.selectedRun?.steps.first(where: { $0.nodeID == node.id }) {
            return step
        }
        if let working = model.working {
            return model.lastRun(for: working)?.steps.first(where: { $0.nodeID == node.id })
        }
        return nil
    }

    private func write(_ id: String, _ body: (inout WorkflowNode) -> Void) {
        guard !applying, loadedID == id else { return }
        model.beginGroupedEdit()
        model.writeWorking { graph in
            if let idx = graph.nodes.firstIndex(where: { $0.id == id }) {
                body(&graph.nodes[idx])
            }
        }
    }

    private func load(_ node: WorkflowNode) {
        applying = true
        loadedID = nil
        title = node.title
        prompt = node.prompt ?? ""
        waitPattern = node.waitPattern ?? ""
        url = node.url ?? ""
        bodyText = node.body ?? ""
        headers = Self.headersText(node.headers)
        command = node.command ?? ""
        promptOverride = node.promptOverride ?? ""
        conditionPattern = node.pattern ?? ""
        loopTimes = node.times.map { String($0) } ?? "3"
        loopUntil = node.until ?? ""
        loadedID = node.id
        Task { @MainActor in
            applying = false
        }
    }

    private static func headersText(_ headers: [String: String]?) -> String {
        guard let headers, !headers.isEmpty else { return "" }
        return headers.sorted(by: { $0.key < $1.key }).map { "\($0.key): \($0.value)" }.joined(separator: "\n")
    }

    private static func parseHeaders(_ text: String) -> [String: String]? {
        var out: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let raw = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !raw.isEmpty, let idx = raw.firstIndex(of: ":") else { continue }
            let key = String(raw[..<idx]).trimmingCharacters(in: .whitespacesAndNewlines)
            let value = String(raw[raw.index(after: idx)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !key.isEmpty { out[key] = value }
        }
        return out.isEmpty ? nil : out
    }
}
