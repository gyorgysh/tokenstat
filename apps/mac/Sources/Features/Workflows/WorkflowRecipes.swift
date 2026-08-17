// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE.

import SwiftUI

/// Cheap / low defaults used by Design and by the example recipes.
///
/// Keep the markers in step with `tokenstat-host::agent_models`. The Mac
/// cannot call that crate, so the same rules live here.
enum WorkflowModelPick {
    static let cheapMarkers = ["haiku", "nano", "mini", "flash", "fast", "lite", "small"]

    static func cheapestModel(backend: String, models: [String]) -> String? {
        if models.isEmpty { return nil }
        for marker in cheapMarkers {
            if let id = models.first(where: { $0.lowercased().contains(marker) }) {
                return id
            }
        }
        if backend == "claude" { return models.last }
        return models.first
    }

    static func lowestEffort(_ efforts: [String]) -> String? {
        for prefer in ["low", "minimal"] {
            if let found = efforts.first(where: { $0.caseInsensitiveCompare(prefer) == .orderedSame }) {
                return found
            }
        }
        return efforts.first
    }

    static func highestEffort(_ efforts: [String]) -> String? {
        for prefer in ["high", "max", "xhigh"] {
            if let found = efforts.first(where: { $0.caseInsensitiveCompare(prefer) == .orderedSame }) {
                return found
            }
        }
        return efforts.last
    }

    static func midModel(models: [String], excluding cheap: String?) -> String? {
        let review = ["opus", "fable"]
        if let mid = models.first(where: { id in
            if let cheap, id == cheap { return false }
            let low = id.lowercased()
            if cheapMarkers.contains(where: { low.contains($0) }) { return false }
            if review.contains(where: { low.contains($0) }) { return false }
            return true
        }) {
            return mid
        }
        return models.first { $0 != cheap }
    }

    static func reviewModel(models: [String]) -> String? {
        for marker in ["opus", "fable"] {
            if let id = models.first(where: { $0.lowercased().contains(marker) }) {
                return id
            }
        }
        return nil
    }
}

/// One example pipeline. The Design field uses `prompt`. The canvas inserts
/// `nodes` and `edges` as a local draft. It does not call the model.
struct WorkflowRecipe: Identifiable {
    var id: String
    var name: String
    var label: String
    var prompt: String
    var nodes: [WorkflowNode]
    var edges: [WorkflowEdge]
}

@MainActor
enum WorkflowRecipes {
    /// Agents whose CLI is on this Mac. Hidden tiles stay out. Shell is not
    /// an agent. Empty means the example chips should hide.
    static func installedAgents(from backends: [AgentBackend]) -> [AgentBackend] {
        let agents = backends.filter { $0.id != "sh" }
        #if os(macOS)
        let installed = Set(LaunchCatalog.shared.available.map(\.id))
        return agents.filter { backend in
            backend.launcherIDs.contains { installed.contains($0) }
        }
        #else
        return agents
        #endif
    }

    /// Who Design can talk to. Prefer installed agents. If the launch catalog
    /// has not seen one yet, fall back to the advertised list minus Shell.
    static func designAgents(from backends: [AgentBackend]) -> [AgentBackend] {
        let installed = installedAgents(from: backends)
        if !installed.isEmpty { return installed }
        return backends.filter { $0.id != "sh" }
    }

    static func defaultBackend(from backends: [AgentBackend]) -> String {
        let agents = designAgents(from: backends)
        if let cheap = agents.first(where: {
            WorkflowModelPick.cheapestModel(backend: $0.id, models: $0.models) != nil
                || WorkflowModelPick.lowestEffort($0.efforts) != nil
        }) {
            return cheap.id
        }
        return agents.first?.id ?? ""
    }

    static func recipes(from backends: [AgentBackend]) -> [WorkflowRecipe] {
        let agents = installedAgents(from: backends)
        guard !agents.isEmpty else { return [] }
        var out: [WorkflowRecipe] = []
        if let full = pipeline(agents: agents, id: "full", short: false) {
            out.append(full)
        }
        if agents.count >= 2, let short = pipeline(agents: agents, id: "short", short: true) {
            if short.label != out.first?.label {
                out.append(short)
            }
        }
        return out
    }

    private struct Stage {
        var id: String
        var verb: String
        var title: String
        var backend: AgentBackend
        var model: String?
        var effort: String?
        var prompt: String
    }

    private static func pipeline(agents: [AgentBackend], id: String, short: Bool) -> WorkflowRecipe? {
        guard let refinePick = pickRefine(agents) else { return nil }
        let planPick = pickPlan(agents, refine: refinePick)
        let buildPick = pickBuild(agents, used: [refinePick.backend.id, planPick?.backend.id].compactMap { $0 })
        let reviewPick = pickReview(agents)

        var stages: [Stage] = []
        if !short {
            stages.append(stage(
                id: "refine",
                verb: "Refine",
                title: "Refine prompt",
                pick: refinePick,
                prompt: "Rewrite this starting prompt so it is clear and ready to plan.\n\n{{input}}"
            ))
        }
        if let planPick, distinct(planPick, from: stages.last) {
            stages.append(stage(
                id: "plan",
                verb: "Plan",
                title: "Plan",
                pick: planPick,
                prompt: "Write a short plan for this work.\n\n\(priorToken(stages.last?.id))"
            ))
        }
        if let buildPick {
            stages.append(stage(
                id: "build",
                verb: "Build",
                title: "Build",
                pick: buildPick,
                prompt: "Implement the plan.\n\n\(priorToken(stages.last?.id))"
            ))
        }
        if !short, let reviewPick, distinct(reviewPick, from: stages.last) {
            stages.append(stage(
                id: "review",
                verb: "Review",
                title: "Review",
                pick: reviewPick,
                prompt: "Review the work. List issues first.\n\n\(priorToken(stages.last?.id))"
            ))
        }
        guard !stages.isEmpty else { return nil }

        var nodes: [WorkflowNode] = [
            WorkflowNode(id: "in", kind: .input, title: "Start"),
        ]
        var edges: [WorkflowEdge] = []
        var previous = "in"
        for item in stages {
            nodes.append(WorkflowNode(
                id: item.id,
                kind: .agent,
                title: item.title,
                backend: item.backend.id,
                model: item.model,
                effort: item.effort,
                prompt: item.prompt,
                wait: "exit"
            ))
            edges.append(WorkflowEdge(from: previous, to: item.id, when: .ok))
            previous = item.id
        }
        nodes.append(WorkflowNode(
            id: "done",
            kind: .command,
            title: "Done",
            command: "afplay /System/Library/Sounds/Glass.aiff"
        ))
        edges.append(WorkflowEdge(from: previous, to: "done", when: .ok))

        let labelParts = ["Start"] + stages.map(label(for:)) + ["Done"]
        let label = labelParts.joined(separator: " → ")
        let prompt = "Starting prompt, then "
            + stages.map { part in
                var bits = [part.verb.lowercased(), "on", part.backend.label]
                if let model = part.model, !model.isEmpty { bits.append(model) }
                if let effort = part.effort, !effort.isEmpty { bits.append("(\(effort))") }
                return bits.joined(separator: " ")
            }
            .joined(separator: ", then ")
            + ", then play the system done sound."
        return WorkflowRecipe(
            id: id,
            name: short ? "Plan then build" : "Plan, build, review",
            label: label,
            prompt: prompt,
            nodes: nodes,
            edges: edges
        )
    }

    private static func priorToken(_ previous: String?) -> String {
        guard let previous else { return "{{input}}" }
        return "{{\(previous).output}}"
    }

    private static func stage(
        id: String,
        verb: String,
        title: String,
        pick: AgentPick,
        prompt: String
    ) -> Stage {
        Stage(
            id: id,
            verb: verb,
            title: title,
            backend: pick.backend,
            model: pick.model,
            effort: pick.effort,
            prompt: prompt
        )
    }

    private static func label(for stage: Stage) -> String {
        var bits = [stage.verb, stage.backend.label]
        if let model = stage.model, !model.isEmpty { bits.append(model) }
        if let effort = stage.effort, !effort.isEmpty { bits.append(effort) }
        return bits.joined(separator: " ")
    }

    private struct AgentPick {
        var backend: AgentBackend
        var model: String?
        var effort: String?
    }

    private static func distinct(_ pick: AgentPick, from previous: Stage?) -> Bool {
        guard let previous else { return true }
        return pick.backend.id != previous.backend.id
            || pick.model != previous.model
            || pick.effort != previous.effort
    }

    private static func pickRefine(_ agents: [AgentBackend]) -> AgentPick? {
        let cheap = agents.first { agent in
            guard let model = WorkflowModelPick.cheapestModel(backend: agent.id, models: agent.models) else {
                return false
            }
            return WorkflowModelPick.cheapMarkers.contains { model.lowercased().contains($0) }
        } ?? agents.first
        guard let agent = cheap else { return nil }
        return AgentPick(
            backend: agent,
            model: WorkflowModelPick.cheapestModel(backend: agent.id, models: agent.models),
            effort: WorkflowModelPick.lowestEffort(agent.efforts)
        )
    }

    private static func pickPlan(_ agents: [AgentBackend], refine: AgentPick) -> AgentPick? {
        let preferred = agents.first { $0.id == "grok" }
            ?? agents.first { WorkflowModelPick.highestEffort($0.efforts) != nil && $0.id != refine.backend.id }
            ?? refine.backend
        let model: String?
        if preferred.id == refine.backend.id {
            model = WorkflowModelPick.midModel(models: preferred.models, excluding: refine.model)
                ?? refine.model
        } else {
            model = preferred.models.first
        }
        return AgentPick(
            backend: preferred,
            model: model,
            effort: WorkflowModelPick.highestEffort(preferred.efforts)
        )
    }

    private static func pickBuild(_ agents: [AgentBackend], used: [String]) -> AgentPick? {
        let order = ["opencode", "opencode2", "cursor", "codex", "agy"]
        let agent = order.compactMap { id in agents.first { $0.id == id } }.first
            ?? agents.first { !used.contains($0.id) }
        guard let agent, !used.contains(agent.id) else { return nil }
        let mid = WorkflowModelPick.midModel(models: agent.models, excluding: nil)
        return AgentPick(
            backend: agent,
            model: mid ?? agent.models.first,
            effort: WorkflowModelPick.highestEffort(agent.efforts).flatMap { high in
                agent.efforts.first { $0.caseInsensitiveCompare("medium") == .orderedSame } ?? high
            }
        )
    }

    private static func pickReview(_ agents: [AgentBackend]) -> AgentPick? {
        if let withOpus = agents.first(where: { WorkflowModelPick.reviewModel(models: $0.models) != nil }) {
            return AgentPick(
                backend: withOpus,
                model: WorkflowModelPick.reviewModel(models: withOpus.models),
                effort: WorkflowModelPick.highestEffort(withOpus.efforts)
            )
        }
        return nil
    }
}

/// Example pipelines. Tapping one fills the Design field.
///
/// These used to be their own arrow sentence, `Start → Refine Claude haiku low
/// → Plan Grok grok-4.6 high → …`, which is the shape of the pipeline written
/// out as text you have to parse. Two of them side by side were a wall. The
/// name says what it is for and the strip says what it does.
struct WorkflowRecipeChips: View {
    let recipes: [WorkflowRecipe]
    var onPick: (WorkflowRecipe) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            ForEach(recipes) { recipe in
                Button { onPick(recipe) } label: {
                    HStack(spacing: Theme.Space.m) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(recipe.name)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.primary)
                            MiniGraph(nodes: recipe.nodes, edges: recipe.edges, dot: 20)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, Theme.Space.s)
                    .padding(.vertical, Theme.Space.s)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.panel, in: RoundedRectangle(cornerRadius: Theme.Space.s))
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.Space.s)
                            .strokeBorder(Theme.border)
                    )
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .help(recipe.label)
                .accessibilityLabel("\(recipe.name). \(recipe.label)")
            }
        }
    }
}

/// Agent, model, effort, folder. Same controls as Automations and Tasks.
struct WorkflowDesignPickers: View {
    let agents: [AgentBackend]
    let folders: [WorkspaceFolder]
    @Binding var backendID: String
    @Binding var modelID: String
    @Binding var effort: String
    @Binding var workspaceID: String

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack(alignment: .bottom, spacing: Theme.Space.s) {
                if !agents.isEmpty {
                    AppMenuPicker(
                        title: "Agent",
                        options: agents.map { (value: $0.id, label: $0.label) },
                        selection: $backendID
                    )
                }
                if folders.count > 1 {
                    AppMenuPicker(
                        title: "Folder",
                        options: [(value: "", label: "No folder")]
                            + folders.map { (value: $0.id, label: $0.name) },
                        selection: $workspaceID
                    )
                }
            }
            if let backend = selected {
                if !backend.models.isEmpty {
                    FavoriteModelPicker(
                        backendID: backend.id,
                        models: backend.models,
                        extra: modelID,
                        selection: $modelID
                    )
                }
                if !backend.efforts.isEmpty {
                    AppMenuPicker(
                        title: "Effort",
                        options: [(value: "", label: "Default")]
                            + backend.efforts.map { (value: $0, label: $0) },
                        selection: $effort
                    )
                }
            }
        }
        .onAppear {
            syncBackend()
            applyCheapDefaults()
        }
        .onChange(of: backendID) { old, new in
            if old != new { applyCheapDefaults() }
        }
        .onChange(of: agents.map(\.id).joined(separator: ",")) { _, _ in
            let before = backendID
            syncBackend()
            if backendID != before { applyCheapDefaults() }
        }
    }

    private var selected: AgentBackend? {
        agents.first { $0.id == backendID } ?? agents.first
    }

    private func syncBackend() {
        if backendID.isEmpty || !agents.contains(where: { $0.id == backendID }) {
            backendID = agents.first?.id ?? ""
        }
    }

    private func applyCheapDefaults() {
        guard let backend = selected else {
            modelID = ""
            effort = ""
            return
        }
        modelID = WorkflowModelPick.cheapestModel(backend: backend.id, models: backend.models) ?? ""
        effort = WorkflowModelPick.lowestEffort(backend.efforts) ?? ""
    }
}
