// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import Foundation

/// Cheap / low defaults used by Design and by the example recipes.
///
/// Keep the markers in step with `tokenstat-host::agent_models`. The Mac
/// cannot call that crate, so the same rules live here.
enum WorkflowModelPick {
    /// Prefer a fresh implementation agent, but never omit the build step
    /// merely because the available backend also planned the work.
    static func buildAgent(from agents: [AgentBackend], used: [String]) -> AgentBackend? {
        let preferred = ["opencode", "opencode2", "cursor", "codex", "agy"]
            .compactMap { id in agents.first { $0.id == id } }
        return preferred.first { !used.contains($0.id) }
            ?? agents.first { !used.contains($0.id) }
            ?? preferred.first
            ?? agents.first
    }

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
