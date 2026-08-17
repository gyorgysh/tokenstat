// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

import SwiftUI

/// The shape of a graph, without the canvas.
///
/// A workflow is the most visual object in the app and every screen except the
/// editor used to print it as a sentence: `Start → Refine Claude haiku low →
/// Plan Grok grok-4.6 high → Done`. Nobody compares two of those at a glance.
/// This lays the same nodes out in columns, one per layer, so a library row, a
/// recipe chip and a live run all read as a picture you can tell apart from the
/// one under it.
///
/// It never mutates the graph. `x`/`y` in the IR belong to the editor canvas,
/// which is free to place nodes anywhere, so the strip re-derives its own
/// layering from the edges instead of trusting coordinates that may all be zero.
enum WorkflowLayering {
    /// Nodes grouped by longest path from an entry node.
    ///
    /// The same rule `WorkflowGraph.layoutIfNeeded` uses, kept separate because
    /// that one writes positions and this one must not. A cycle cannot loop
    /// forever here: a node is queued once, and its layer only ever rises.
    static func layers(nodes: [WorkflowNode], edges: [WorkflowEdge]) -> [[WorkflowNode]] {
        guard !nodes.isEmpty else { return [] }

        let known = Set(nodes.map(\.id))
        var incoming: [String: Int] = [:]
        var outgoing: [String: [String]] = [:]
        for node in nodes {
            incoming[node.id] = 0
        }
        for edge in edges where known.contains(edge.from) && known.contains(edge.to) {
            incoming[edge.to, default: 0] += 1
            outgoing[edge.from, default: []].append(edge.to)
        }

        var queue = nodes.filter { (incoming[$0.id] ?? 0) == 0 }.map(\.id)
        // Every node has an incoming edge, so the graph is one big cycle. Start
        // somewhere rather than showing nothing.
        if queue.isEmpty {
            queue = [nodes[0].id]
        }
        var layer: [String: Int] = [:]
        for id in queue {
            layer[id] = 0
        }

        var seen = Set(queue)
        var index = 0
        while index < queue.count {
            let id = queue[index]
            index += 1
            let depth = layer[id] ?? 0
            for next in outgoing[id] ?? [] {
                layer[next] = max(layer[next] ?? 0, depth + 1)
                if seen.insert(next).inserted {
                    queue.append(next)
                }
            }
        }

        var grouped: [Int: [WorkflowNode]] = [:]
        for node in nodes {
            grouped[layer[node.id] ?? 0, default: []].append(node)
        }
        return grouped.keys.sorted().map { grouped[$0] ?? [] }
    }

    /// The sentence the picture replaces, for VoiceOver and for `help`.
    ///
    /// Every visual in this file carries one. A shape is faster to read and no
    /// use at all to a screen reader, so the words never leave the app, they
    /// just stop taking up the row.
    static func sentence(nodes: [WorkflowNode], edges: [WorkflowEdge]) -> String {
        let steps = layers(nodes: nodes, edges: edges).map { column in
            column.map(\.displayTitle).joined(separator: " and ")
        }
        if steps.isEmpty { return "Empty workflow" }
        return steps.joined(separator: ", then ")
    }
}

/// A workflow drawn small: node marks in columns, joined by connectors.
///
/// Pass `steps` and `currentNodeID` from a run and the same strip becomes a
/// progress read-out, so a library row shows where a live run has got to
/// without anybody opening the editor.
struct MiniGraph: View {
    var nodes: [WorkflowNode]
    var edges: [WorkflowEdge] = []
    /// Per-node outcomes from a run. Empty means "not running", which draws
    /// every node in the quiet resting tint.
    var steps: [WorkflowStep] = []
    var currentNodeID: String?
    /// Columns drawn before the rest collapses into a `+n` pill.
    var maxColumns: Int = 5
    var dot: CGFloat = 22

    private var columns: [[WorkflowNode]] {
        WorkflowLayering.layers(nodes: nodes, edges: edges)
    }

    var body: some View {
        let all = columns
        let shown = Array(all.prefix(all.count > maxColumns ? maxColumns - 1 : maxColumns))
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
            .help("\(count) more steps")
    }

    /// Resting, or coloured by what the run did with this node.
    ///
    /// Note the tuple is read once per render into `MiniGraphNode`, which owns
    /// the pulse. A run usually starts while the library is already on screen,
    /// so "began breathing" has to be a change the node itself sees rather
    /// than something the strip sets up once when it appears.
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

/// One tile in the strip, and the only thing here that moves.
///
/// Its own view because the pulse has to start when the node goes live, not
/// when the strip appears: the interesting case is a run beginning under a list
/// that is already on screen, and an animation keyed to the parent's `onAppear`
/// would leave that node dimmed and still.
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
        // Only the node a run is sitting on breathes. A whole strip of moving
        // tiles says nothing about where the work is.
        .opacity(dimmed ? 0.55 : 1)
        .animation(
            dimmed
                ? .easeInOut(duration: 1.1).repeatForever(autoreverses: true)
                : .easeInOut(duration: 0.2),
            value: dimmed
        )
        .onAppear { dimmed = shouldPulse }
        .onChange(of: live) { _, _ in dimmed = shouldPulse }
        .help(node.displayTitle)
    }

    private var shouldPulse: Bool {
        live && !reduceMotion
    }
}
