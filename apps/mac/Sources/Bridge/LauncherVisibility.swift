// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available: source sharing and own builds are permitted.
// Store and commercial distribution of builds is reserved. See LICENSE.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

import Foundation
import Observation

@MainActor
@Observable
final class LauncherVisibility {
    static let shared = LauncherVisibility()

    private static let defaultsPrefix = "launcher.hidden."

    private var hidden: [String: Set<String>] = [:]

    private init() {}

    func isHidden(_ id: String, scope: String) -> Bool {
        ids(for: scope).contains(id)
    }

    func hide(_ id: String, scope: String) {
        var set = ids(for: scope)
        guard set.insert(id).inserted else { return }
        hidden[scope] = set
        persist(set, scope: scope)
    }

    func show(_ id: String, scope: String) {
        var set = ids(for: scope)
        guard set.remove(id) != nil else { return }
        hidden[scope] = set
        persist(set, scope: scope)
    }

    func replace(_ ids: Set<String>, scope: String) {
        hidden[scope] = ids
        persist(ids, scope: scope)
    }

    func ids(for scope: String) -> Set<String> {
        hidden[scope] ?? Set(UserDefaults.standard.stringArray(forKey: Self.key(scope)) ?? [])
    }

    private func persist(_ set: Set<String>, scope: String) {
        UserDefaults.standard.set(Array(set).sorted(), forKey: Self.key(scope))
    }

    private static func key(_ scope: String) -> String {
        defaultsPrefix + scope
    }
}

extension AgentBackend {
    var launcherIDs: [String] {
        switch id {
        case "sh": return ["shell"]
        case "claude": return ["claude_code"]
        case "codex": return ["codex"]
        case "grok": return ["grok"]
        case "cursor": return ["cursor", "cursor_agent"]
        case "agy": return ["antigravity"]
        case "opencode": return ["opencode"]
        case "opencode2": return ["opencode2"]
        default: return [id]
        }
    }

    @MainActor
    func isHiddenFromLaunchers(scope: String = "local") -> Bool {
        let ids = launcherIDs
        guard !ids.isEmpty else { return false }
        return ids.allSatisfy { LauncherVisibility.shared.isHidden($0, scope: scope) }
    }
}

extension [AgentBackend] {
    @MainActor
    func visibleForPicker(keeping id: String? = nil, scope: String = "local") -> [AgentBackend] {
        var out = filter { !$0.isHiddenFromLaunchers(scope: scope) }
        if let id, !id.isEmpty, !out.contains(where: { $0.id == id }),
           let extra = first(where: { $0.id == id }) {
            out.append(extra)
        }
        if let at = out.firstIndex(where: { $0.id == "sh" }) {
            out.append(out.remove(at: at))
        }
        return out
    }

    @MainActor
    func defaultForPicker(keeping id: String? = nil, scope: String = "local") -> AgentBackend? {
        let out = visibleForPicker(keeping: id, scope: scope)
        return out.first { $0.id != "sh" } ?? out.first
    }
}
