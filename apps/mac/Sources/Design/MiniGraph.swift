// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available: source sharing and own builds are permitted.
// Store and commercial distribution of builds is reserved. See LICENSE.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

import SwiftUI


struct WorkflowStepStrip: View {
    var nodes: [WorkflowNode]
    var edges: [WorkflowEdge] = []
    var mark: CGFloat = 18

    private var steps: [WorkflowNode] {
        WorkflowLayering.layers(nodes: nodes, edges: edges).flatMap { $0 }
    }

    var body: some View {
        FlowLayout(spacing: 6, rowSpacing: 6) {
            ForEach(Array(steps.enumerated()), id: \.element.id) { index, node in
                HStack(spacing: 5) {
                    if index > 0 {
                        Image(systemName: "arrow.right")
                            .font(Theme.font(9, weight: .semibold))
                            .foregroundStyle(.tertiary)
                    }
                    HStack(spacing: 5) {
                        if node.kind == .agent, let backend = node.backend, !backend.isEmpty {
                            HarnessMark(id: backend, size: mark)
                        } else {
                            FeatureMark(name: node.kind.mark, tint: Theme.accent, size: mark)
                        }
                        Text(node.displayTitle)
                            .font(Theme.font(11, weight: .medium))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(Theme.accentSoft, in: Capsule())
                }
                .help(node.subtitle)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(WorkflowLayering.sentence(nodes: nodes, edges: edges))
    }
}

struct MiniGraph: View {
    var nodes: [WorkflowNode]
    var edges: [WorkflowEdge] = []
    var steps: [WorkflowStep] = []
    var currentNodeID: String?
    var maxColumns: Int = 5
    var dot: CGFloat = 22

    private var columns: [[WorkflowNode]] {
        WorkflowLayering.layers(nodes: nodes, edges: edges)
    }

    var body: some View {
        let all = columns
        let cap = max(0, maxColumns)
        let shown = Array(all.prefix(max(0, all.count > cap ? cap - 1 : cap)))
        let hidden = all.dropFirst(shown.count).reduce(0) { $0 + $1.count }

        HStack(spacing: 0) {
            ForEach(Array(shown.enumerated()), id: \.offset) { index, column in
                if index > 0 { connector }
                VStack(spacing: 3) {
                    ForEach(column) { node in
                        mark(for: node)
                    }
                }
            }
            if hidden > 0 {
                connector
                overflow(hidden)
            }
        }
        .frame(height: dot)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(WorkflowLayering.sentence(nodes: nodes, edges: edges))
    }

    private var connector: some View {
        Rectangle()
            .fill(Theme.border)
            .frame(width: 8, height: 1.5)
    }

    private func mark(for node: WorkflowNode) -> some View {
        let state = state(of: node)
        return MiniGraphNode(node: node, tint: state.tint, emphatic: state.emphatic, live: state.live, dot: dot)
    }

    private func overflow(_ count: Int) -> some View {
        Text("+\(count)")
            .font(Theme.numeric(10, weight: .semibold))
            .foregroundStyle(.secondary)
            .frame(width: dot, height: dot)
            .background(
                RoundedRectangle(cornerRadius: dot / 3, style: .continuous)
                    .fill(Theme.border.opacity(0.5))
            )
            .help(L10n.text("apple.minigraph.0_more_steps.af5b37ef", "\(count)"))
    }

    private func state(of node: WorkflowNode) -> (tint: Color, emphatic: Bool, live: Bool) {
        if node.id == currentNodeID {
            return (Theme.stateWorking, true, true)
        }
        guard let step = steps.first(where: { $0.nodeID == node.id }) else {
            return (Theme.accent, false, false)
        }
        let running = step.status == "running" || step.status == "waiting"
        return (RunOutcome.tint(step.status), true, running)
    }
}

private struct MiniGraphNode: View {
    var node: WorkflowNode
    var tint: Color
    var emphatic: Bool
    var live: Bool
    var dot: CGFloat

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dimmed = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: dot / 3, style: .continuous)
                .fill(tint.opacity(0.14))
            RoundedRectangle(cornerRadius: dot / 3, style: .continuous)
                .strokeBorder(tint.opacity(emphatic ? 0.75 : 0.3), lineWidth: 1)
            if node.kind == .agent, let backend = node.backend, !backend.isEmpty {
                HarnessMark(id: backend, size: dot * 0.6)
            } else {
                FeatureMark(name: node.kind.mark, tint: tint, size: dot * 0.6)
            }
        }
        .frame(width: dot, height: dot)
        .animation(
            dimmed
                ? .easeInOut(duration: 1.1).repeatForever(autoreverses: true)
                : .easeInOut(duration: 0.2)
        ) { $0.opacity(dimmed ? 0.55 : 1) }
        .onAppear { dimmed = shouldPulse }
        .onChange(of: live) { _, _ in dimmed = shouldPulse }
        .help(node.displayTitle)
    }

    private var shouldPulse: Bool {
        live && !reduceMotion
    }
}
