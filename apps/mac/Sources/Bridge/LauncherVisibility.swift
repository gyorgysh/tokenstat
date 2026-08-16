// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

import Foundation
import Observation

/// Which launcher tiles the user has taken off the main grid.
///
/// This is display only. The binary stays on the machine. A hidden installed
/// profile moves under the + row and can be shown again without running an
/// installer. The set is per owning machine so hiding Codex on a remote host
/// does not hide it on this one.
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

    /// Cached after the first write. Reads fall back to defaults so a view
    /// body never mutates this object.
    private func ids(for scope: String) -> Set<String> {
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
    /// Workspace launcher tiles that stand for this automation backend.
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

    /// Hidden only when every matching tile is hidden. Cursor has two tiles.
    @MainActor
    func isHiddenFromLaunchers(scope: String = "local") -> Bool {
        let ids = launcherIDs
        guard !ids.isEmpty else { return false }
        return ids.allSatisfy { LauncherVisibility.shared.isHidden($0, scope: scope) }
    }
}

extension [AgentBackend] {
    /// Picker list: hidden tiles stay out, unless this card or job already uses one.
    @MainActor
    func visibleForPicker(keeping id: String? = nil, scope: String = "local") -> [AgentBackend] {
        var out = filter { !$0.isHiddenFromLaunchers(scope: scope) }
        if let id, !id.isEmpty, !out.contains(where: { $0.id == id }),
           let extra = first(where: { $0.id == id }) {
            out.append(extra)
        }
        return out
    }
}
