// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

import SwiftUI

/// Phone and compact iPad graph editor: a list of steps, not a flattened
/// sequence. Each row names its outgoing Then / Else / Body connections.
struct WorkflowStepListView: View {
    @Bindable var session: WorkflowEditorSession
    @Binding var path: [String]
    var selectsInPlace = false
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var adding = false

    /// Phone list and iPad inspector share these names. Input is Start.
    static func kindTitle(_ kind: WorkflowNodeKind) -> String {
        switch kind {
        case .input: return "Start"
        default: return kind.label
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            header
            if adding {
                kindPicker
            }
            if !adding || selectsInPlace {
                ForEach(ordered) { node in
                    stepRow(node)
                }
            }
            if let issue = session.additionIssue(kind: .gate) {
                Text(issue)
                    .font(Theme.caption)
                    .foregroundStyle(Theme.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !adding {
                Button("Add step", .create) { adding = true }
                    .buttonStyle(AccentButtonStyle(comfortable: true))
                    .disabled(!canAdd)
            }
        }
        .onChange(of: session.fields.nodes.map(\.id)) { _, ids in
            path.removeAll { !ids.contains($0) }
        }
        #if WORKBENCH_QA
        .onAppear {
            if ProcessInfo.processInfo.environment["WORKBENCH_ADDING"] == "1" {
                adding = true
            }
        }
        #endif
    }

    private var ordered: [WorkflowNode] {
        WorkflowLayering.layers(nodes: session.fields.nodes, edges: session.fields.edges).flatMap { $0 }
    }

    private var canAdd: Bool {
        session.additionIssue(kind: .gate) == nil && !session.creating && session.otherDraft == nil
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Steps")
                    .font(Theme.caption)
                    .foregroundStyle(Theme.controlGlyph)
                Text("\(session.fields.nodes.count) steps · \(session.fields.edges.count) connections")
                    .font(Theme.caption)
                    .foregroundStyle(Theme.controlGlyph)
            }
            Spacer(minLength: Theme.Space.s)
            Button("Undo", .restore) { session.undoGraph() }
                .buttonStyle(SecondaryButtonStyle(small: true))
                .disabled(!session.canUndoGraph || session.creating)
            Button("Redo", .next) { session.redoGraph() }
                .buttonStyle(SecondaryButtonStyle(small: true))
                .disabled(!session.canRedoGraph || session.creating)
            if selectsInPlace, !path.isEmpty {
                Button("Settings", .settings) {
                    session.endGroupedStepEdit()
                    session.selectStep(nil)
                    session.selectConnection(nil)
                    path = []
                }
                .buttonStyle(SecondaryButtonStyle(small: true))
            }
        }
    }

    private func stepRow(_ node: WorkflowNode) -> some View {
        let selected = path.last == node.id
        let outgoing = session.fields.edges.filter { $0.from == node.id }
        let incoming = session.fields.edges.filter { $0.to == node.id }
        let issue = rowIssue(node)
        return Button {
            session.selectStep(node.id)
            if selectsInPlace {
                path = [node.id]
            } else if path.last != node.id {
                path.append(node.id)
            }
        } label: {
            HStack(alignment: .top, spacing: Theme.Space.m) {
                mark(for: node)
                VStack(alignment: .leading, spacing: 4) {
                    Text(node.displayTitle)
                        .font(Theme.callout.weight(.semibold))
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.leading)
                    if Self.kindTitle(node.kind) != node.displayTitle {
                        Text(Self.kindTitle(node.kind))
                            .font(Theme.caption)
                            .foregroundStyle(Theme.controlGlyph)
                    }
                    connections(node: node, outgoing: outgoing, incoming: incoming)
                    if let issue {
                        Text(issue)
                            .font(Theme.caption)
                            .foregroundStyle(Theme.danger)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
                if !selectsInPlace {
                    Image(systemName: ActionIcon.next.symbol)
                        .font(Theme.font(12, weight: .semibold))
                        .foregroundStyle(Theme.controlGlyph)
                        .padding(.top, 4)
                        .accessibilityHidden(true)
                }
            }
            .padding(Theme.Space.m)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.panel, in: RoundedRectangle(cornerRadius: Theme.cardRadius))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.cardRadius)
                    .strokeBorder(selected ? Theme.accent : Theme.border, lineWidth: selected ? 1.5 : 1)
            )
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibility(node: node, outgoing: outgoing, incoming: incoming, issue: issue))
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier(node.id)
        .contextMenu {
            Button("Delete step", .delete, role: .destructive) {
                session.selectStep(node.id)
                session.removeSelectedStep()
            }
        }
    }

    @ViewBuilder
    private func connections(
        node: WorkflowNode,
        outgoing: [WorkflowEdge],
        incoming: [WorkflowEdge]
    ) -> some View {
        if outgoing.isEmpty {
            Text("No next step yet")
                .font(Theme.caption)
                .foregroundStyle(Theme.controlGlyph)
        } else {
            FlowLayout(spacing: 6, rowSpacing: 6) {
                ForEach(outgoing) { edge in
                    connectionChip(from: node, edge: edge)
                }
            }
        }
        if incoming.count > 1 {
            Text("Joins \(incoming.count) steps")
                .font(Theme.caption)
                .foregroundStyle(Theme.controlGlyph)
        }
    }

    private func connectionChip(from node: WorkflowNode, edge: WorkflowEdge) -> some View {
        let role = WorkflowGraphRules.outgoingRole(kind: node.kind, when: edge.when)
        let target = session.fields.nodes.first { $0.id == edge.to }?.displayTitle ?? edge.to
        return HStack(spacing: 4) {
            Text(role)
                .font(Theme.font(11, weight: .semibold))
                .foregroundStyle(Theme.accent)
            Text(target)
                .font(Theme.font(11, weight: .medium))
                .foregroundStyle(.primary)
                .lineLimit(1)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(Theme.accentSoft, in: Capsule())
    }

    private var kindPicker: some View {
        let columns = typeSize.isAccessibilitySize ? 1 : 2
        return VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack {
                Text("Add a step")
                    .font(Theme.caption)
                    .foregroundStyle(Theme.controlGlyph)
                Spacer(minLength: 0)
                Button("Cancel", .dismiss) { adding = false }
                    .buttonStyle(SecondaryButtonStyle(small: true))
            }
            LazyVGrid(
                columns: Array(
                    repeating: GridItem(.flexible(), spacing: Theme.Space.s),
                    count: columns
                ),
                spacing: Theme.Space.s
            ) {
                ForEach(kindChoices, id: \.kind) { choice in
                    kindTile(choice)
                }
            }
        }
    }

    private func kindTile(_ choice: KindChoice) -> some View {
        Button {
            add(choice)
        } label: {
            HStack(alignment: .center, spacing: Theme.Space.s) {
                FeatureMark(name: choice.kind.mark, tint: Theme.accent, size: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text(choice.title)
                        .font(Theme.font(13, weight: .medium))
                        .foregroundStyle(.primary)
                    Text(choice.subtitle)
                        .font(Theme.caption)
                        .foregroundStyle(Theme.controlGlyph)
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
            }
            .padding(Theme.Space.s)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .background(Theme.panel, in: RoundedRectangle(cornerRadius: Theme.Space.s))
            .overlay(RoundedRectangle(cornerRadius: Theme.Space.s).strokeBorder(Theme.border))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(choice.title). \(choice.subtitle)")
    }

    private func add(_ choice: KindChoice) {
        if session.selectedStepID == nil, let last = ordered.last {
            session.selectStep(last.id)
        }
        var backend: String?
        var automationID: String?
        if choice.kind == .agent {
            backend = session.backends.defaultForPicker()?.id
        }
        if choice.kind == .automation {
            automationID = session.jobs.first?.id
        }
        session.addStep(kind: choice.kind, backend: backend, automationID: automationID)
        adding = false
        guard let id = session.selectedStepID else { return }
        if selectsInPlace {
            path = [id]
        } else if path.last != id {
            path.append(id)
        }
    }

    private func mark(for node: WorkflowNode) -> some View {
        Group {
            if node.kind == .agent, let backend = node.backend, !backend.isEmpty {
                HarnessMark(id: backend, size: 22)
            } else {
                FeatureMark(name: node.kind.mark, tint: Theme.accent, size: 22)
            }
        }
        .frame(width: 28, height: 28)
    }

    private func rowIssue(_ node: WorkflowNode) -> String? {
        if let issue = WorkflowGraphRules.nodeIssue(node) { return issue }
        if node.kind == .loop,
           !session.fields.edges.contains(where: { $0.from == node.id && $0.when == .ok }) {
            return "Loop \(node.displayTitle) needs a body connection."
        }
        return nil
    }

    private func accessibility(
        node: WorkflowNode,
        outgoing: [WorkflowEdge],
        incoming: [WorkflowEdge],
        issue: String?
    ) -> String {
        var parts = [Self.kindTitle(node.kind), node.displayTitle]
        for edge in outgoing {
            let role = WorkflowGraphRules.outgoingRole(kind: node.kind, when: edge.when)
            let target = session.fields.nodes.first { $0.id == edge.to }?.displayTitle ?? edge.to
            parts.append("\(role) \(target)")
        }
        if incoming.count > 1 {
            parts.append("joins \(incoming.count) steps")
        }
        if let issue { parts.append(issue) }
        return parts.joined(separator: ". ")
    }

    private var kindChoices: [KindChoice] {
        [
            KindChoice(kind: .input, title: "Start", subtitle: "Starting prompt"),
            KindChoice(kind: .agent, title: "Agent", subtitle: "Model and prompt"),
            KindChoice(kind: .automation, title: "Automation", subtitle: "Run a saved job"),
            KindChoice(kind: .http, title: "HTTP", subtitle: "Host-owned request"),
            KindChoice(kind: .command, title: "Command", subtitle: "Shell in the folder"),
            KindChoice(kind: .gate, title: "Gate", subtitle: "Wait for you"),
            KindChoice(kind: .condition, title: "If", subtitle: "Then or else"),
            KindChoice(kind: .loop, title: "Loop", subtitle: "Repeat a body"),
        ]
    }

    private struct KindChoice {
        var kind: WorkflowNodeKind
        var title: String
        var subtitle: String
    }
}
