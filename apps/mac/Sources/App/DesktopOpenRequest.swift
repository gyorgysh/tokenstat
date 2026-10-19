// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
#if os(macOS)
import Foundation

/// Explicit, workspace-owned desktop navigation. Links accept no command text.
struct DesktopOpenRequest: Equatable {
    enum InspectorTab: String { case files, changes, history }
    let tool: DesktopWorkbenchState.Tool
    let workspaceID: String
    let inspectorTab: InspectorTab?
    let browserURL: URL?
    let sessionID: String?
    let newTerminal: Bool
    let commitID: String?

    init?(url: URL) {
        guard url.absoluteString.count <= 16384, url.user == nil, url.password == nil, url.port == nil, url.fragment == nil,
              url.scheme?.lowercased() == "tokenstat", url.host == "workbench", url.path == "/open",
              let parts = URLComponents(url: url, resolvingAgainstBaseURL: false), let items = parts.queryItems else { return nil }
        var query: [String: String] = [:]
        for item in items {
            guard query[item.name] == nil, let value = item.value else { return nil }
            query[item.name] = value
        }
        guard let workspace = query["workspace"], Self.validID(workspace),
              let name = query["tool"], let tool = DesktopWorkbenchState.Tool(rawValue: name) else { return nil }
        let extras: Set<String>
        switch tool {
        case .inspector: extras = ["tab"]
        case .browser: extras = ["url"]
        case .terminal: extras = ["session", "new"]
        case .changes: extras = ["commit"]
        default: extras = []
        }
        guard query.keys.allSatisfy({ ["tool", "workspace"].contains($0) || extras.contains($0) }) else { return nil }
        var tab: InspectorTab?
        if let value = query["tab"] { guard let parsed = InspectorTab(rawValue: value) else { return nil }; tab = parsed }
        var browser: URL?
        if let value = query["url"] {
            guard value.count <= 8192, let parsed = URL(string: value), ["http", "https"].contains(parsed.scheme?.lowercased() ?? ""),
                  let host = parsed.host, !host.isEmpty, parsed.user == nil, parsed.password == nil else { return nil }
            browser = parsed
        }
        if let session = query["session"], !Self.validID(session) { return nil }
        if let spawn = query["new"], spawn != "1" || query["session"] != nil { return nil }
        if let commit = query["commit"], ![40, 64].contains(commit.utf8.count) || !commit.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }) { return nil }
        self.tool = tool; workspaceID = workspace; inspectorTab = tab; browserURL = browser
        sessionID = query["session"]; newTerminal = query["new"] == "1"
        commitID = query["commit"]
    }
    private static func validID(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 512 && value.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || [45, 46, 58, 95].contains($0)
        }
    }
}

struct DesktopTerminalIntent: Equatable {
    let id = UUID()
    let sessionID: String?
    let newTerminal: Bool
}
#endif
