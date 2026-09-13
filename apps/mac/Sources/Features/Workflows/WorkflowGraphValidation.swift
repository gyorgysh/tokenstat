// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

import Foundation

/// Host graph limits and the messages a person sees before Save.
///
/// Keep the numbers and the legal shapes in step with
/// `tokenstat-host::workflows::validate`. Wording is product copy, not the
/// host's lowercase internals.
enum WorkflowGraphRules {
    static let maxNodes = 64
    static let maxEdges = 128
    static let maxLoopTimes: UInt32 = 20
    static let maxPathID = 128
    static let undoLimit = 30
    static let columnWidth = 252.0
    static let rowHeight = 160.0
    static let originX = 80.0
    static let originY = 80.0

    /// Kinds a person can add. MCP is reserved on the host.
    static let authorableKinds: [WorkflowNodeKind] = [
        .input, .agent, .automation, .http, .command, .gate, .condition, .loop,
    ]

    /// How an outgoing connection is named on the step list and detail.
    ///
    /// If uses Then/Else. Loop uses Body for the repeated work and After last
    /// pass for the way out. Other steps use Then, On error and Always.
    static func outgoingRole(kind: WorkflowNodeKind, when: WorkflowEdgeWhen) -> String {
        switch (kind, when) {
        case (.condition, .ok): return "Then"
        case (.condition, .error): return "Else"
        case (.loop, .ok): return "Body"
        case (.loop, .always): return "After last pass"
        case (_, .ok): return "Then"
        case (_, .error): return "On error"
        case (_, .always): return "Always"
        }
    }

    static func whenOptions(kind: WorkflowNodeKind) -> [(value: WorkflowEdgeWhen, label: String)] {
        [WorkflowEdgeWhen.ok, .error, .always].map { ($0, outgoingRole(kind: kind, when: $0)) }
    }

    static func connectionCaption(kind: WorkflowNodeKind) -> String {
        switch kind {
        case .condition:
            return "Then is success. Else is error. The test reads the previous step."
        case .loop:
            return "Body is the repeated work. After last pass is where the run goes when the loop is done. At most 20 passes."
        case .gate:
            return "The run pauses here. Continue or Stop from the run."
        case .input:
            return "The starting prompt fills {{input}} when you press Run."
        default:
            return "Then is on success. On error is the failure path. Always runs either way."
        }
    }

    static func suggestedWhen(kind: WorkflowNodeKind, outgoing: [WorkflowEdge]) -> WorkflowEdgeWhen {
        let used = Set(outgoing.map(\.when))
        switch kind {
        case .loop:
            if !used.contains(.ok) { return .ok }
            return .always
        case .condition:
            if !used.contains(.ok) { return .ok }
            if !used.contains(.error) { return .error }
            return .always
        default:
            if !used.contains(.ok) { return .ok }
            if !used.contains(.error) { return .error }
            return .always
        }
    }

    static func additionIssue(kind: WorkflowNodeKind, nodeCount: Int) -> String? {
        if kind == .mcp {
            return "MCP steps are not available yet."
        }
        if nodeCount >= maxNodes {
            return "A workflow may have at most \(maxNodes) steps."
        }
        return nil
    }

    static func connectionIssue(
        from: String,
        to: String,
        nodes: [WorkflowNode],
        edges: [WorkflowEdge]
    ) -> String? {
        if from == to {
            return "A step cannot connect to itself."
        }
        let ids = Set(nodes.map(\.id))
        if !ids.contains(from) {
            return "A connection starts from a missing step."
        }
        if !ids.contains(to) {
            return "A connection points to a missing step."
        }
        let replacing = edges.contains { $0.from == from && $0.to == to }
        if !replacing, edges.count >= maxEdges {
            return "A workflow may have at most \(maxEdges) connections."
        }
        return nil
    }

    static func stepsIssue(nodes: [WorkflowNode], edges: [WorkflowEdge]) -> String? {
        if nodes.count > maxNodes {
            return "A workflow may have at most \(maxNodes) steps."
        }
        if edges.count > maxEdges {
            return "A workflow may have at most \(maxEdges) connections."
        }
        var ids = Set<String>()
        for node in nodes {
            let trimmed = node.id.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                return "Every step needs an id."
            }
            if !isPathSafeID(node.id) {
                if node.id.utf8.count > maxPathID * 4 || node.id.contains("\0") {
                    return "Step id \(node.id) cannot be used."
                }
            }
            if !ids.insert(node.id).inserted {
                return "Two steps share the id \(node.id)."
            }
            if let issue = nodeIssue(node) {
                return issue
            }
        }
        for edge in edges {
            if !ids.contains(edge.from) {
                return "A connection starts from a missing step."
            }
            if !ids.contains(edge.to) {
                return "A connection points to a missing step."
            }
            if edge.from == edge.to {
                return "A step cannot connect to itself."
            }
        }
        if hasIllegalCycle(nodes: nodes, edges: edges) {
            return "This graph loops without a Loop step."
        }
        for node in nodes where node.kind == .loop {
            let times = node.times ?? 3
            if !(1...maxLoopTimes).contains(times) {
                return "A loop may repeat at most \(maxLoopTimes) times."
            }
            if !edges.contains(where: { $0.from == node.id && $0.when == .ok }) {
                return "Loop \(node.displayTitle) needs a body connection."
            }
        }
        return nil
    }

    static func nodeIssue(_ node: WorkflowNode) -> String? {
        switch node.kind {
        case .input, .gate, .loop:
            return nil
        case .condition:
            switch node.test ?? "contains" {
            case "contains", "equals", "matches":
                return nil
            default:
                return "If only supports Contains, Equals or Matches."
            }
        case .mcp:
            return "MCP steps are not available yet."
        case .agent:
            if (node.backend ?? "").isEmpty {
                return "An agent step needs an agent."
            }
            return nil
        case .automation:
            if (node.automationID ?? "").isEmpty {
                return "An automation step needs an automation."
            }
            return nil
        case .http:
            let url = node.url ?? ""
            if url.isEmpty {
                return "An HTTP step needs a URL."
            }
            if !(url.hasPrefix("http://") || url.hasPrefix("https://")) {
                return "An HTTP URL must start with http:// or https://."
            }
            return nil
        case .command:
            let text = node.command ?? node.prompt ?? ""
            if text.isEmpty {
                return "A command step needs a command."
            }
            return nil
        }
    }

    static func isPathSafeID(_ id: String) -> Bool {
        let utf8 = id.utf8
        return !utf8.isEmpty
            && utf8.count <= maxPathID
            && utf8.allSatisfy { byte in
                (byte >= 48 && byte <= 57)
                    || (byte >= 65 && byte <= 90)
                    || (byte >= 97 && byte <= 122)
                    || byte == 45
                    || byte == 95
            }
    }

    static func nextNodeID(in nodes: [WorkflowNode]) -> String {
        var n = nodes.count + 1
        var id = "n\(n)"
        let existing = Set(nodes.map(\.id))
        while existing.contains(id) {
            n += 1
            id = "n\(n)"
        }
        return id
    }

    static func origin(in nodes: [WorkflowNode], under id: String?) -> (x: Double, y: Double) {
        if let id, let source = nodes.first(where: { $0.id == id }) {
            return (source.x, source.y + rowHeight)
        }
        guard let last = nodes.max(by: { $0.y < $1.y }) else {
            return (originX, originY)
        }
        return (last.x, last.y + rowHeight)
    }

    static func makeNode(
        kind: WorkflowNodeKind,
        id: String,
        x: Double,
        y: Double,
        backend: String? = nil,
        automationID: String? = nil
    ) -> WorkflowNode {
        var node = WorkflowNode(id: id, kind: kind, x: x, y: y, title: kind.label)
        node.backend = backend
        node.automationID = automationID
        switch kind {
        case .agent:
            node.prompt = "{{input}}"
            node.wait = "exit"
        case .http:
            node.method = "GET"
            node.url = "https://"
        case .command:
            node.command = "echo ok"
        case .condition:
            node.test = "contains"
        case .loop:
            node.times = 3
        default:
            break
        }
        return node
    }

    /// Cycles are allowed only when every cycle passes through a loop node.
    /// Edges that touch a loop are dropped from the walk, matching the host.
    static func hasIllegalCycle(nodes: [WorkflowNode], edges: [WorkflowEdge]) -> Bool {
        let loops = Set(nodes.filter { $0.kind == .loop }.map(\.id))
        var adj: [String: [String]] = [:]
        for edge in edges {
            if loops.contains(edge.from) || loops.contains(edge.to) {
                continue
            }
            adj[edge.from, default: []].append(edge.to)
        }
        var stack = Set<String>()
        var seen = Set<String>()
        func visit(_ id: String) -> Bool {
            if !stack.insert(id).inserted {
                return true
            }
            if seen.insert(id).inserted {
                for child in adj[id] ?? [] {
                    if visit(child) {
                        return true
                    }
                }
            }
            stack.remove(id)
            return false
        }
        return nodes.contains { visit($0.id) }
    }
}

extension WorkflowGraph {
    /// Node and edge problems the host would refuse. Name, folder and
    /// schedule stay with the metadata editor.
    var stepsIssue: String? {
        WorkflowGraphRules.stepsIssue(nodes: nodes, edges: edges)
    }
}
