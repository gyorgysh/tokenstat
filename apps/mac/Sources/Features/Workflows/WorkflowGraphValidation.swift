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
        case (.condition, .ok): return L10n.text("apple.workflowgraphvalidation.then.0597f441")
        case (.condition, .error): return L10n.text("apple.workflowgraphvalidation.else.9c77d72e")
        case (.loop, .ok): return L10n.text("apple.workflowgraphvalidation.body.6ccaa641")
        case (.loop, .always): return L10n.text("apple.workflowgraphvalidation.after_last_pass.c89d89b0")
        case (_, .ok): return L10n.text("apple.workflowgraphvalidation.then.0597f441")
        case (_, .error): return L10n.text("apple.workflowgraphvalidation.on_error.817fc01c")
        case (_, .always): return L10n.text("apple.workflowgraphvalidation.always.de9f057a")
        }
    }

    static func whenOptions(kind: WorkflowNodeKind) -> [(value: WorkflowEdgeWhen, label: String)] {
        [WorkflowEdgeWhen.ok, .error, .always].map { ($0, outgoingRole(kind: kind, when: $0)) }
    }

    static func connectionCaption(kind: WorkflowNodeKind) -> String {
        switch kind {
        case .condition:
            return L10n.text("apple.workflowgraphvalidation.then_is_success_else_is_error_the_test_rea.8b4c9b63")
        case .loop:
            return L10n.text("apple.workflowgraphvalidation.body_is_the_repeated_work_after_last_pass.121c684e")
        case .gate:
            return L10n.text("apple.workflowgraphvalidation.the_run_pauses_here_continue_or_stop_from.793fcc9e")
        case .input:
            return L10n.text("apple.workflowgraphvalidation.the_starting_prompt_fills_input_when_you_p.25eaf312")
        default:
            return L10n.text("apple.workflowgraphvalidation.then_is_on_success_on_error_is_the_failure.bab7fe1d")
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
            return L10n.text("apple.workflowgraphvalidation.mcp_steps_are_not_available_yet.d3e1bfc3")
        }
        if nodeCount >= maxNodes {
            return L10n.text("apple.workflowgraphvalidation.a_workflow_may_have_at_most_0_steps.e533210f", "\(maxNodes)")
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
            return L10n.text("apple.workflowgraphvalidation.a_step_cannot_connect_to_itself.315c4446")
        }
        let ids = Set(nodes.map(\.id))
        if !ids.contains(from) {
            return L10n.text("apple.workflowgraphvalidation.a_connection_starts_from_a_missing_step.f423e421")
        }
        if !ids.contains(to) {
            return L10n.text("apple.workflowgraphvalidation.a_connection_points_to_a_missing_step.611cba65")
        }
        let replacing = edges.contains { $0.from == from && $0.to == to }
        if !replacing, edges.count >= maxEdges {
            return L10n.text("apple.workflowgraphvalidation.a_workflow_may_have_at_most_0_connections.32d67dc9", "\(maxEdges)")
        }
        return nil
    }

    static func stepsIssue(nodes: [WorkflowNode], edges: [WorkflowEdge]) -> String? {
        if nodes.count > maxNodes {
            return L10n.text("apple.workflowgraphvalidation.a_workflow_may_have_at_most_0_steps.e533210f", "\(maxNodes)")
        }
        if edges.count > maxEdges {
            return L10n.text("apple.workflowgraphvalidation.a_workflow_may_have_at_most_0_connections.32d67dc9", "\(maxEdges)")
        }
        var ids = Set<String>()
        for node in nodes {
            let trimmed = node.id.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                return L10n.text("apple.workflowgraphvalidation.every_step_needs_an_id.8d69a4a0")
            }
            if !isPathSafeID(node.id) {
                if node.id.utf8.count > maxPathID * 4 || node.id.contains("\0") {
                    return L10n.text("apple.workflowgraphvalidation.step_id_0_cannot_be_used.cb82549b", "\(node.id)")
                }
            }
            if !ids.insert(node.id).inserted {
                return L10n.text("apple.workflowgraphvalidation.two_steps_share_the_id_0.7df9bf9b", "\(node.id)")
            }
            if let issue = nodeIssue(node) {
                return issue
            }
        }
        for edge in edges {
            if !ids.contains(edge.from) {
                return L10n.text("apple.workflowgraphvalidation.a_connection_starts_from_a_missing_step.f423e421")
            }
            if !ids.contains(edge.to) {
                return L10n.text("apple.workflowgraphvalidation.a_connection_points_to_a_missing_step.611cba65")
            }
            if edge.from == edge.to {
                return L10n.text("apple.workflowgraphvalidation.a_step_cannot_connect_to_itself.315c4446")
            }
        }
        if hasIllegalCycle(nodes: nodes, edges: edges) {
            return L10n.text("apple.workflowgraphvalidation.this_graph_loops_without_a_loop_step.92bd3735")
        }
        for node in nodes where node.kind == .loop {
            let times = node.times ?? 3
            if !(1...maxLoopTimes).contains(times) {
                return L10n.text("apple.workflowgraphvalidation.a_loop_may_repeat_at_most_0_times.5ac3bdc7", "\(maxLoopTimes)")
            }
            if !edges.contains(where: { $0.from == node.id && $0.when == .ok }) {
                return L10n.text("apple.workflowgraphvalidation.loop_0_needs_a_body_connection.0195107c", "\(node.displayTitle)")
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
                return L10n.text("apple.workflowgraphvalidation.if_only_supports_contains_equals_or_matche.3a5207ff")
            }
        case .mcp:
            return L10n.text("apple.workflowgraphvalidation.mcp_steps_are_not_available_yet.d3e1bfc3")
        case .agent:
            if (node.backend ?? "").isEmpty {
                return L10n.text("apple.workflowgraphvalidation.an_agent_step_needs_an_agent.4f1e96ec")
            }
            return nil
        case .automation:
            if (node.automationID ?? "").isEmpty {
                return L10n.text("apple.workflowgraphvalidation.an_automation_step_needs_an_automation.5eb2b325")
            }
            return nil
        case .http:
            let url = node.url ?? ""
            if url.isEmpty {
                return L10n.text("apple.workflowgraphvalidation.an_http_step_needs_a_url.78b1c371")
            }
            if !(url.hasPrefix("http://") || url.hasPrefix("https://")) {
                return L10n.text("apple.workflowgraphvalidation.an_http_url_must_start_with_http_or_https.f66df6ab")
            }
            return nil
        case .command:
            let text = node.command ?? node.prompt ?? ""
            if text.isEmpty {
                return L10n.text("apple.workflowgraphvalidation.a_command_step_needs_a_command.5d665b7c")
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
