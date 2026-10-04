// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
// Compile with SidebarPreferences.swift.
import Foundation

@main
struct SidebarPreferencesTests {
    static func main() {
        let suite = "tokenstat-sidebar-tests-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = SidebarPreferences(defaults: defaults)
        precondition(preferences.sectionOrder == ["projects", "servers"])
        precondition(preferences.isExpanded("project:new", default: true))
        precondition(!preferences.isExpanded("server:new", default: false))
        defaults.set(350.0, forKey: "shell.sidebarWidth")
        preferences.rememberExpansion("project:local", expanded: false)
        preferences.rememberExpansion("project:peer:remote", expanded: true)
        preferences.rememberExpansion("history:local", expanded: true)
        preferences.rememberExpansion("server:one", expanded: true)
        preferences.rememberExpansion("section:projects", expanded: false)
        preferences.move("servers", before: "projects")
        let reopened = SidebarPreferences(defaults: UserDefaults(suiteName: suite)!)
        precondition(!reopened.isExpanded("project:local", default: true), "Explicit collapse must survive reopening")
        precondition(reopened.isExpanded("project:peer:remote", default: false), "Disconnected peers must retain their choice")
        precondition(reopened.expandedIDs("history:") == ["local"])
        precondition(reopened.expandedIDs("server:") == ["one"])
        precondition(!reopened.isExpanded("section:projects", default: true))
        precondition(reopened.sectionOrder == ["servers", "projects"])
        precondition(defaults.double(forKey: "shell.sidebarWidth") == 350, "Existing settings must remain independent")

        // Newer releases may add sections and values this release cannot read.
        let future: [String: Any] = ["layout": ["version": 8]]
        defaults.set(["future", future, "servers", "servers", "projects", 7], forKey: "shell.sidebar.sectionOrder")
        defaults.set(future, forKey: "shell.sidebar.expanded.future:row")
        defaults.set(1, forKey: "shell.sidebar.expanded.project:number")
        defaults.set("open", forKey: "shell.sidebar.expanded.project:string")
        precondition(!reopened.isExpanded("project:number", default: false), "Only booleans are disclosure choices")
        precondition(reopened.isExpanded("project:string", default: true), "Unsupported values need per-row defaults")
        precondition(reopened.sectionOrder == ["servers", "projects"], "Unknown and repeated sections must not render")
        reopened.move("projects", before: "servers")
        reopened.rememberExpansion("project:local", expanded: true)
        let raw = defaults.array(forKey: "shell.sidebar.sectionOrder")!
        precondition(raw.contains { ($0 as? String) == "future" })
        precondition(raw.contains { ($0 as? NSDictionary) == future as NSDictionary })
        precondition((defaults.object(forKey: "shell.sidebar.expanded.future:row") as? NSDictionary) == future as NSDictionary)
        precondition(reopened.sectionOrder == ["projects", "servers"])

        defaults.set(["future"], forKey: "shell.sidebar.sectionOrder")
        precondition(reopened.sectionOrder == ["projects", "servers"], "Missing known sections need stable defaults")
        defaults.set("unrecognized", forKey: "shell.sidebar.sectionOrder")
        precondition(reopened.sectionOrder == ["projects", "servers"], "Malformed order must not block launch")
        print("Sidebar preferences passed")
    }
}
