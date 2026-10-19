// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

/// Tool selection belongs to the workspace, independently of chat navigation.
struct DesktopWorkbenchState: Equatable {
    enum Tool: String, CaseIterable, Identifiable {
        case changes, browser, terminal, inspector
        var id: String { rawValue }
    }

    private(set) var tabs: [Tool] = []
    private(set) var selected: Tool?
    private(set) var isPresented = false

    mutating func open(_ tool: Tool) {
        if !tabs.contains(tool) { tabs.append(tool) }
        selected = tool
        isPresented = true
    }

    mutating func close(_ tool: Tool) {
        guard let index = tabs.firstIndex(of: tool) else { return }
        tabs.remove(at: index)
        if selected == tool { selected = tabs.isEmpty ? nil : tabs[max(0, index - 1)] }
        if tabs.isEmpty { isPresented = false }
    }

    /// Hiding the workbench preserves its tabs and their native surfaces.
    mutating func hide() { isPresented = false }
}

/// Visibility and the selected tool follow the window's chat navigation.
/// Each project keeps its own open tabs and review/browser/terminal contents.
struct DesktopWorkbenchSession {
    private var workspaces: [String: DesktopWorkbenchState] = [:]
    private(set) var isPresented = false
    private(set) var preferredTool: DesktopWorkbenchState.Tool = .inspector

    func state(in workspace: String) -> DesktopWorkbenchState {
        var state = workspaces[workspace] ?? DesktopWorkbenchState()
        if isPresented { state.open(preferredTool) }
        else { state.hide() }
        return state
    }

    mutating func open(_ tool: DesktopWorkbenchState.Tool, in workspace: String) {
        var state = state(in: workspace)
        state.open(tool)
        workspaces[workspace] = state
        preferredTool = tool
        isPresented = true
    }

    mutating func close(_ tool: DesktopWorkbenchState.Tool, in workspace: String) {
        var state = state(in: workspace)
        state.close(tool)
        workspaces[workspace] = state
        if let selected = state.selected { preferredTool = selected }
        isPresented = state.isPresented
    }

    mutating func hide() { isPresented = false }
    mutating func retain(workspaces ids: Set<String>) { workspaces = workspaces.filter { ids.contains($0.key) } }
}

/// Chat needs reading room beside review, including on laptop-sized windows.
enum DesktopWorkbenchLayout {
    static let detailMinimum = 480.0
    static let toolMinimum = 320.0
    static let divider = 5.0

    static func fitsBeside(available: Double) -> Bool {
        available >= detailMinimum + divider + toolMinimum
    }

    static func sidebarFits(width: Double, rail: Double, sidebar: Double, preferredTool: Double) -> Bool {
        width >= rail + sidebar + detailMinimum + divider + max(toolMinimum, preferredTool)
    }
}
