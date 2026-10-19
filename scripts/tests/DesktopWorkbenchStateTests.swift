// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
// Compile with DesktopWorkbenchState.swift using swiftc -parse-as-library, then run.
import Foundation

@main
struct DesktopWorkbenchStateTests {
    static func main() {
        var workspaces: [String: DesktopWorkbenchState] = [:]
        for tool in DesktopWorkbenchState.Tool.allCases {
            workspaces["local", default: DesktopWorkbenchState()].open(tool)
        }
        workspaces["local"]?.open(.browser)
        precondition(workspaces["local"]?.tabs.count == 4, "Opening an existing tool selects its retained tab")
        workspaces["remote", default: DesktopWorkbenchState()].open(.changes)
        precondition(workspaces["local"]?.selected == .browser && workspaces["remote"]?.tabs == [.changes])
        workspaces["local"]?.hide()
        precondition(workspaces["local"]?.isPresented == false && workspaces["local"]?.tabs.count == 4)
        workspaces["local"]?.open(.browser)
        workspaces["local"]?.close(.terminal)
        precondition(workspaces["local"]?.selected == .browser, "Closing a background tab cannot change the active tool")
        workspaces["local"]?.close(.browser)
        precondition(workspaces["local"]?.selected == .changes, "Closing the active tab selects the preceding tool")
        workspaces["local"]?.close(.changes)
        precondition(workspaces["local"]?.selected == .inspector)
        workspaces["local"]?.close(.inspector)
        precondition(workspaces["local"]?.selected == nil && workspaces["local"]?.isPresented == false)
        workspaces["local"]?.close(.browser)
        workspaces["local"]?.open(.terminal)
        precondition(workspaces["local"]?.tabs == [.terminal] && workspaces["local"]?.isPresented == true)
        workspaces = [:]
        precondition(workspaces.isEmpty, "Changing account drops all workspace tool selections")
        var window = DesktopWorkbenchSession()
        window.open(.inspector, in: "first")
        precondition(window.state(in: "second").isPresented && window.state(in: "second").selected == .inspector,
                     "An open inspector follows chat navigation to another project")
        window.open(.browser, in: "second")
        precondition(window.state(in: "first").selected == .browser, "The chosen tool follows the chat")
        window.hide()
        precondition(!window.state(in: "first").isPresented && !window.state(in: "third").isPresented,
                     "An explicit hide must follow navigation too")
        window.open(.changes, in: "third")
        window.retain(workspaces: ["third"])
        precondition(window.state(in: "first").tabs == [.changes], "Removed projects cannot retain stale tabs")
        window.close(.changes, in: "third")
        precondition(!window.isPresented && !window.state(in: "second").isPresented)
        precondition(DesktopWorkbenchLayout.fitsBeside(available: 805))
        precondition(!DesktopWorkbenchLayout.fitsBeside(available: 804))
        precondition(DesktopWorkbenchLayout.sidebarFits(width: 1353, rail: 76, sidebar: 272, preferredTool: 520))
        precondition(!DesktopWorkbenchLayout.sidebarFits(width: 1352, rail: 76, sidebar: 272, preferredTool: 520))
        precondition(!DesktopWorkbenchLayout.sidebarFits(width: 1280, rail: 76, sidebar: 272, preferredTool: 520)
            && DesktopWorkbenchLayout.fitsBeside(available: 1280 - 76), "Laptop windows must retain a side-by-side conversation")
        print("DesktopWorkbenchStateTests passed")
    }
}
