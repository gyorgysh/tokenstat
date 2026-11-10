// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

// Original SidebarPreferences and RootView disclosure setters run only against
// this private in-memory adapter, never a real UserDefaults domain or host.
import Foundation
import CoreFoundation

enum SidebarReference {
    final class Defaults {
        static let standard = Defaults()
        var values: [String:Any] = [:]
        func object(forKey key: String) -> Any? { values[key] }
        func array(forKey key: String) -> [Any]? { values[key] as? [Any] }
        func dictionaryRepresentation() -> [String:Any] { values }
        func set(_ value: Any, forKey key: String) { values[key] = value }
    }
    /* SOURCE_PREFERENCES */
    final class Window {
        var expandedWorkspaces: Set<String> = []
        var knownSidebarProjects: Set<String> = []
        var expandedSidebarSections = Set(SidebarPreferences.defaultOrder.filter {
            SidebarPreferences.shared.isExpanded("section:" + $0, default:true)
        })
        /* SOURCE_SECTION_SETTER */
        /* SOURCE_PROJECT_SETTER */
        func directory(_ ids: [String]) {
            /* SOURCE_ARRIVAL */
            knownSidebarProjects = incoming
        }
        func project(_ id: String, _ expanded: Bool) { setProjectExpanded(id, expanded) }
        func section(_ expanded: Bool) { setSidebarSectionExpanded("projects", expanded) }
    }
    static let keys = ["section:projects", "section:servers", "project:a", "project:b", "project:c", "project:remote:peer:a", "project:é", "project:e\u{301}", "history:a", "server:one", "project:number", "future:row"]
    static let ids = ["a", "b", "c", "remote:peer:a", "é", "e\u{301}"]
    static let prefixes = ["project:", "history:", "server:", "section:", "future:"]
    static func state(_ windows: [Window]) -> [String:Any] {
        let preferences = SidebarPreferences.shared
        return ["raw":Defaults.standard.values,"order":preferences.sectionOrder,
            "expanded":keys.map { ["key":$0,"yes":preferences.isExpanded($0,default:true),"no":preferences.isExpanded($0,default:false)] as [String:Any] },
            "ids":prefixes.map { ["prefix":$0,"ids":preferences.expandedIDs($0).sorted()] as [String:Any] },
            "windows":windows.map { window in ["projects":window.expandedSidebarSections.contains("projects"),"rows":ids.map { ["id":$0,"expanded":window.expandedWorkspaces.contains($0)] as [String:Any] }] as [String:Any] }]
    }
    static func run(_ input: [String:Any]) -> [String:Any] {
        Defaults.standard.values = input["seed"] as! [String:Any]
        var windows: [Window] = []
        var rows = [state(windows)]
        for step in input["steps"] as! [[String:Any]] {
            let index = step["window"] as? Int ?? 0
            switch step["op"] as! String {
            case "open": windows.append(Window())
            case "directory": windows[index].directory(step["ids"] as! [String])
            case "project": windows[index].project(step["id"] as! String,step["expanded"] as! Bool)
            case "section": windows[index].section(step["expanded"] as! Bool)
            case "expansion": SidebarPreferences.shared.rememberExpansion(step["key"] as! String, expanded:step["expanded"] as! Bool)
            case "move": SidebarPreferences.shared.move(step["section"] as! String,before:step["before"] as! String)
            case "external": for (key,value) in step["values"] as! [String:Any] { Defaults.standard.values[key] = value }
            default: fatalError("Unknown sidebar fixture operation")
            }
            rows.append(state(windows))
        }
        return ["input":input,"rows":rows]
    }
    static func snapshot(_ input: [String:Any]) -> [String:Any] {
        ["cases":(input["cases"] as! [[String:Any]]).map { run($0["input"] as! [String:Any]) }]
    }
}
