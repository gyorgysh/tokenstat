// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

#if !os(macOS)
import SwiftUI

/// A workflow as named columns. Read-only. The Mac canvas stays on the Mac.
///
/// Layers come from `WorkflowLayering`, the same rule `MiniGraph` uses, so a
/// library row and this board cannot disagree about the order of the run.
struct ClientWorkflowBoard: View {
    let graph: WorkflowGraph
    var run: WorkflowRunRecord?
    var selectedNodeID: String?
    var onSelect: (String) -> Void

    private var columns: [[WorkflowNode]] {
        WorkflowLayering.layers(nodes: graph.nodes, edges: graph.edges)
    }

    var body: some View {
        ScrollView([.horizontal, .vertical]) {
            HStack(alignment: .top, spacing: Theme.Space.m) {
                ForEach(Array(columns.enumerated()), id: \.offset) { index, column in
                    if index > 0 {
                        Image(systemName: "arrow.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                            .padding(.top, 22)
                    }
                    VStack(spacing: Theme.Space.s) {
                        ForEach(column) { node in
                            ClientWorkflowBoardCard(
                                node: node,
                                step: run?.steps.first { $0.nodeID == node.id },
                                isCurrent: run?.currentNodeID == node.id,
                                isSelected: selectedNodeID == node.id
                            )
                            .onTapGesture { onSelect(node.id) }
                        }
                    }
                }
            }
            .padding(Theme.Space.m)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(WorkflowLayering.sentence(nodes: graph.nodes, edges: graph.edges))
        }
    }
}

/// One step on the board. Mark, title, subtitle, and the live tint if a run
/// is sitting on it.
private struct ClientWorkflowBoardCard: View {
    let node: WorkflowNode
    var step: WorkflowStep?
    var isCurrent: Bool
    var isSelected: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dimmed = false

    var body: some View {
        HStack(spacing: Theme.Space.s) {
            mark
            VStack(alignment: .leading, spacing: 2) {
                Text(node.displayTitle)
                    .font(ClientType.label.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                Text(node.subtitle)
                    .font(ClientType.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
            if let step {
                StatusPill(status: step.status, text: step.endedLabel)
            }
        }
        .padding(Theme.Space.m)
        .frame(minWidth: 180, minHeight: 44, alignment: .leading)
        .background(
            isSelected ? Theme.rowSelected : Theme.panel,
            in: RoundedRectangle(cornerRadius: Theme.cardRadius)
        )
        .overlay {
            RoundedRectangle(cornerRadius: Theme.cardRadius)
                .strokeBorder(border, lineWidth: isCurrent || isSelected ? 1.5 : 1)
        }
        .opacity(dimmed ? 0.55 : 1)
        .animation(
            dimmed
                ? .easeInOut(duration: 1.1).repeatForever(autoreverses: true)
                : .easeInOut(duration: 0.2),
            value: dimmed
        )
        .onAppear { dimmed = shouldPulse }
        .onChange(of: isCurrent) { _, _ in dimmed = shouldPulse }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(node.kind.label). \(node.displayTitle). \(node.subtitle)")
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    @ViewBuilder
    private var mark: some View {
        if node.kind == .agent, let backend = node.backend, !backend.isEmpty {
            HarnessMark(id: backend, size: 22)
        } else {
            FeatureMark(name: node.kind.mark, tint: tint, size: 22)
        }
    }

    private var tint: Color {
        if let step { return RunOutcome.tint(step.status) }
        return isCurrent ? Theme.stateWorking : Theme.accent
    }

    private var border: Color {
        if isCurrent { return Theme.stateWorking }
        if isSelected { return Theme.accent.opacity(0.55) }
        return Theme.border
    }

    private var shouldPulse: Bool {
        isCurrent && !reduceMotion
    }
}

#endif
