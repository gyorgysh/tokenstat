// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

#if os(macOS)
import AppKit
import SwiftUI

/// Sizes the desktop shell is built from.
///
/// The left chrome is two columns on one surface: a rail of machine-wide
/// places, and the sidebar of projects beside it. The rail never collapses,
/// so the places it holds are always one click away and hiding the sidebar
/// gives the room back without taking the way home with it.
enum ShellMetrics {
    /// The rail's own width. Wide enough that the window's traffic lights sit
    /// inside the left surface rather than hanging over the content column
    /// when the sidebar is hidden.
    static let railWidth: CGFloat = 64
    /// Gap between the floating glass panel and the window edges. Zero where
    /// the panel is flat and runs edge to edge.
    static var panelInset: CGFloat { usesGlass ? 6 : 0 }
    /// Corner radius of the floating panel.
    static let panelRadius: CGFloat = 16
    /// The band the traffic lights sit in. The shell's titlebar is hidden and
    /// empty, so this is the only thing above the first row of chrome.
    static let titleBand: CGFloat = 28

    /// The sidebar's resizable range and its first width.
    static let sidebarRange: ClosedRange<Double> = 220...440
    static let sidebarDefault: Double = 272
    /// The inspector's resizable range and its first width.
    static let inspectorRange: ClosedRange<Double> = 300...640
    static let inspectorDefault: Double = 400

    /// Liquid Glass exists from macOS 26. Below that the left chrome keeps the
    /// flat sidebar colour it has always had: the `.bar` material flashed white
    /// when the columns re-laid out, and a flat colour cannot.
    static var usesGlass: Bool {
        if #available(macOS 26, *) { return true }
        return false
    }
}

extension View {
    /// The left chrome's surface: a floating Liquid Glass panel on macOS 26
    /// and later, the flat sidebar colour before that.
    ///
    /// Chrome only. `Theme` keeps the rule that content sits on flat colour,
    /// because vibrancy pulls whatever is behind the window into columns of
    /// digits. A list of project names and a rail of glyphs is chrome.
    ///
    /// The sidebar colour sits inside the glass as well as tinting it. A tint
    /// alone is dropped when the window is not key, and the panel turned the
    /// system's neutral grey beside violet content; with the colour laid in,
    /// an inactive window keeps its palette and an active one gains the rim
    /// and depth of the glass over it.
    @ViewBuilder
    func leftChromeSurface() -> some View {
        if #available(macOS 26, *) {
            self
                .background(Theme.sidebar.opacity(0.75), in: .rect(cornerRadius: ShellMetrics.panelRadius))
                .clipShape(.rect(cornerRadius: ShellMetrics.panelRadius))
                .glassEffect(
                    .regular.tint(Theme.sidebar.opacity(0.5)),
                    in: .rect(cornerRadius: ShellMetrics.panelRadius)
                )
                .padding([.leading, .top, .bottom], ShellMetrics.panelInset)
        } else {
            self.background(Theme.sidebar)
        }
    }
}

/// The sidebar floated over the content on a window too narrow for the
/// column: the same glass as the docked panel, with a hairline and the flat
/// colour where glass does not exist.
struct FloatingSidebarSurface: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26, *) {
            content
                .background(Theme.sidebar.opacity(0.85), in: .rect(cornerRadius: ShellMetrics.panelRadius))
                .clipShape(.rect(cornerRadius: ShellMetrics.panelRadius))
                .glassEffect(
                    .regular.tint(Theme.sidebar.opacity(0.5)),
                    in: .rect(cornerRadius: ShellMetrics.panelRadius)
                )
                .padding(.vertical, ShellMetrics.panelInset)
        } else {
            content
                .background(Theme.sidebar)
                .overlay(alignment: .trailing) {
                    Rectangle().fill(Theme.border).frame(width: 1)
                }
        }
    }
}

/// A machine-wide place on the rail.
///
/// The rail is the answer to "where in the app am I". Projects are one of
/// those places, and every folder route lights it, so the rail always has
/// one lit mark and the sidebar says which project.
enum RailPlace: String, CaseIterable, Identifiable, Hashable {
    case home
    case projects
    case tasks
    case notes
    case automations
    case insights
    case devices
    case ssh

    var id: String { rawValue }

    var label: String {
        switch self {
        case .home: return "Home"
        case .projects: return "Workspaces"
        case .tasks: return "Tasks"
        case .notes: return "Notes"
        case .automations: return "Automations"
        case .insights: return "Insights"
        case .devices: return "Devices"
        case .ssh: return "SSH"
        }
    }

    var symbol: String {
        switch self {
        case .home: return "house"
        case .projects: return "folder"
        case .tasks: return "checklist"
        case .notes: return "note.text"
        case .automations: return "bolt"
        case .insights: return "chart.bar.xaxis"
        case .devices: return "laptopcomputer"
        case .ssh: return "terminal"
        }
    }

    /// Which place a route belongs to. Workflows live with Automations: both
    /// are work that runs without anybody at the keyboard, and one place for
    /// that is easier to find than two.
    static func of(_ route: Route) -> RailPlace? {
        switch route {
        case let .global(section):
            switch section {
            case .home: return .home
            case .insights: return .insights
            case .machines: return .devices
            case .todo: return .tasks
            case .notes: return .notes
            case .workflows, .automations: return .automations
            case .account: return nil
            }
        case .workspace, .workspacesOverview: return .projects
        case .ssh, .sshTerminals: return .ssh
        }
    }
}

/// One mark on the rail: a glyph in a rounded seat, its name on hover.
struct RailButton: View {
    let place: RailPlace
    let isSelected: Bool
    /// A small count or state dot in the corner, when the place has news.
    var badge: Bool = false
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: place.symbol)
                .font(Theme.fixed(16, weight: isSelected ? .semibold : .regular))
                .symbolVariant(isSelected ? .fill : .none)
                .foregroundStyle(isSelected ? Theme.accent : (isHovering ? Theme.controlGlyphHover : Theme.controlGlyph))
                .frame(width: 40, height: 36)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(isSelected ? Theme.rowSelected : (isHovering ? Theme.rowHighlight.opacity(0.7) : .clear))
                )
                .overlay(alignment: .topTrailing) {
                    if badge {
                        Circle()
                            .fill(Theme.accent)
                            .frame(width: 7, height: 7)
                            .offset(x: -5, y: 5)
                    }
                }
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(place.label)
        .accessibilityLabel(place.label)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// A draggable edge between two columns.
///
/// Wide enough to grab, drawn as a hairline, and it writes the stored width
/// only when the drag ends: a preference written on every frame is a defaults
/// write per frame, and a width read back mid-gesture fights the pointer.
struct ColumnResizeHandle: View {
    /// Which side of the handle the resized column is on. A sidebar grows
    /// when the pointer moves right, an inspector when it moves left.
    enum Side { case leading, trailing }

    let side: Side
    /// The committed width.
    @Binding var width: Double
    /// The width while a drag is in flight, or nil at rest.
    @Binding var liveWidth: Double?
    let range: ClosedRange<Double>
    var showsLine: Bool = true
    var help: String = "Drag to resize"

    @State private var start: Double?
    @State private var cursorPushed = false

    var body: some View {
        ZStack {
            if showsLine {
                Rectangle().fill(Theme.border).frame(width: 1)
            }
        }
        .frame(width: 7)
        .frame(maxHeight: .infinity)
        .contentShape(.rect)
        .onHover { hovering in
            if hovering, !cursorPushed {
                NSCursor.resizeLeftRight.push()
                cursorPushed = true
            } else if !hovering, cursorPushed, start == nil {
                NSCursor.pop()
                cursorPushed = false
            }
        }
        .gesture(
            DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { value in
                    let origin = start ?? (liveWidth ?? width)
                    if start == nil { start = origin }
                    let delta = side == .leading ? value.translation.width : -value.translation.width
                    liveWidth = min(range.upperBound, max(range.lowerBound, origin + delta))
                }
                .onEnded { _ in
                    if let liveWidth { width = liveWidth }
                    liveWidth = nil
                    start = nil
                }
        )
        // Double-click puts the column back where it started.
        .onTapGesture(count: 2) {
            width = side == .leading ? ShellMetrics.sidebarDefault : ShellMetrics.inspectorDefault
        }
        .onDisappear {
            if cursorPushed { NSCursor.pop(); cursorPushed = false }
            liveWidth = nil
            start = nil
        }
        .help(help)
        .accessibilityElement()
        .accessibilityLabel(help)
        .accessibilityAdjustableAction { direction in
            let step: Double = direction == .increment ? 20 : -20
            width = min(range.upperBound, max(range.lowerBound, width + step))
        }
    }
}
#endif

#if os(macOS)
/// A project's name and branch, then its sections, in the content bar.
///
/// The sections used to be ten rows repeated under every folder in the
/// sidebar. Here they are one strip over the thing they switch, the way a
/// repository's tabs sit over the repository, and the sidebar is left with
/// the chats and sessions people actually open.
struct ProjectHeader: View {
    let folder: WorkspaceFolder
    let selected: WorkspaceSection?
    /// Present when the branch can be switched from here.
    var branch: AnyView?
    /// What each section holds, where that is worth a number.
    var count: (WorkspaceSection) -> Int? = { _ in nil }
    let select: (WorkspaceSection) -> Void

    /// In reading order. History is the inspector's on the Mac, and the
    /// browser is the globe beside the inspector toggle.
    static let sections: [WorkspaceSection] = [
        .chat, .sessions, .changes, .files, .pulls, .todo, .notes, .automations, .workflows,
    ]
    /// How many sections keep their names when the bar gets tight.
    private static let primary = 5

    var body: some View {
        HStack(spacing: Theme.Space.s) {
            title
            if let branch {
                branch.fixedSize()
            }
            Rectangle()
                .fill(Theme.border)
                .frame(width: 1, height: 16)
                .padding(.horizontal, 2)
            // Names for the five everyday sections survive the middle width.
            ChromeTabStrip(tabs: tabs, selected: selected?.rawValue, primary: Self.primary) { id in
                if let section = WorkspaceSection(rawValue: id) { select(section) }
            }
        }
    }

    private var title: some View {
        HStack(spacing: 6) {
            Image(systemName: folder.isRemote ? "network" : "folder.fill")
                .font(Theme.fixed(11, weight: .semibold))
                .foregroundStyle(Theme.accent)
            Text(folder.isRemote ? "\(folder.machineLabel ?? "Remote") / \(folder.name)" : folder.name)
                .font(Theme.fit(13, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .frame(maxWidth: 220, alignment: .leading)
        .fixedSize(horizontal: true, vertical: false)
        .help(folder.isRemote ? "\(folder.machineLabel ?? "Remote machine") · \(folder.path)" : folder.path)
    }

    private var tabs: [ChromeTab] {
        Self.sections.map { ChromeTab(id: $0.rawValue, label: $0.label, symbol: $0.symbol, count: count($0)) }
    }
}

/// One tab in a content bar's strip.
struct ChromeTab: Identifiable, Hashable {
    let id: String
    let label: String
    let symbol: String
    /// Drawn after the name when there is one. Nil draws nothing: a zero is
    /// not news.
    var count: Int? = nil
}

/// The sections of whatever the bar is showing, as tabs.
///
/// Gives way in steps as the bar narrows: counts go first, then the names of
/// all but the first few, then every name but the one on screen. The tab you
/// are on always says what it is, and every glyph keeps its name on hover.
/// One component for a project's sections, the SSH library's and the
/// automations place, so they read as the same control wherever they appear.
struct ChromeTabStrip: View {
    let tabs: [ChromeTab]
    let selected: String?
    /// How many tabs keep their names at the middle width.
    var primary: Int = 3
    let select: (String) -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            strip(counts: true) { _, _ in true }
            strip(counts: false) { _, _ in true }
            strip(counts: false) { index, isSelected in isSelected || index < primary }
            strip(counts: false) { _, isSelected in isSelected }
        }
    }

    private func strip(counts: Bool, labelled: @escaping (Int, Bool) -> Bool) -> some View {
        HStack(spacing: 2) {
            ForEach(Array(tabs.enumerated()), id: \.element) { index, tab in
                let isSelected = tab.id == selected
                ChromeTabButton(
                    tab: tab,
                    isSelected: isSelected,
                    showsLabel: labelled(index, isSelected),
                    showsCount: counts
                ) { select(tab.id) }
            }
        }
        .fixedSize()
    }
}

/// One tab: glyph and name in a soft capsule, lit when it is on screen.
struct ChromeTabButton: View {
    let tab: ChromeTab
    let isSelected: Bool
    let showsLabel: Bool
    var showsCount: Bool = true
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: tab.symbol)
                    .font(Theme.fixed(11, weight: .medium))
                if showsLabel {
                    Text(tab.label)
                        .font(Theme.fit(12, weight: isSelected ? .semibold : .medium))
                        .lineLimit(1)
                    if showsCount, let count = tab.count {
                        Text("\(count)")
                            .font(Theme.numeric(11))
                            .foregroundStyle(isSelected ? AnyShapeStyle(Theme.accent.opacity(0.75)) : AnyShapeStyle(.tertiary))
                    }
                }
            }
            .foregroundStyle(isSelected ? Theme.accent : (isHovering ? Theme.controlGlyphHover : Theme.controlGlyph))
            .padding(.horizontal, showsLabel ? 9 : 7)
            .frame(height: 26)
            .background(
                Capsule().fill(isSelected ? Theme.rowSelected : (isHovering ? Theme.rowHighlight.opacity(0.7) : .clear))
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(tab.count.map { "\(tab.label), \($0)" } ?? tab.label)
        .accessibilityLabel(tab.count.map { "\(tab.label), \($0)" } ?? tab.label)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
#endif
