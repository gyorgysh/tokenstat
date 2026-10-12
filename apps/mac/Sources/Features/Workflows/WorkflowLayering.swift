// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import Foundation

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
    /// Longest-path layers for acyclic edges. Wait for every predecessor
    /// before visiting a join, so its successors inherit its final depth.
    /// Cyclic components have no topological order: break the first remaining
    /// node's incoming edges deterministically, keeping all nodes visible and
    /// ignoring back edges to nodes already placed.
    static func depths(nodes: [WorkflowNode], edges: [WorkflowEdge]) -> [String: Int] {
        let known = Set(nodes.map(\.id))
        var incoming = Dictionary(uniqueKeysWithValues: known.map { ($0, 0) })
        var outgoing: [String: [String]] = [:]
        for edge in edges where known.contains(edge.from) && known.contains(edge.to) {
            incoming[edge.to, default: 0] += 1
            outgoing[edge.from, default: []].append(edge.to)
        }
        var queue = nodes.filter { incoming[$0.id] == 0 }.map(\.id)
        var depth: [String: Int] = [:]
        var placed = Set<String>()
        var index = 0
        while placed.count < known.count {
            if index == queue.count {
                guard let next = nodes.first(where: { !placed.contains($0.id) }) else { break }
                queue.append(next.id)
            }
            let id = queue[index]
            index += 1
            guard placed.insert(id).inserted else { continue }
            let current = depth[id, default: 0]
            depth[id] = current
            for next in outgoing[id] ?? [] where !placed.contains(next) {
                depth[next] = max(depth[next, default: 0], current + 1)
                incoming[next, default: 0] -= 1
                if incoming[next] == 0 { queue.append(next) }
            }
        }
        return depth
    }

    static func layers(nodes: [WorkflowNode], edges: [WorkflowEdge]) -> [[WorkflowNode]] {
        let depth = depths(nodes: nodes, edges: edges)
        let grouped = Dictionary(grouping: nodes) { depth[$0.id, default: 0] }
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
        if steps.isEmpty { return L10n.text("apple.minigraph.empty_workflow.f1fad181") }
        return steps.joined(separator: ", then ")
    }
}
