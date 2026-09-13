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
                Button("Steps", .back) {
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
                Button("Delete step", .delete, role: .destructive) {
                    session.selectStep(node.id)
                    session.removeSelectedStep()
                    pop()
                }
                .buttonStyle(SecondaryButtonStyle(comfortable: true))
                .disabled(session.creating || session.otherDraft != nil)
            } else {
                Text("This step is no longer in the graph.")
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
            labeledField("Title", text: $title) { next in
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
                caption("Reserved. This kind cannot be saved yet.")
            }
        }
    }

    @ViewBuilder
    private func agentFields(_ node: WorkflowNode) -> some View {
        let backends = session.backends.visibleForPicker(keeping: node.backend)
        AppMenuPicker(
            title: "Agent",
            options: backends.isEmpty
                ? [(value: node.backend ?? "", label: "Choose an agent")]
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
                    title: "Effort",
                    options: [(value: "", label: "Default")]
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
                    session.updateSelectedStep { $0.wait = next }
                }
            )
        )
        if node.wait == "output" {
            labeledField("Match", text: $waitPattern) { next in
                write(node.id) { $0.waitPattern = next.isEmpty ? nil : next }
            }
        }
        caption("{{input}} is the starting prompt. {{nodeId.output}} is an earlier step.")
    }

    @ViewBuilder
    private func automationFields(_ node: WorkflowNode) -> some View {
        AppMenuPicker(
            title: "Automation",
            options: session.jobs.isEmpty
                ? [(value: node.automationID ?? "", label: "Choose an automation")]
                : session.jobs.map { (value: $0.id, label: $0.name) },
            selection: Binding(
                get: { node.automationID ?? "" },
                set: { next in
                    session.updateSelectedStep { $0.automationID = next.isEmpty ? nil : next }
                }
            )
        )
        labeledField("Prompt override", text: $promptOverride, axis: .vertical) { next in
            write(node.id) { $0.promptOverride = next.isEmpty ? nil : next }
        }
        caption("A timer cannot commit. This step runs because you press Run.")
    }

    @ViewBuilder
    private func httpFields(_ node: WorkflowNode) -> some View {
        AppMenuPicker(
            title: "Method",
            options: ["GET", "POST", "PUT", "PATCH", "DELETE", "HEAD"].map { (value: $0, label: $0) },
            selection: Binding(
                get: { node.method ?? "GET" },
                set: { next in
                    session.updateSelectedStep { $0.method = next }
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
        caption("This leaves the machine only because you press Run. Authorization is a header you type.")
    }

    @ViewBuilder
    private func commandFields(_ node: WorkflowNode) -> some View {
        labeledField("Command", text: $command, axis: .vertical) { next in
            write(node.id) { $0.command = next }
        }
        caption("Runs in the folder, as you. A timer cannot commit.")
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
                    session.updateSelectedStep { $0.test = next }
                }
            )
        )
        labeledField("Pattern", text: $conditionPattern, axis: .vertical, lines: 1...4) { next in
            write(node.id) { $0.pattern = next }
        }
    }

    @ViewBuilder
    private func loopFields(_ node: WorkflowNode) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Times")
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
            TextField("Times", text: $loopTimes)
                .textFieldStyle(.themed)
                #if os(iOS)
                .keyboardType(.numberPad)
                #endif
                .onChange(of: loopTimes) { _, next in
                    guard !applying else { return }
                    write(node.id) { $0.times = UInt32(next) ?? 3 }
                }
        }
        labeledField("Until", text: $loopUntil) { next in
            write(node.id) { $0.until = next.isEmpty ? nil : next }
        }
    }

    @ViewBuilder
    private func connections(_ node: WorkflowNode) -> some View {
        let outgoing = session.fields.edges.filter { $0.from == node.id }
        let incoming = session.fields.edges.filter { $0.to == node.id }
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Text("Connections")
                .font(Theme.callout.weight(.semibold))
            caption(WorkflowGraphRules.connectionCaption(kind: node.kind))
            if outgoing.isEmpty {
                Text("No next step yet.")
                    .font(Theme.callout)
                    .foregroundStyle(Theme.controlGlyph)
            }
            ForEach(outgoing) { edge in
                outgoingRow(node: node, edge: edge)
            }
            addConnection(node: node, outgoing: outgoing)
            Text("Arrives from")
                .font(Theme.caption)
                .foregroundStyle(Theme.controlGlyph)
            if incoming.isEmpty {
                Text(node.kind == .input ? "Run fills this step." : "Nothing connects here yet.")
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
                Button("Remove", .delete, role: .destructive) {
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
            Button("Remove", .delete, role: .destructive) {
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
            Text("A workflow may have at most \(WorkflowGraphRules.maxEdges) connections.")
                .font(Theme.caption)
                .foregroundStyle(Theme.controlGlyph)
        } else if targets.isEmpty {
            Text("Every other step already connects from here.")
                .font(Theme.caption)
                .foregroundStyle(Theme.controlGlyph)
        } else {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                AppMenuPicker(
                    title: "Add connection",
                    options: [(value: "", label: "Choose a step")] + targets,
                    selection: $addTarget
                )
                FlowLayout(spacing: 6, rowSpacing: 6) {
                    ForEach(WorkflowGraphRules.whenOptions(kind: node.kind), id: \.value) { option in
                        ChoiceChip(title: option.label, isSelected: addWhen == option.value) {
                            addWhen = option.value
                        }
                    }
                }
                Button("Connect", .create) {
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
