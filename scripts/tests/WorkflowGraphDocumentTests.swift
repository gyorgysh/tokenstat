// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
// Compile with WorkflowGraphValidation.swift WorkflowGraphDocument.swift.
import Foundation

enum WorkflowScope: String, Codable, Sendable, Hashable {
    case global, workspace
}

enum WorkflowNodeKind: String, Codable, Sendable, Hashable {
    case input, agent, automation, http, command, gate, condition, loop, mcp
    var label: String {
        switch self {
        case .input: return "Input"
        case .agent: return "Agent"
        case .automation: return "Automation"
        case .http: return "HTTP"
        case .command: return "Command"
        case .gate: return "Gate"
        case .condition: return "If"
        case .loop: return "Loop"
        case .mcp: return "MCP"
        }
    }
}

enum WorkflowEdgeWhen: String, Codable, Sendable, Hashable {
    case ok, error, always
}

struct WorkflowNode: Codable, Sendable, Hashable, Identifiable {
    var id: String
    var kind: WorkflowNodeKind
    var x: Double = 0
    var y: Double = 0
    var title: String = ""
    var backend: String? = nil
    var model: String? = nil
    var effort: String? = nil
    var prompt: String? = nil
    var wait: String? = nil
    var waitPattern: String? = nil
    var automationID: String? = nil
    var promptOverride: String? = nil
    var method: String? = nil
    var url: String? = nil
    var headers: [String: String]? = nil
    var body: String? = nil
    var command: String? = nil
    var test: String? = nil
    var pattern: String? = nil
    var times: UInt32? = nil
    var until: String? = nil

    var displayTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        return kind.label
    }
}

struct WorkflowEdge: Codable, Sendable, Hashable, Identifiable {
    var from: String
    var to: String
    var when: WorkflowEdgeWhen = .ok
    var id: String { "\(from)>\(to):\(when.rawValue)" }
}

struct WorkflowGraph: Codable, Sendable, Hashable, Identifiable {
    var id: String = ""
    var name: String
    var scope: WorkflowScope = .workspace
    var workspaceID: String? = nil
    var budgetSeconds: UInt64 = 10_800
    var enabled: Bool = false
    var nodes: [WorkflowNode] = []
    var edges: [WorkflowEdge] = []
    var lastRunAtMs: Int64? = nil
    var lastRunID: String? = nil

    static func blank(name: String = "Untitled") -> WorkflowGraph {
        WorkflowGraph(
            name: name,
            nodes: [WorkflowNode(id: "in", kind: .input, x: 80, y: 120, title: "Start")]
        )
    }

    mutating func layoutIfNeeded() {
        guard !nodes.isEmpty else { return }
        if nodes.contains(where: { $0.x != 0 || $0.y != 0 }) { return }
        for idx in nodes.indices {
            nodes[idx].x = 80
            nodes[idx].y = 80 + Double(idx) * 160
        }
    }
}

@main
struct WorkflowGraphDocumentTests {
    static func main() {
        func check(_ condition: Bool, _ message: String) {
            assert(condition, message)
        }

        check(WorkflowGraphRules.authorableKinds.count == 8, "every kind except MCP")
        check(!WorkflowGraphRules.authorableKinds.contains(.mcp), "MCP is not authorable")

        do {
            var document = WorkflowGraphDocument()
            check(!document.isOpen, "closed to start")
            document.open(WorkflowGraph.blank(), dirty: false)
            check(document.selectedNodeID == "in", "opens on Start")
            check(document.graph?.nodes.count == 1, "blank start")
            check(!document.isDirty, "saved graph is clean")
            check(document.stepsIssue == nil, "blank is valid")
        }

        do {
            var document = WorkflowGraphDocument()
            document.open(WorkflowGraph.blank(), dirty: true)
            document.addNode(kind: .agent, backend: "codex")
            let agent = document.selectedNode
            check(agent?.id == "n2", "stable n{n} id")
            check(agent?.kind == .agent, "agent kind")
            check(agent?.title == "Agent", "kind label")
            check(agent?.backend == "codex", "backend kept")
            check(agent?.prompt == "{{input}}", "agent prompt")
            check(agent?.wait == "exit", "agent wait")
            check(agent?.x == 80 && agent?.y == 280, "under the selected start")
            check(document.graph?.edges.map(\.id) == ["in>n2:ok"], "auto edge from selection")
            check(document.isDirty, "add is dirty")
            check(document.stepsIssue == nil, "agent with backend is valid")
        }

        do {
            var document = WorkflowGraphDocument()
            document.open(WorkflowGraph.blank(), dirty: true)
            document.addNode(kind: .http)
            check(document.selectedNode?.method == "GET", "http method")
            check(document.selectedNode?.url == "https://", "http url")
            document.addNode(kind: .command)
            check(document.selectedNode?.command == "echo ok", "command default")
            document.addNode(kind: .condition)
            check(document.selectedNode?.test == "contains", "condition default")
            document.addNode(kind: .loop)
            check(document.selectedNode?.times == 3, "loop default")
            document.addNode(kind: .gate)
            check(document.selectedNode?.kind == .gate, "gate")
            document.addNode(kind: .automation, automationID: "job-1")
            check(document.selectedNode?.automationID == "job-1", "automation id")
            document.addNode(kind: .mcp)
            check(document.selectedNode?.kind == .automation, "mcp is refused")
            check(WorkflowGraphRules.additionIssue(kind: .mcp, nodeCount: 1) == "MCP steps are not available yet.", "mcp copy")
        }

        do {
            var document = WorkflowGraphDocument()
            document.open(WorkflowGraph.blank(), dirty: true)
            document.addNode(kind: .command)
            document.connect(from: "in", to: "n2", when: .error)
            check(document.graph?.edges.count == 1, "same pair is one edge")
            check(document.graph?.edges.first?.when == .error, "connect replaces when")
            document.connect(from: "in", to: "in", when: .ok)
            check(document.graph?.edges.count == 1, "self connect is refused")
            document.connect(from: "missing", to: "n2", when: .ok)
            check(document.graph?.edges.count == 1, "unknown from is refused")
        }

        do {
            var document = WorkflowGraphDocument()
            document.open(WorkflowGraph.blank(), dirty: true)
            document.addNode(kind: .command)
            document.addNode(kind: .command)
            document.selectNode("n2")
            document.deleteSelection()
            check(document.graph?.nodes.map(\.id) == ["in", "n3"], "deleted node")
            check(document.graph?.edges.contains(where: { $0.from == "n2" || $0.to == "n2" }) == false, "incident edges go")
            check(document.selectedNodeID == "in", "selects remaining first")
            document.selectEdge("in>n3:ok")
            document.deleteSelection()
            check(document.graph?.edges.isEmpty == true, "deleted edge")
            check(document.selectedEdgeID == nil, "edge selection cleared")
        }

        do {
            var document = WorkflowGraphDocument()
            document.open(WorkflowGraph.blank(), dirty: true)
            document.selectNode("in")
            document.addNode(kind: .command)
            check(document.selectedNodeID == "n2", "new step selected")
            document.undo()
            check(document.graph?.nodes.map(\.id) == ["in"], "undo add")
            check(document.selectedNodeID == "in", "undo restores selection")
            document.redo()
            check(document.graph?.nodes.map(\.id) == ["in", "n2"], "redo add")
            check(document.selectedNodeID == "n2", "redo restores selection")
        }

        do {
            var document = WorkflowGraphDocument()
            document.open(WorkflowGraph.blank(), dirty: true)
            document.beginGroupedEdit()
            document.writeWorking { graph in
                if let idx = graph.nodes.firstIndex(where: { $0.id == "in" }) {
                    graph.nodes[idx].title = "Start here"
                }
            }
            document.writeWorking { graph in
                if let idx = graph.nodes.firstIndex(where: { $0.id == "in" }) {
                    graph.nodes[idx].title = "Start now"
                }
            }
            document.endGroupedEdit()
            check(document.graph?.nodes.first?.title == "Start now", "grouped write")
            document.undo()
            check(document.graph?.nodes.first?.title == "Start", "one undo for the group")
            check(!document.canUndo, "group was one snapshot")
        }

        do {
            var document = WorkflowGraphDocument()
            document.open(WorkflowGraph.blank(), dirty: true)
            document.beginNodeMove()
            document.moveNode(id: "in", x: 40, y: 90)
            document.moveNode(id: "in", x: 12, y: 18)
            check(document.graph?.nodes.first?.x == 12, "live drag")
            document.undo()
            check(document.graph?.nodes.first?.x == 80, "one undo for the drag")
        }

        do {
            var document = WorkflowGraphDocument()
            document.open(WorkflowGraph.blank(), dirty: true)
            for i in 0..<WorkflowGraphRules.undoLimit + 5 {
                document.rename("Name \(i)")
            }
            var undos = 0
            while document.canUndo {
                document.undo()
                undos += 1
            }
            check(undos == WorkflowGraphRules.undoLimit, "undo cap 30")
        }

        do {
            var document = WorkflowGraphDocument()
            document.open(WorkflowGraph.blank(), dirty: true)
            document.addNode(kind: .command)
            document.selectEdge("in>n2:ok")
            document.updateSelectedEdge(when: .always)
            check(document.selectedEdgeID == "in>n2:always", "edge id follows when")
            check(document.graph?.edges.first?.when == .always, "when written")
        }

        do {
            var document = WorkflowGraphDocument()
            document.open(WorkflowGraph.blank(name: "Untitled"), dirty: true)
            document.replaceSteps(
                nodes: [
                    WorkflowNode(id: "in", kind: .input, title: "Start"),
                    WorkflowNode(id: "build", kind: .agent, title: "Build", backend: "codex", prompt: "{{input}}"),
                ],
                edges: [WorkflowEdge(from: "in", to: "build")],
                nameIfUntitled: "Plan then build"
            )
            check(document.graph?.name == "Plan then build", "recipe names untitled")
            check(document.graph?.nodes.count == 2, "recipe nodes")
            check(document.selectedNodeID == "in", "recipe selects first")
            check(document.stepsIssue == nil, "recipe is valid")
        }

        do {
            var node = WorkflowGraphRules.makeNode(kind: .agent, id: "a", x: 1, y: 2, backend: "grok")
            node.model = "grok-4"
            node.effort = "high"
            node.prompt = "hello"
            node.wait = "output"
            node.waitPattern = "done"
            check(node.backend == "grok", "backend field")
            check(node.model == "grok-4", "model field")
            check(node.effort == "high", "effort field")
            check(node.prompt == "hello", "prompt field")
            check(node.wait == "output", "wait field")
            check(node.waitPattern == "done", "waitPattern field")
            var automation = WorkflowGraphRules.makeNode(kind: .automation, id: "job", x: 0, y: 0, automationID: "auto-1")
            automation.promptOverride = "override"
            check(automation.automationID == "auto-1", "automationId field")
            check(automation.promptOverride == "override", "promptOverride field")
            var http = WorkflowGraphRules.makeNode(kind: .http, id: "h", x: 0, y: 0)
            http.headers = ["Authorization": "Bearer x"]
            http.body = "{\"ok\":true}"
            check(http.method == "GET", "method field")
            check(http.url == "https://", "url field")
            check(http.headers?["Authorization"] == "Bearer x", "headers field")
            check(http.body == "{\"ok\":true}", "body field")
            var command = WorkflowGraphRules.makeNode(kind: .command, id: "c", x: 0, y: 0)
            command.command = "ls"
            check(command.command == "ls", "command field")
            var condition = WorkflowGraphRules.makeNode(kind: .condition, id: "if", x: 0, y: 0)
            condition.pattern = "READY"
            check(condition.test == "contains", "test field")
            check(condition.pattern == "READY", "pattern field")
            var loop = WorkflowGraphRules.makeNode(kind: .loop, id: "loop", x: 0, y: 0)
            loop.until = "{{input}}"
            check(loop.times == 3, "times field")
            check(loop.until == "{{input}}", "until field")
        }

        do {
            let agent = WorkflowNode(id: "a", kind: .agent, title: "Build")
            check(WorkflowGraphRules.nodeIssue(agent) == "An agent step needs an agent.", "agent backend")
            let job = WorkflowNode(id: "j", kind: .automation, title: "Nightly")
            check(WorkflowGraphRules.nodeIssue(job) == "An automation step needs an automation.", "automation id")
            var http = WorkflowNode(id: "h", kind: .http, title: "Call")
            check(WorkflowGraphRules.nodeIssue(http) == "An HTTP step needs a URL.", "http url missing")
            http.url = "ftp://example"
            check(WorkflowGraphRules.nodeIssue(http) == "An HTTP URL must start with http:// or https://.", "http scheme")
            http.url = "https://example"
            check(WorkflowGraphRules.nodeIssue(http) == nil, "http ok")
            var command = WorkflowNode(id: "c", kind: .command, title: "Shell")
            check(WorkflowGraphRules.nodeIssue(command) == "A command step needs a command.", "command missing")
            command.prompt = "echo hi"
            check(WorkflowGraphRules.nodeIssue(command) == nil, "command via prompt")
            let condition = WorkflowNode(id: "if", kind: .condition, title: "If", test: "regex")
            check(WorkflowGraphRules.nodeIssue(condition) == "If only supports Contains, Equals or Matches.", "unknown test")
            let mcp = WorkflowNode(id: "m", kind: .mcp, title: "Tools")
            check(WorkflowGraphRules.nodeIssue(mcp) == "MCP steps are not available yet.", "mcp reserved")
        }

        do {
            let cycle = WorkflowGraph(
                name: "Cycle",
                nodes: [
                    WorkflowNode(id: "in", kind: .input, title: "Start"),
                    WorkflowNode(id: "a", kind: .command, title: "A", command: "echo a"),
                    WorkflowNode(id: "b", kind: .command, title: "B", command: "echo b"),
                ],
                edges: [
                    WorkflowEdge(from: "in", to: "a"),
                    WorkflowEdge(from: "a", to: "b"),
                    WorkflowEdge(from: "b", to: "a"),
                ]
            )
            check(cycle.stepsIssue == "This graph loops without a Loop step.", "illegal cycle")
            let looped = WorkflowGraph(
                name: "Loop",
                nodes: [
                    WorkflowNode(id: "in", kind: .input, title: "Start"),
                    WorkflowNode(id: "loop", kind: .loop, title: "Retry", times: 3),
                    WorkflowNode(id: "body", kind: .command, title: "Body", command: "echo body"),
                    WorkflowNode(id: "done", kind: .command, title: "Done", command: "echo done"),
                ],
                edges: [
                    WorkflowEdge(from: "in", to: "loop"),
                    WorkflowEdge(from: "loop", to: "body", when: .ok),
                    WorkflowEdge(from: "body", to: "loop", when: .ok),
                    WorkflowEdge(from: "loop", to: "done", when: .always),
                ]
            )
            check(looped.stepsIssue == nil, "cycle through loop is legal")
            var noBody = looped
            noBody.edges.removeAll { $0.from == "loop" && $0.when == .ok }
            check(noBody.stepsIssue == "Loop Retry needs a body connection.", "loop body")
            var times = looped
            times.nodes[1].times = 21
            check(times.stepsIssue == "A loop may repeat at most 20 times.", "loop cap")
        }

        do {
            let duplicate = WorkflowGraph(
                name: "Dup",
                nodes: [
                    WorkflowNode(id: "in", kind: .input, title: "Start"),
                    WorkflowNode(id: "in", kind: .command, title: "Again", command: "echo"),
                ]
            )
            check(duplicate.stepsIssue == "Two steps share the id in.", "duplicate id")
            let missing = WorkflowGraph(
                name: "Missing",
                nodes: [WorkflowNode(id: "in", kind: .input, title: "Start")],
                edges: [WorkflowEdge(from: "in", to: "gone")]
            )
            check(missing.stepsIssue == "A connection points to a missing step.", "unknown to")
            let grandfather = WorkflowGraph(
                name: "Old",
                nodes: [WorkflowNode(id: "step 1", kind: .input, title: "Start")]
            )
            check(grandfather.stepsIssue == nil, "old id with a space is kept")
            let nul = WorkflowGraph(
                name: "Nul",
                nodes: [WorkflowNode(id: "a\0b", kind: .input, title: "Start")]
            )
            check(nul.stepsIssue == "Step id a\0b cannot be used.", "nul id")
            check(WorkflowGraphRules.isPathSafeID("n2"), "new ids are path safe")
            check(!WorkflowGraphRules.isPathSafeID("step 1"), "space is not path safe")
        }

        do {
            var document = WorkflowGraphDocument()
            document.open(WorkflowGraph.blank(), dirty: true)
            for _ in 0..<(WorkflowGraphRules.maxNodes - 1) {
                document.addNode(kind: .gate)
            }
            check(document.graph?.nodes.count == WorkflowGraphRules.maxNodes, "filled to cap")
            document.addNode(kind: .gate)
            check(document.graph?.nodes.count == WorkflowGraphRules.maxNodes, "refuses a 65th step")
            var packed = WorkflowGraph(name: "Packed", nodes: (0..<12).map {
                WorkflowNode(id: "n\($0)", kind: .gate, title: "G")
            })
            for from in packed.nodes {
                for to in packed.nodes where from.id != to.id {
                    packed.edges.append(WorkflowEdge(from: from.id, to: to.id))
                    if packed.edges.count == WorkflowGraphRules.maxEdges { break }
                }
                if packed.edges.count == WorkflowGraphRules.maxEdges { break }
            }
            check(packed.edges.count == WorkflowGraphRules.maxEdges, "128 edges")
            var document2 = WorkflowGraphDocument()
            document2.open(packed, dirty: true)
            document2.connect(from: "n0", to: "n1", when: .always)
            check(document2.graph?.edges.count == WorkflowGraphRules.maxEdges, "replace at cap")
            let already = Set(packed.edges.map { "\($0.from)>\($0.to)" })
            var added = false
            for from in packed.nodes {
                for to in packed.nodes where from.id != to.id && !already.contains("\(from.id)>\(to.id)") {
                    document2.connect(from: from.id, to: to.id, when: .ok)
                    added = true
                    break
                }
                if added { break }
            }
            check(added, "there is a pair left")
            check(document2.graph?.edges.count == WorkflowGraphRules.maxEdges, "new pair at cap is refused")
        }

        do {
            var document = WorkflowGraphDocument()
            document.open(WorkflowGraph.blank(name: "Review"), dirty: true)
            document.setScope(.workspace, workspaceID: "folder")
            document.setBudgetMinutes(30)
            check(document.graph?.workspaceID == "folder", "scope")
            check(document.graph?.budgetSeconds == 1800, "budget")
            document.markSaved(document.graph!)
            check(!document.isDirty, "saved is clean")
            var host = document.graph!
            host.name = "Host copy"
            document.reloadClean(host)
            check(document.graph?.name == "Host copy", "clean reload")
            document.rename("Local")
            document.reloadClean(WorkflowGraph.blank(name: "Ignored"))
            check(document.graph?.name == "Local", "dirty reload ignored")
        }

        print("WorkflowGraphDocumentTests passed")
    }
}
