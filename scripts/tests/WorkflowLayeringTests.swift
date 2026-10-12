// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
// Compile with WorkflowLayering.swift.
import Foundation

struct WorkflowNode {
    let id: String
    var displayTitle: String { id }
}
struct WorkflowEdge {
    let from: String
    let to: String
}

@main struct WorkflowLayeringTests {
    static func main() {
        let nodes = ["start", "plan", "refine", "join", "finish"].map(WorkflowNode.init)
        let edges = [
            WorkflowEdge(from: "start", to: "plan"),
            WorkflowEdge(from: "start", to: "join"),
            WorkflowEdge(from: "plan", to: "refine"),
            WorkflowEdge(from: "refine", to: "join"),
            WorkflowEdge(from: "join", to: "finish"),
        ]
        // A breadth-first pass visits join before refine updates its depth.
        for orderedEdges in [edges, Array(edges.reversed())] {
            let depths = WorkflowLayering.depths(nodes: nodes, edges: orderedEdges)
            assert(depths == ["start": 0, "plan": 1, "refine": 2, "join": 3, "finish": 4])
            assert(orderedEdges.allSatisfy { depths[$0.from]! < depths[$0.to]! })
        }
        assert(WorkflowLayering.layers(nodes: nodes, edges: edges).flatMap { $0.map(\.id) }
               == nodes.map(\.id))
        let cyclic = edges + [WorkflowEdge(from: "finish", to: "join")]
        let cycleDepths = WorkflowLayering.depths(nodes: nodes, edges: cyclic)
        assert(cycleDepths.count == nodes.count && cycleDepths.values.allSatisfy { $0 < nodes.count })
        let disconnected = [WorkflowNode(id: "isolated")] + nodes
        assert(WorkflowLayering.depths(nodes: disconnected, edges: cyclic)["isolated"] == 0)
        let invalid = edges + [WorkflowEdge(from: "missing", to: "start")]
        assert(WorkflowLayering.depths(nodes: nodes, edges: invalid)
               == WorkflowLayering.depths(nodes: nodes, edges: edges))
        assert(WorkflowLayering.layers(nodes: [], edges: edges).isEmpty)
        print("Workflow layering: joins, edge order, cycles, disconnected and missing nodes passed")
    }
}
