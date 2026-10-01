// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

import SwiftUI

/// Fields and explicit connections for one step. Then, Else and loop Body
/// stay separate picks, not a single next-step control.
struct WorkflowStepDetailView: View {
    @Bindable var session: WorkflowEditorSession
    let nodeID: String
    @Binding var path: [String]
    var showsBack = true

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
    @State private var addTarget = ""
    @State private var addWhen: WorkflowEdgeWhen = .ok
    @State private var loadedID: String?
    @State private var applying = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            if showsBack {
                Button(L10n.text("apple.workflowstepdetailview.steps.1de3df70"), .back) {
                    pop()
                }
                .buttonStyle(SecondaryButtonStyle(comfortable: true))
            }
            if let node {
                fields(node)
                ThemeRule()
                connections(node)
                if let issue = WorkflowGraphRules.nodeIssue(node) {
                    Text(issue)
                        .font(Theme.caption)
                        .foregroundStyle(Theme.danger)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Button(L10n.text("apple.workflowstepdetailview.delete_step.0e31c081"), .delete, role: .destructive) {
                    session.selectStep(node.id)
                    session.removeSelectedStep()
                    pop()
                }
                .buttonStyle(SecondaryButtonStyle(comfortable: true))
                .disabled(session.creating || session.otherDraft != nil)
            } else {
                Text(L10n.text("apple.workflowstepdetailview.this_step_is_no_longer_in_the_graph.f4c519a4"))
                    .font(Theme.callout)
                    .foregroundStyle(Theme.controlGlyph)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear {
            session.selectStep(nodeID)
            if let node { load(node) }
        }
        .onChange(of: nodeID) { _, id in
            session.endGroupedStepEdit()
            session.selectStep(id)
            addTarget = ""
            if let node { load(node) }
        }
        .onDisappear { session.endGroupedStepEdit() }
    }

    private var node: WorkflowNode? {
        session.fields.nodes.first { $0.id == nodeID }
    }

    @ViewBuilder
    private func fields(_ node: WorkflowNode) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            Text(WorkflowStepListView.kindTitle(node.kind))
                .font(Theme.caption.weight(.semibold))
                .foregroundStyle(Theme.controlGlyph)
            labeledField(L10n.text("apple.workflowstepdetailview.title.7e8cd205"), text: $title) { next in
                write(node.id) { $0.title = next }
            }
            switch node.kind {
            case .input, .gate:
                EmptyView()
            case .agent:
                agentFields(node)
            case .automation:
                automationFields(node)
            case .http:
                httpFields(node)
            case .command:
                commandFields(node)
            case .condition:
                conditionFields(node)
            case .loop:
                loopFields(node)
            case .mcp:
                caption(L10n.text("apple.workflowstepdetailview.reserved_this_kind_cannot_be_saved_yet.3dc62a35"))
            }
        }
    }

    @ViewBuilder
    private func agentFields(_ node: WorkflowNode) -> some View {
        let backends = session.backends.visibleForPicker(keeping: node.backend)
        AppMenuPicker(
            title: L10n.text("apple.workflowstepdetailview.agent.11b39c93"),
            options: backends.isEmpty
                ? [(value: node.backend ?? "", label: L10n.text("apple.workflowstepdetailview.choose_an_agent.b6890bc2"))]
                : backends.map { (value: $0.id, label: $0.label) },
            selection: Binding(
                get: { node.backend ?? "" },
                set: { next in
                    session.updateSelectedStep { item in
                        item.backend = next.isEmpty ? nil : next
                        if let backend = session.backends.first(where: { $0.id == next }) {
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
        if let backend = session.backends.first(where: { $0.id == (node.backend ?? "") }) {
            if !backend.models.isEmpty {
                FavoriteModelPicker(
                    backendID: backend.id,
                    models: backend.models,
                    extra: node.model ?? "",
                    preservesSavedSelection: true,
                    selection: Binding(
                        get: { node.model ?? "" },
                        set: { next in
                            session.updateSelectedStep { $0.model = next.isEmpty ? nil : next }
                        }
                    )
                )
            }
            if !backend.efforts.isEmpty {
                AppMenuPicker(
                    title: L10n.text("apple.workflowstepdetailview.effort.4387e5d3"),
                    options: [(value: "", label: L10n.text("apple.workflowstepdetailview.default.21b111cb"))]
                        + backend.efforts.map { (value: $0, label: $0) },
                    selection: Binding(
                        get: { node.effort ?? "" },
                        set: { next in
                            session.updateSelectedStep { $0.effort = next.isEmpty ? nil : next }
                        }
                    )
                )
            }
        }
        labeledField(L10n.text("apple.workflowstepdetailview.prompt.5c391238"), text: $prompt, axis: .vertical) { next in
            write(node.id) { $0.prompt = next }
        }
        AppMenuPicker(
            title: L10n.text("apple.workflowstepdetailview.wait.26b83994"),
            options: [
                (value: "exit", label: L10n.text("apple.workflowstepdetailview.until_the_process_exits.5c4be6c2")),
                (value: "output", label: L10n.text("apple.workflowstepdetailview.until_output_matches.6f886c69")),
            ],
            selection: Binding(
                get: { node.wait ?? "exit" },
                set: { next in
                    session.updateSelectedStep { $0.wait = next }
                }
            )
        )
        if node.wait == "output" {
            labeledField(L10n.text("apple.workflowstepdetailview.match.03c0e806"), text: $waitPattern) { next in
                write(node.id) { $0.waitPattern = next.isEmpty ? nil : next }
            }
        }
        caption(L10n.text("apple.workflowstepdetailview.input_is_the_starting_prompt_nodeid_output.98d8c50d"))
    }

    @ViewBuilder
    private func automationFields(_ node: WorkflowNode) -> some View {
        AppMenuPicker(
            title: L10n.text("apple.workflowstepdetailview.automation.d909750b"),
            options: session.jobs.isEmpty
                ? [(value: node.automationID ?? "", label: L10n.text("apple.workflowstepdetailview.choose_an_automation.758af24e"))]
                : session.jobs.map { (value: $0.id, label: $0.name) },
            selection: Binding(
                get: { node.automationID ?? "" },
                set: { next in
                    session.updateSelectedStep { $0.automationID = next.isEmpty ? nil : next }
                }
            )
        )
        labeledField(L10n.text("apple.workflowstepdetailview.prompt_override.b992708e"), text: $promptOverride, axis: .vertical) { next in
            write(node.id) { $0.promptOverride = next.isEmpty ? nil : next }
        }
        caption(L10n.text("apple.workflowstepdetailview.a_timer_cannot_commit_this_step_runs_becau.0f4f14da"))
    }

    @ViewBuilder
    private func httpFields(_ node: WorkflowNode) -> some View {
        AppMenuPicker(
            title: L10n.text("apple.workflowstepdetailview.method.52a0f9b6"),
            options: ["GET", "POST", "PUT", "PATCH", "DELETE", "HEAD"].map { (value: $0, label: $0) },
            selection: Binding(
                get: { node.method ?? "GET" },
                set: { next in
                    session.updateSelectedStep { $0.method = next }
                }
            )
        )
        labeledField(L10n.text("apple.workflowstepdetailview.url.e7a241de"), text: $url) { next in
            write(node.id) { $0.url = next }
        }
        labeledField(L10n.text("apple.workflowstepdetailview.headers.194e9fe6"), text: $headers, axis: .vertical) { next in
            write(node.id) { $0.headers = Self.parseHeaders(next) }
        }
        labeledField(L10n.text("apple.workflowstepdetailview.body.6ccaa641"), text: $bodyText, axis: .vertical) { next in
            write(node.id) { $0.body = next.isEmpty ? nil : next }
        }
        caption(L10n.text("apple.workflowstepdetailview.this_leaves_the_machine_only_because_you_p.902dc077"))
    }

    @ViewBuilder
    private func commandFields(_ node: WorkflowNode) -> some View {
        labeledField(L10n.text("apple.workflowstepdetailview.command.71316697"), text: $command, axis: .vertical) { next in
            write(node.id) { $0.command = next }
        }
        caption(L10n.text("apple.workflowstepdetailview.runs_in_the_folder_as_you_a_timer_cannot_c.c658a7be"))
    }

    @ViewBuilder
    private func conditionFields(_ node: WorkflowNode) -> some View {
        AppMenuPicker(
            title: L10n.text("apple.workflowstepdetailview.test.532eaabd"),
            options: [
                (value: "contains", label: L10n.text("apple.workflowstepdetailview.contains.2eaecb3d")),
                (value: "equals", label: L10n.text("apple.workflowstepdetailview.equals.f939ae3d")),
                (value: "matches", label: L10n.text("apple.workflowstepdetailview.matches.98abff28")),
            ],
            selection: Binding(
                get: { node.test ?? "contains" },
                set: { next in
                    session.updateSelectedStep { $0.test = next }
                }
            )
        )
        labeledField(L10n.text("apple.workflowstepdetailview.pattern.4288ade7"), text: $conditionPattern, axis: .vertical, lines: 1...4) { next in
            write(node.id) { $0.pattern = next }
        }
    }

    @ViewBuilder
    private func loopFields(_ node: WorkflowNode) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(L10n.text("apple.workflowstepdetailview.times.0c0fd31c"))
                .font(Theme.caption)
                .foregroundStyle(Theme.controlGlyph)
            FlowLayout(spacing: 6, rowSpacing: 6) {
                ForEach([2, 3, 5, 10], id: \.self) { value in
                    ChoiceChip(title: String(value), isSelected: (UInt32(loopTimes) ?? 0) == UInt32(value)) {
                        loopTimes = String(value)
                        session.selectStep(node.id)
                        session.updateSelectedStep { $0.times = UInt32(value) }
                    }
                }
            }
            TextField(L10n.text("apple.workflowstepdetailview.times.0c0fd31c"), text: $loopTimes)
                .textFieldStyle(.themed)
                #if os(iOS)
                .keyboardType(.numberPad)
                #endif
                .onChange(of: loopTimes) { _, next in
                    guard !applying else { return }
                    write(node.id) { $0.times = UInt32(next) ?? 3 }
                }
        }
        labeledField(L10n.text("apple.workflowstepdetailview.until.7caf856e"), text: $loopUntil) { next in
            write(node.id) { $0.until = next.isEmpty ? nil : next }
        }
    }

    @ViewBuilder
    private func connections(_ node: WorkflowNode) -> some View {
        let outgoing = session.fields.edges.filter { $0.from == node.id }
        let incoming = session.fields.edges.filter { $0.to == node.id }
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Text(L10n.text("apple.workflowstepdetailview.connections.dc273117"))
                .font(Theme.callout.weight(.semibold))
            caption(WorkflowGraphRules.connectionCaption(kind: node.kind))
            if outgoing.isEmpty {
                Text(L10n.text("apple.workflowstepdetailview.no_next_step_yet.2cc05797"))
                    .font(Theme.callout)
                    .foregroundStyle(Theme.controlGlyph)
            }
            ForEach(outgoing) { edge in
                outgoingRow(node: node, edge: edge)
            }
            addConnection(node: node, outgoing: outgoing)
            Text(L10n.text("apple.workflowstepdetailview.arrives_from.7356ce95"))
                .font(Theme.caption)
                .foregroundStyle(Theme.controlGlyph)
            if incoming.isEmpty {
                Text(node.kind == .input ? L10n.text("apple.workflowstepdetailview.run_fills_this_step.6c0bab88") : L10n.text("apple.workflowstepdetailview.nothing_connects_here_yet.f2c1b3f9"))
                    .font(Theme.callout)
                    .foregroundStyle(Theme.controlGlyph)
            }
            ForEach(incoming) { edge in
                incomingRow(edge)
            }
        }
    }

    private func outgoingRow(node: WorkflowNode, edge: WorkflowEdge) -> some View {
        let targets = targetOptions(from: node.id, keeping: edge.to)
        return VStack(alignment: .leading, spacing: Theme.Space.s) {
            AppMenuPicker(
                title: WorkflowGraphRules.outgoingRole(kind: node.kind, when: edge.when),
                options: targets,
                selection: Binding(
                    get: { edge.to },
                    set: { next in
                        session.replaceConnection(id: edge.id, to: next, when: edge.when)
                    }
                )
            )
            HStack(alignment: .center, spacing: Theme.Space.s) {
                FlowLayout(spacing: 6, rowSpacing: 6) {
                    ForEach(WorkflowGraphRules.whenOptions(kind: node.kind), id: \.value) { option in
                        ChoiceChip(
                            title: option.label,
                            isSelected: edge.when == option.value
                        ) {
                            session.replaceConnection(id: edge.id, to: edge.to, when: option.value)
                        }
                    }
                }
                Spacer(minLength: 0)
                Button(L10n.text("common.remove"), .delete, role: .destructive) {
                    session.removeConnection(id: edge.id)
                }
                .buttonStyle(SecondaryButtonStyle(small: true))
                .environment(\.compactActions, true)
            }
        }
        .padding(Theme.Space.s)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: Theme.cardRadius))
        .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius).strokeBorder(Theme.border))
    }

    private func incomingRow(_ edge: WorkflowEdge) -> some View {
        let source = session.fields.nodes.first { $0.id == edge.from }
        let role = WorkflowGraphRules.outgoingRole(kind: source?.kind ?? .agent, when: edge.when)
        return HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
            VStack(alignment: .leading, spacing: 2) {
                Text(source?.displayTitle ?? edge.from)
                    .font(Theme.callout)
                Text(role)
                    .font(Theme.caption)
                    .foregroundStyle(Theme.controlGlyph)
            }
            Spacer(minLength: 0)
            Button(L10n.text("common.remove"), .delete, role: .destructive) {
                session.removeConnection(id: edge.id)
            }
            .buttonStyle(SecondaryButtonStyle(small: true))
        }
        .padding(Theme.Space.s)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: Theme.cardRadius))
        .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius).strokeBorder(Theme.border))
    }

    @ViewBuilder
    private func addConnection(node: WorkflowNode, outgoing: [WorkflowEdge]) -> some View {
        let connected = Set(outgoing.map(\.to))
        let targets = session.fields.nodes
            .filter { $0.id != node.id && !connected.contains($0.id) }
            .map { (value: $0.id, label: $0.displayTitle) }
        if session.fields.edges.count >= WorkflowGraphRules.maxEdges {
            Text(L10n.text("apple.workflowstepdetailview.a_workflow_may_have_at_most_0_connections.32d67dc9", "\(WorkflowGraphRules.maxEdges)"))
                .font(Theme.caption)
                .foregroundStyle(Theme.controlGlyph)
        } else if targets.isEmpty {
            Text(L10n.text("apple.workflowstepdetailview.every_other_step_already_connects_from_her.274fc9dd"))
                .font(Theme.caption)
                .foregroundStyle(Theme.controlGlyph)
        } else {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                AppMenuPicker(
                    title: L10n.text("apple.workflowstepdetailview.add_connection.685f88ae"),
                    options: [(value: "", label: L10n.text("apple.workflowstepdetailview.choose_a_step.f1fb3b3c"))] + targets,
                    selection: $addTarget
                )
                FlowLayout(spacing: 6, rowSpacing: 6) {
                    ForEach(WorkflowGraphRules.whenOptions(kind: node.kind), id: \.value) { option in
                        ChoiceChip(title: option.label, isSelected: addWhen == option.value) {
                            addWhen = option.value
                        }
                    }
                }
                Button(L10n.text("common.connect"), .create) {
                    session.connectSteps(from: node.id, to: addTarget, when: addWhen)
                    addTarget = ""
                    addWhen = WorkflowGraphRules.suggestedWhen(kind: node.kind, outgoing: session.fields.edges.filter { $0.from == node.id })
                }
                .buttonStyle(AccentButtonStyle(comfortable: true))
                .disabled(addTarget.isEmpty || session.creating)
            }
            .onAppear {
                addWhen = WorkflowGraphRules.suggestedWhen(kind: node.kind, outgoing: outgoing)
            }
        }
    }

    private func targetOptions(from id: String, keeping current: String) -> [(value: String, label: String)] {
        let connected = Set(session.fields.edges.filter { $0.from == id && $0.to != current }.map(\.to))
        return session.fields.nodes
            .filter { $0.id != id && ($0.id == current || !connected.contains($0.id)) }
            .map { (value: $0.id, label: $0.displayTitle) }
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(Theme.caption)
            .foregroundStyle(Theme.controlGlyph)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func labeledField(
        _ title: String,
        text: Binding<String>,
        axis: Axis = .horizontal,
        lines: ClosedRange<Int>? = nil,
        onChange: @escaping (String) -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(Theme.caption)
                .foregroundStyle(Theme.controlGlyph)
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
            .lineLimit(lines ?? (axis == .vertical ? 3...10 : 1...1))
        }
    }

    private func pop() {
        session.endGroupedStepEdit()
        if showsBack {
            if !path.isEmpty { path.removeLast() }
        } else {
            path = []
        }
    }

    private func write(_ id: String, _ body: (inout WorkflowNode) -> Void) {
        guard !applying, loadedID == id else { return }
        session.selectStep(id)
        session.beginGroupedStepEdit()
        session.writeSelectedStep(body)
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
