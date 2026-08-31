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
        if model.isEditing, model.selectedNode != nil { return "Node" }
        if model.isEditing, model.selectedEdgeID != nil { return "Edge" }
        switch model.selectedFocus {
        case .run: return "Run"
        case .graph: return "Workflow"
        case .none: return "Workflows"
        }
    }

    private var edgeBody: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                if let id = model.selectedEdgeID,
                   let edge = model.working?.edges.first(where: { $0.id == id }) {
                    labeled("From", edge.from)
                    labeled("To", edge.to)
                    AppMenuPicker(
                        title: "When",
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
                    Text("Green is on success. Red is on error. Always runs either way. A loop leaves on always after the last pass.")
                        .font(Theme.caption)
                        .foregroundStyle(.secondary)
                    Button("Delete edge", .delete, role: .destructive) {
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
                    TextField("Name", text: Binding(
                        get: { model.working?.name ?? graph.name },
                        set: { next in
                            model.beginGroupedEdit()
                            model.writeWorking { $0.name = next }
                        }
                    ))
                    .textFieldStyle(.themed)
                    if graph.id.isEmpty {
                        Text("Unsaved draft. It will not run until you save and press Run.")
                            .font(Theme.caption)
                            .foregroundStyle(.secondary)
                    }
                    AppMenuPicker(
                        title: "Scope",
                        options: WorkflowScope.allCases.map { (value: $0, label: $0.label) },
                        selection: Binding(
                            get: { model.working?.scope ?? graph.scope },
                            set: { model.setWorkingScope($0, workspaceID: graph.workspaceID ?? folders.first?.id) }
                        )
                    )
                    if (model.working?.scope ?? graph.scope) == .workspace {
                        AppMenuPicker(
                            title: "Folder",
                            options: folders.map { (value: $0.id, label: $0.name) },
                            selection: Binding(
                                get: { model.working?.workspaceID ?? "" },
                                set: { model.setWorkingScope(.workspace, workspaceID: $0) }
                            )
                        )
                    }
                    WorkflowBudgetField(model: model)
                } else if graph.id.isEmpty {
                    TextField("Name", text: Binding(
                        get: { model.draft?.name ?? graph.name },
                        set: { model.draft?.name = $0 }
                    ))
                    .textFieldStyle(.themed)
                    Text("Unsaved draft. It will not run until you save and press Run.")
                        .font(Theme.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text(graph.name)
                        .font(Theme.font(15, weight: .semibold))
                    labeled("Scope", graph.scope.label)
                    if let folder = folders.first(where: { $0.id == graph.workspaceID }) {
                        labeled("Folder", folder.name)
                    }
                    labeled("Budget", budgetLabel(graph.budgetSeconds))
                }

                labeled("Nodes", "\(graph.nodes.count)")
                if let last = model.lastRun(for: graph) {
                    labeled("Last", last.startedAt.formatted(date: .abbreviated, time: .shortened))
                }

                if !model.designTranscript.isEmpty {
                    Text("Design transcript")
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
                        Button("Save", .save) { Task { await model.saveWorking() } }
                            .buttonStyle(AccentButtonStyle())
                        Button("Discard", .dismiss) { model.discardDraft() }
                            .buttonStyle(SecondaryButtonStyle())
                    } else if model.isEditing {
                        Button("Save", .save) { Task { await model.saveWorking() } }
                            .buttonStyle(AccentButtonStyle())
                            .disabled(!model.isDirty)
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
                        .font(Theme.font(15, weight: .semibold))
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
                        .font(Theme.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
                Text(run.startedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(Theme.caption)
                    .foregroundStyle(.tertiary)
                BrandToggleChip(title: "Follow", isOn: $followLive)
                    .help("Keep the transcript pinned to the newest line")
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
        if seconds == 0 { return "No limit" }
        let minutes = max(1, seconds / 60)
        return "\(minutes) min"
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
            Text("Time limit")
                .font(Theme.caption)
                .foregroundStyle(.secondary)
            TextField("180", text: $minutes)
                .textFieldStyle(.themed)
                .frame(width: 56)
                .multilineTextAlignment(.trailing)
                .disabled(noLimit)
                .onSubmit { commit() }
            Text("minutes")
                .font(Theme.caption)
                .foregroundStyle(.secondary)
            BrandToggleChip(title: "No limit", isOn: $noLimit)
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
        let value = UInt64(minutes) ?? 180
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
                    BrandToggleChip(title: "Follow", isOn: $followLive)
                        .help("Keep the newest output in view, and follow the live step")
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
                    Button("Delete node", .delete, role: .destructive) {
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
        TextField("Title", text: $title)
            .textFieldStyle(.themed)
            .onChange(of: title) { _, next in
                guard !applying else { return }
                write(node.id) { $0.title = next }
            }

        switch node.kind {
        case .input:
            Text("The starting prompt fills {{input}} when you press Run.")
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
            Text("The run pauses here. Continue or Stop from the canvas.")
                .font(Theme.caption)
                .foregroundStyle(.secondary)
        case .condition:
            conditionFields(node)
        case .loop:
            loopFields(node)
        case .mcp:
            Text("Reserved. This kind cannot be saved yet.")
                .font(Theme.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func agentFields(_ node: WorkflowNode) -> some View {
        AppMenuPicker(
            title: "Agent",
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
                    title: "Effort",
                    options: [(value: "", label: "Default")]
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
        labeledField("Prompt", text: $prompt, axis: .vertical) { next in
            write(node.id) { $0.prompt = next }
        }
        AppMenuPicker(
            title: "Wait",
            options: [
                (value: "exit", label: "Until the process exits"),
                (value: "output", label: "Until output matches"),
            ],
            selection: Binding(
                get: { node.wait ?? "exit" },
                set: { next in
                    model.updateSelectedNode { $0.wait = next }
                }
            )
        )
        if node.wait == "output" {
            labeledField("Match", text: $waitPattern) { next in
                write(node.id) { $0.waitPattern = next.isEmpty ? nil : next }
            }
        }
        Text("{{input}} is the starting prompt. {{nodeId.output}} is an earlier step.")
            .font(Theme.caption)
            .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private func conditionFields(_ node: WorkflowNode) -> some View {
        AppMenuPicker(
            title: "Test",
            options: [
                (value: "contains", label: "Contains"),
                (value: "equals", label: "Equals"),
                (value: "matches", label: "Matches"),
            ],
            selection: Binding(
                get: { node.test ?? "contains" },
                set: { next in
                    model.updateSelectedNode { $0.test = next }
                }
            )
        )
        labeledField("Pattern", text: $conditionPattern, axis: .vertical) { next in
            write(node.id) { $0.pattern = next }
        }
        Text("Then is on success. Else is on error. The test reads the previous step.")
            .font(Theme.caption)
            .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private func loopFields(_ node: WorkflowNode) -> some View {
        labeledField("Times", text: $loopTimes) { next in
            write(node.id) { $0.times = UInt32(next) ?? 3 }
        }
        labeledField("Until", text: $loopUntil) { next in
            write(node.id) { $0.until = next.isEmpty ? nil : next }
        }
        Text("The green out is the body. The run leaves on the always edge after the last pass, or when Until matches. At most 20 passes.")
            .font(Theme.caption)
            .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private func automationFields(_ node: WorkflowNode) -> some View {
        AppMenuPicker(
            title: "Automation",
            options: model.jobs.map { (value: $0.id, label: $0.name) },
            selection: Binding(
                get: { node.automationID ?? "" },
                set: { next in
                    model.updateSelectedNode { $0.automationID = next.isEmpty ? nil : next }
                }
            )
        )
        labeledField("Prompt override", text: $promptOverride, axis: .vertical) { next in
            write(node.id) { $0.promptOverride = next.isEmpty ? nil : next }
        }
        Text("A timer cannot commit. This step runs because you press Run.")
            .font(Theme.caption)
            .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private func httpFields(_ node: WorkflowNode) -> some View {
        AppMenuPicker(
            title: "Method",
            options: ["GET", "POST", "PUT", "PATCH", "DELETE", "HEAD"].map { (value: $0, label: $0) },
            selection: Binding(
                get: { node.method ?? "GET" },
                set: { next in
                    model.updateSelectedNode { $0.method = next }
                }
            )
        )
        labeledField("URL", text: $url) { next in
            write(node.id) { $0.url = next }
        }
        labeledField("Headers", text: $headers, axis: .vertical) { next in
            write(node.id) { $0.headers = Self.parseHeaders(next) }
        }
        labeledField("Body", text: $bodyText, axis: .vertical) { next in
            write(node.id) { $0.body = next.isEmpty ? nil : next }
        }
        Text("This leaves the machine only because you press Run. Authorization is a header you type.")
            .font(Theme.caption)
            .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private func commandFields(_ node: WorkflowNode) -> some View {
        labeledField("Command", text: $command, axis: .vertical) { next in
            write(node.id) { $0.command = next }
        }
        Text("Runs in the folder, as you. A timer cannot commit.")
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
