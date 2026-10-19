// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
#if os(macOS)
import SwiftUI

extension DesktopWorkbenchState.Tool {
    var title: String {
        switch self {
        case .changes: WorkspaceSection.changes.label
        case .browser: L10n.text("common.browser")
        case .terminal: L10n.text("apple.chatterminalpane.terminal.e0926fda")
        case .inspector: L10n.text("apple.workbench.inspector")
        case .simulator: L10n.text("apple.simulator.title")
        }
    }

    var symbol: String {
        switch self {
        case .changes: ActionIcon.compare.symbol
        case .browser: ActionIcon.browser.symbol
        case .terminal: "terminal"
        case .inspector: "sidebar.trailing"
        case .simulator: "iphone"
        }
    }
}

/// A horizontally scrollable strip keeps tools usable at the narrowest width.
struct DesktopWorkbenchBar: View {
    let state: DesktopWorkbenchState
    let open: (DesktopWorkbenchState.Tool) -> Void
    let close: (DesktopWorkbenchState.Tool) -> Void
    let hide: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            ScrollViewReader { scroll in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(state.tabs) { tool in
                            HStack(spacing: 2) {
                                Button { open(tool) } label: {
                                    Label(tool.title, systemImage: tool.symbol)
                                        .font(Theme.font(12, weight: state.selected == tool ? .semibold : .regular))
                                        .lineLimit(1)
                                        .padding(.leading, 9).padding(.trailing, 4).padding(.vertical, 9)
                                }
                                .buttonStyle(.plain)
                                .accessibilityAddTraits(state.selected == tool ? [.isSelected] : [])
                                ToolbarIconButton(systemImage: ActionIcon.dismiss.symbol,
                                    help: L10n.text("apple.workbench.close_tool", tool.title)) { close(tool) }
                            }
                            .foregroundStyle(state.selected == tool ? Theme.accent : Theme.controlGlyph)
                            .background(state.selected == tool ? Theme.accentSoft : .clear,
                                        in: RoundedRectangle(cornerRadius: 8))
                            .id(tool)
                        }
                    }
                }
                .onChange(of: state.selected, initial: true) { _, tool in
                    if let tool { scroll.scrollTo(tool, anchor: .trailing) }
                }
            }
            Menu {
                ForEach(DesktopWorkbenchState.Tool.allCases) { tool in
                    Button { open(tool) } label: { Label(tool.title, systemImage: tool.symbol) }
                }
            } label: {
                Image(systemName: ActionIcon.create.symbol).frame(width: 30, height: 30)
            }
            .menuStyle(.borderlessButton).fixedSize()
            .help(L10n.text("apple.workbench.add_tool"))
            .accessibilityLabel(L10n.text("apple.workbench.add_tool"))
            ToolbarIconButton(systemImage: "sidebar.trailing",
                              help: L10n.text("apple.workbench.hide"), action: hide)
        }
        .padding(6)
        .background(Theme.sidebar)
        .overlay(alignment: .bottom) { ThemeRule() }
    }
}
#endif
