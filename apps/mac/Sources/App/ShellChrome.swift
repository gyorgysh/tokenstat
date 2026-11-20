// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available: source sharing and own builds are permitted.
// Store and commercial distribution of builds is reserved. See LICENSE.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

#if os(macOS)
import AppKit
import SwiftUI
import Observation

/// Sizes the desktop shell is built from.
///
/// The left chrome is two columns on one surface: a rail of machine-wide
/// places, and the sidebar of projects beside it. The rail never collapses,
/// so the places it holds are always one click away and hiding the sidebar
/// gives the room back without taking the way home with it.
enum ShellMetrics {
    static let railWidth: CGFloat = 64
    /// Gap between the floating glass panel and the window edges. Zero where
    /// the panel is flat and runs edge to edge.
    static var panelInset: CGFloat { usesGlass ? 6 : 0 }
    static let panelRadius: CGFloat = 16
    /// How far a dragged column edge moves between re-layouts of the panes
    /// beside it. Small enough that a truncated title catches up at once,
    /// large enough that a drag is mostly moves rather than measurements.
    static let dragLayoutStep: CGFloat = 12
    /// The band the traffic lights sit in. The shell's titlebar is hidden and
    /// empty, so this is the only thing above the first row of chrome.
    static let titleBand: CGFloat = 28
    static var headerHeight: CGFloat { DetailChromeBarHeight + panelInset }

    static let sidebarRange: ClosedRange<Double> = 220...440
    static let sidebarDefault: Double = 272
    static let inspectorRange: ClosedRange<Double> = 300...640
    static let inspectorDefault: Double = 400

    /// Floating chrome starts on macOS 26. Its geometry stays the same when
    /// transparency is disabled, including during a full-screen transition.
    /// Below that it keeps the
    /// flat sidebar colour it has always had: the `.bar` material flashed white
    /// when the columns re-laid out, and a flat colour cannot.
    static var usesGlass: Bool {
        if #available(macOS 26, *) { return true }
        return false
    }
}

extension View {
    /// Preserve a hidden pane's native views without laying them out for every
    /// resize of the foreground screen. Its next activation adopts the current
    /// proposal before it becomes visible.
    func retainedPane(isActive: Bool) -> some View {
        RetainedPaneLayout(isActive: isActive) { self }
            .transformEnvironment(\.personaMotionAllowed) { $0 = $0 && isActive }
            // The bar's tabs and toggles are rebuilt on every shell update,
            // and every pane's bar read them, so a chat switch rebuilt and
            // measured about ten tab strips that nobody could see. A hidden
            // pane has no bar to show and now holds nothing that changes.
            .transformEnvironment(\.detailChromeToggles) { if !isActive { $0 = nil } }
            .transformEnvironment(\.desktopChromeJoined) { if !isActive { $0 = false } }
    }


}

/// A transparent titlebar region that delegates the original mouse-down to
/// AppKit. Window Server then owns the drag, including Space switching; the
/// decorative SwiftUI background never interprets it as a liquid interaction.
struct TitlebarDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> TitlebarDragView { TitlebarDragView() }
    func updateNSView(_ view: TitlebarDragView, context: Context) {}
}

final class TitlebarDragView: NSView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }
}

@available(macOS 26, *)
struct SidebarGlassSurface: View {
    let isFullScreen: Bool
    var cornerRadius: CGFloat = ShellMetrics.panelRadius
    @AppStorage(SidebarAppearancePreferences.enabledKey) private var enabled = true
    @AppStorage(SidebarAppearancePreferences.washKey) private var wash = SidebarAppearancePreferences.defaultWash
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        if !enabled || isFullScreen || reduceTransparency || SidebarAppearancePreferences.effective(wash) >= 1 {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).fill(Theme.sidebar)
        } else {
            // Keep native glass's depth and edge while the backing softens
            // background detail and this neutral wash protects row contrast.
            // Match the app's theme, even when it differs from macOS.
            SidebarBackdrop(cornerRadius: cornerRadius)
                .overlay {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill((colorScheme == .dark ? Color.black : Color.white)
                            .opacity(SidebarAppearancePreferences.effective(wash)))
                }
        }
    }
}

/// The frost and Liquid Glass are separate siblings, in that order. Putting
/// the visual effect inside the glass's content view would cover the glass.
@available(macOS 26, *)
private struct SidebarBackdrop: NSViewRepresentable {
    let cornerRadius: CGFloat

    func makeNSView(context: Context) -> FrostedGlassView {
        let view = FrostedGlassView(cornerRadius: cornerRadius)
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: FrostedGlassView, context: Context) {
        view.setTheme(dark: context.environment.colorScheme == .dark)
    }
}

@available(macOS 26, *)
private final class FrostedGlassView: NSView {
    private let glass = NSGlassEffectView()

    init(cornerRadius: CGFloat) {
        super.init(frame: .zero)
        let frost = NSVisualEffectView(frame: bounds)
        frost.material = .underWindowBackground
        frost.blendingMode = .behindWindow
        frost.state = .active
        // A full-strength legacy material flattens the native glass. Use it
        // only to soften detail; the glass and wash carry the appearance.
        frost.alphaValue = 0.35
        frost.maskImage = Self.mask(radius: cornerRadius)
        frost.autoresizingMask = [.width, .height]
        addSubview(frost)

        glass.frame = bounds
        glass.style = .clear
        glass.cornerRadius = cornerRadius
        glass.autoresizingMask = [.width, .height]
        addSubview(glass)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Honour the app's theme even when it differs from the system's.
    private var isDark: Bool?

    func setTheme(dark: Bool) {
        // Called on every SwiftUI update. Re-tinting live glass is not free.
        guard isDark != dark else { return }
        isDark = dark
        appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        glass.tintColor = (dark ? NSColor.black : NSColor.white).withAlphaComponent(0.15)
    }

    // This is a background. Sidebar controls own every pointer interaction.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// A stretchable continuous-corner mask keeps the behind-window frost
    /// inside the panel, including where its native glass edge is rounded.
    private static func mask(radius: CGFloat) -> NSImage {
        let cap = (radius * 1.6).rounded(.up)
        let edge = cap * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.setFillColor(NSColor.black.cgColor)
            context.addPath(RoundedRectangle(cornerRadius: radius, style: .continuous).path(in: rect).cgPath)
            context.fillPath()
            return true
        }
        image.capInsets = NSEdgeInsets(top: cap, left: cap, bottom: cap, right: cap)
        image.resizingMode = .stretch
        return image
    }
}

@available(macOS 26, *)
private struct SidebarPanelRim: View {
    var cornerRadius: CGFloat = ShellMetrics.panelRadius
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .strokeBorder(colorScheme == .dark ? Color.white.opacity(0.16) : Color.black.opacity(0.10), lineWidth: 1)
            .allowsHitTesting(false)
    }
}

/// The toolbar uses the same material and contrast setting as the sidebar.
struct DesktopTitlebarPlate: ViewModifier {
    @Environment(\.desktopChromeJoined) private var isJoined
    let fallback: Color

    func body(content: Content) -> some View {
        content
            .padding(.top, isJoined ? ShellMetrics.panelInset : 0)
            .background {
                if !isJoined { fallback }
            }
            .overlay(alignment: .bottom) {
                if !isJoined { ThemeRule() }
            }
    }
}

extension EnvironmentValues {
    @Entry var desktopChromeJoined = false
}

struct DesktopPaneBackground: ViewModifier {
    @Environment(\.desktopChromeJoined) private var isJoined
    let color: Color

    func body(content: Content) -> some View {
        content.background {
            if !isJoined { color }
        }
    }
}

/// The window owns the outer corner curves. This path only marks where chrome
/// gives way to the content, and needs one material pass even with both panes.
struct DesktopChromeSurface: View {
    let sidebarWidth: CGFloat
    /// A sidebar edge drag in progress, read here so the surface follows the
    /// pointer without the root view rebuilding.
    var drag: ShellColumnDrag?
    var storedSidebar: Double = 0
    let isFullScreen: Bool
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @AppStorage(SidebarAppearancePreferences.enabledKey) private var enabled = true
    @AppStorage(SidebarAppearancePreferences.washKey) private var wash = SidebarAppearancePreferences.defaultWash

    var body: some View {
        let live = drag?.sidebar.map { CGFloat($0 - storedSidebar) } ?? 0
        let width = sidebarWidth + live
        let outline = DesktopChromeShape(sidebarWidth: width)
        let tint = SidebarAppearancePreferences.effective(wash)
        Group {
            if enabled && !isFullScreen && !reduceTransparency && tint < 1 {
                glass(outline: outline, width: width, tint: tint)
            } else {
                outline.fill(Theme.sidebar)
                    .overlay { DesktopContentRim(sidebarWidth: width).stroke(Theme.contentRim, lineWidth: 1) }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func glass(outline: DesktopChromeShape, width: CGFloat, tint: Double) -> some View {
        if #available(macOS 26, *) {
            // Real Liquid Glass over the desktop behind the window, under the
            // whole window: the content sheet covers everything that is not
            // chrome, so the glass never needs the chrome's shape and a
            // sidebar drag never reshapes it. A SwiftUI material here only
            // blurred the window's own (clear) backing, which read as flat
            // grey whatever the slider said.
            SidebarBackdrop(cornerRadius: 0)
                .overlay { Theme.sidebar.opacity(tint) }
                .overlay { ChromeLighting(sidebarWidth: width) }
        } else {
            outline.fill(.regularMaterial)
                .overlay { outline.fill(Theme.sidebar.opacity(tint)) }
                .overlay { ChromeLighting(sidebarWidth: width) }
        }
    }
}

/// Optional light on the glass: a sheen along the top, one soft glare
/// streak, a breath of the accent and a lit bevel along the seam.
///
/// Plain alpha blending on purpose. Additive light (`plusLighter`) pushed
/// whites past full brightness, which an XDR display shows as HDR glare and
/// which made the content beside it look washed out. The seam's dark line
/// is drawn whether or not this is on, because it is structure, not light.
private struct ChromeLighting: View {
    let sidebarWidth: CGFloat
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(SidebarAppearancePreferences.highlightsKey) private var highlights = true

    var body: some View {
        let dark = colorScheme == .dark
        // Full-window fills: the content sheet covers the rest, and a fill that
        // followed the sidebar width repainted the whole window on every drag frame.
        let outline = Rectangle()
        ZStack {
            if highlights {
                outline.fill(LinearGradient(
                    stops: [.init(color: .white.opacity(dark ? 0.05 : 0.18), location: 0),
                            .init(color: .clear, location: 0.22)],
                    startPoint: .top, endPoint: .bottom))
                outline.fill(LinearGradient(
                    stops: [.init(color: .clear, location: 0.08),
                            .init(color: .white.opacity(dark ? 0.025 : 0.08), location: 0.14),
                            .init(color: .clear, location: 0.20)],
                    startPoint: .topLeading, endPoint: UnitPoint(x: 0.75, y: 1)))
                outline.fill(RadialGradient(colors: [Theme.accent.opacity(dark ? 0.06 : 0.04), .clear],
                                            center: .topLeading, startRadius: 0, endRadius: 480))
                DesktopContentRim(sidebarWidth: sidebarWidth, inset: -1.5)
                    .stroke(.white.opacity(dark ? 0.09 : 0.35), lineWidth: 1)
            }
            DesktopContentRim(sidebarWidth: sidebarWidth, inset: -0.5)
                .stroke(Theme.contentRim, lineWidth: 1)
        }
    }
}

private struct DesktopChromeShape: Shape {
    let sidebarWidth: CGFloat

    func path(in rect: CGRect) -> Path {
        let shoulder = rect.minX + min(max(sidebarWidth, 0), rect.width)
        let headerBottom = min(rect.minY + ShellMetrics.headerHeight, rect.maxY)
        return Path { path in
            path.move(to: rect.origin)
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: headerBottom))
            path.addLine(to: CGPoint(x: shoulder, y: headerBottom))
            path.addLine(to: CGPoint(x: shoulder, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
            path.closeSubpath()
        }
    }
}

/// The edge where the content sheet meets the chrome: one soft line down the
/// sidebar side and across under the toolbar, square at the shoulder.
private struct DesktopContentRim: Shape {
    let sidebarWidth: CGFloat
    /// Where the line sits relative to the seam. Negative is the chrome's
    /// side, which is the only side the content sheet does not cover.
    var inset: CGFloat = 0.5

    func path(in rect: CGRect) -> Path {
        let shoulder = rect.minX + min(max(sidebarWidth, 0), rect.width) + inset
        let headerBottom = min(rect.minY + ShellMetrics.headerHeight, rect.maxY) + inset
        return Path { path in
            path.move(to: CGPoint(x: shoulder, y: rect.maxY))
            path.addLine(to: CGPoint(x: shoulder, y: headerBottom))
            path.addLine(to: CGPoint(x: rect.maxX, y: headerBottom))
        }
    }
}

/// The content canvas below the toolbar. Its corner stays square: a rounded
/// corner against the sidebar read as a gap rather than a sheet.
struct DesktopContentSheet: View {
    let topInset: CGFloat
    var color: Color = Theme.background

    var body: some View {
        Rectangle()
            .fill(color)
            .padding(.top, topInset)
            .allowsHitTesting(false)
    }
}

/// AppKit proposes the new width before it publishes the new docking state.
/// A stale inspector reservation must never move the sidebar off the window.
struct DesktopDetailLayout: Layout {
    let minimumDetail: CGFloat
    var inspectorWidth: CGFloat?

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let preferredWidth = minimumDetail + (inspectorWidth ?? 0)
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? preferredWidth
        let height = proposal.height.flatMap { $0.isFinite ? $0 : nil } ?? 0
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let main = subviews.first else { return }
        let trailing = subviews.dropFirst().first
        let remaining = max(0, bounds.width - minimumDetail)
        let sideWidth: CGFloat
        if let inspectorWidth {
            sideWidth = inspectorWidth <= remaining ? inspectorWidth : 0
        } else {
            sideWidth = min(remaining, trailing?.sizeThatFits(.unspecified).width ?? 0)
        }
        let mainWidth = bounds.width - sideWidth
        main.place(at: bounds.origin, anchor: .topLeading,
                   proposal: ProposedViewSize(width: mainWidth, height: bounds.height))
        trailing?.place(at: CGPoint(x: bounds.minX + mainWidth, y: bounds.minY), anchor: .topLeading,
                        proposal: ProposedViewSize(width: sideWidth, height: bounds.height))
    }
}

/// The sidebar floated over the content on a window too narrow for the
/// column: the same glass as the docked panel, with a hairline and the flat
/// colour where glass does not exist.
struct FloatingSidebarSurface: ViewModifier {
    var isFullScreen: Bool = false

    func body(content: Content) -> some View {
        if #available(macOS 26, *) {
            content
                .background {
                    SidebarGlassSurface(isFullScreen: isFullScreen)
                }
                .overlay {
                    SidebarPanelRim()
                }
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

/// Remembered column widths, read once when a window opens and written
/// when a drag settles. Same keys the app has always used.
enum StoredWidth {
    static let sidebar = "shell.sidebarWidth"
    static let inspector = "shell.inspectorWidth"
    static let browserPane = "chat.browserPaneWidth"

    static func read(_ key: String, default fallback: Double) -> Double {
        guard let number = UserDefaults.standard.object(forKey: key) as? NSNumber else { return fallback }
        let value = number.doubleValue
        return value.isFinite && value > 0 ? value : fallback
    }

    static func write(_ value: Double, _ key: String) {
        guard value.isFinite, value > 0 else { return }
        UserDefaults.standard.set(value, forKey: key)
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
    case team

    var id: String { rawValue }

    var label: String {
        switch self {
        case .home: return L10n.text("common.home")
        case .projects: return L10n.text("common.projects")
        case .tasks: return L10n.text("common.tasks")
        case .notes: return L10n.text("common.notes")
        case .automations: return L10n.text("common.automations")
        case .insights: return L10n.text("common.insights")
        case .devices: return L10n.text("common.devices")
        case .team: return L10n.text("common.teams.title")
        case .ssh: return L10n.text("apple.shellchrome.ssh.01c4d3c2")
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
        case .team: return "person.2"
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
            case .team: return .team
            case .account, .newChat: return nil
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
    var badge: Bool = false
    let action: () -> Void

    @State private var isHovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            Image(systemName: place.symbol)
                .font(Theme.fixed(16, weight: isSelected ? .semibold : .regular))
                .symbolVariant(isSelected ? .fill : .none)
                .foregroundStyle(isSelected ? Theme.accent : (isHovering ? Theme.controlGlyphHover : Theme.controlGlyph))
                .frame(width: 36, height: 33)
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
        .buttonStyle(ControlFeedbackStyle(highlights: false))
        .onHover { isHovering = $0 }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: isHovering)
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
    @Binding var width: Double
    /// Closures rather than a binding: SwiftUI reads a binding while updating
    /// the parent, which made the root view redraw on every drag event.
    let liveWidth: () -> Double?
    let setLiveWidth: (Double?) -> Void
    let range: ClosedRange<Double>
    var showsLine: Bool = true
    var help: String = L10n.text("apple.shellchrome.drag_to_resize.31b2f1cd")

    @State private var start: Double?
    @State private var hovered = false

    var body: some View {
        ZStack {
            if showsLine {
                Rectangle().fill(Theme.border).frame(width: 1)
            }
            Capsule().fill(Theme.accent.opacity(hovered || start != nil ? 0.8 : 0))
                .frame(width: 3, height: 36)
                .allowsHitTesting(false)
        }
        .frame(width: 9)
        .frame(maxHeight: .infinity)
        .contentShape(.rect)
        .columnResizePointer()
        .onHover { hovered = $0 }
        .gesture(
            DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { value in
                    let origin = start ?? (liveWidth() ?? width)
                    if start == nil { start = origin }
                    let delta = side == .leading ? value.translation.width : -value.translation.width
                    setLiveWidth(min(range.upperBound, max(range.lowerBound, origin + delta)))
                }
                .onEnded { _ in
                    if let live = liveWidth() { width = live }
                    setLiveWidth(nil)
                    start = nil
                }
        )
        .onTapGesture(count: 2) {
            let reset = side == .leading ? ShellMetrics.sidebarDefault : ShellMetrics.inspectorDefault
            width = min(range.upperBound, max(range.lowerBound, reset))
        }
        .onDisappear {
            setLiveWidth(nil)
            start = nil
            hovered = false
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

/// The widths a column edge is being dragged to, outside the root view.
///
/// A width held in the root view's state rebuilt every screen the window
/// shows on each pointer event, which is what made the edges feel heavy. Here
/// only the small leaves that read a width (the column frame, the chrome
/// surface, the handle itself) update while the pointer moves, and the stored
/// preference is written once, when the drag ends.
@Observable final class ShellColumnDrag {
    var sidebar: Double?
    var inspector: Double?
}

/// Frames a column at its live width while dragging, its stored width
/// otherwise. Reading the live width here keeps the update in this leaf.
struct LiveColumnWidth: ViewModifier {
    enum Column { case sidebar, inspector }
    let drag: ShellColumnDrag
    let column: Column
    let stored: Double

    func body(content: Content) -> some View {
        let live = column == .sidebar ? drag.sidebar : drag.inspector
        // The column's edge follows the pointer exactly. Its rows are laid
        // out in steps (see `SteppedWidthLayout`) and clipped to the edge.
        SteppedWidthLayout(step: live == nil ? 1 : ShellMetrics.dragLayoutStep) { content }
            .frame(width: CGFloat(live ?? stored))
            .clipShape(DragClip(active: live != nil))
            .transaction { if live != nil { $0.animation = nil; $0.disablesAnimations = true } }
    }
}

/// Clips to the column only while it is dragged. A clip added and removed
/// would change the column's identity and reset its scroll position, so
/// at rest this is a rectangle far larger than anything it holds, which
/// leaves hover cards and focus rings that reach past the edge alone.
private struct DragClip: Shape {
    var active: Bool
    func path(in rect: CGRect) -> Path {
        Path(active ? rect : rect.insetBy(dx: -4000, dy: -4000))
    }
}

/// The detail beside a sidebar being dragged, laid out in steps.
///
/// Re-measuring a chat transcript or Home's cards for every pointer event is
/// what made the sidebar edge trail the pointer. While a drag runs, this
/// only re-measures each `dragLayoutStep` points and moves the laid out
/// content in between, which costs a placement and nothing else. The extra
/// width hangs off the window's trailing edge, so nothing ever shows a gap.
struct LiveSteppedDetail<Content: View>: View {
    let drag: ShellColumnDrag
    @ViewBuilder let content: Content

    var body: some View {
        SteppedWidthLayout(step: drag.sidebar == nil ? 1 : ShellMetrics.dragLayoutStep) { content }
    }
}

/// Proposes its child a width rounded up to a whole step, places it at the
/// leading edge, and reports the width it was offered. A child asked the
/// same size again reuses its last layout, so between steps a resize is a
/// move. Rounding up, never down, means the child always covers the space.
struct SteppedWidthLayout: Layout {
    var step: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let child = subviews.first else { return .zero }
        let size = child.sizeThatFits(childProposal(proposal))
        return CGSize(width: proposal.width ?? size.width, height: proposal.height ?? size.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let offered = ProposedViewSize(width: bounds.width, height: bounds.height)
        subviews.first?.place(at: bounds.origin, anchor: .topLeading, proposal: childProposal(offered))
    }

    private func childProposal(_ proposal: ProposedViewSize) -> ProposedViewSize {
        guard step > 1, let width = proposal.width, width.isFinite else { return proposal }
        return ProposedViewSize(width: (width / step).rounded(.up) * step, height: proposal.height)
    }
}

/// The detail and docked inspector split, reading the inspector's live width
/// in this leaf rather than in the root view.
struct LiveDetailColumn<Content: View>: View {
    let drag: ShellColumnDrag
    let minimumDetail: CGFloat
    let storedInspector: Double?
    @ViewBuilder let content: Content

    var body: some View {
        let width = storedInspector.map { CGFloat(drag.inspector ?? $0) }
        DesktopDetailLayout(minimumDetail: minimumDetail, inspectorWidth: width) { content }
            .transaction { if drag.inspector != nil { $0.animation = nil; $0.disablesAnimations = true } }
    }
}

extension View {
    /// The system's column resize pointer over a divider. SwiftUI's own
    /// pointer style wins over the hosting view's arrow, where a cursor rect
    /// alone was overridden and never showed.
    @ViewBuilder
    func columnResizePointer(isActive: Bool = true) -> some View {
        if #available(macOS 15, *) {
            self.pointerStyle(isActive ? .columnResize : nil)
        } else {
            self.background { ColumnResizeCursorArea(isActive: isActive) }
        }
    }
}

/// AppKit owns the cursor only inside the visible divider. A global cursor
/// stack can outlive SwiftUI hover exits when columns move or disappear.
struct ColumnResizeCursorArea: NSViewRepresentable {
    var isActive = true
    func makeNSView(context: Context) -> ColumnResizeCursorView { ColumnResizeCursorView() }
    func updateNSView(_ view: ColumnResizeCursorView, context: Context) {
        if view.isHidden != !isActive {
            view.isHidden = !isActive
            view.window?.invalidateCursorRects(for: view)
        }
    }
    static func dismantleNSView(_ view: ColumnResizeCursorView, coordinator: ()) {
        view.discardCursorRects()
    }
}

final class ColumnResizeCursorView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func resetCursorRects() {
        super.resetCursorRects()
        guard window != nil, !isHiddenOrHasHiddenAncestor, !visibleRect.isEmpty else { return }
        addCursorRect(visibleRect, cursor: .resizeLeftRight)
    }
}
#endif

#if os(macOS)
struct ProjectHeader: View {
    let folder: WorkspaceFolder
    let selected: WorkspaceSection?
    var branch: AnyView?
    var count: (WorkspaceSection) -> Int? = { _ in nil }
    let select: (WorkspaceSection) -> Void

    /// In reading order. History is the inspector's on the Mac, and the
    /// browser is the globe beside the inspector toggle.
    static let sections: [WorkspaceSection] = [
        .chat, .sessions, .changes, .files, .pulls, .todo, .notes, .automations, .workflows,
    ]
    private static let primary = 5

    var body: some View {
        HStack(spacing: 6) {
            title.layoutPriority(1)
            if let branch {
                branch
            }
            Rectangle()
                .fill(Theme.border)
                .frame(width: 1, height: 16)
                .padding(.horizontal, 2)
            // Names for the five everyday sections survive the middle width.
            ChromeTabStrip(tabs: tabs, selected: selected?.rawValue, primary: Self.primary, owner: folder.id) { id in
                if let section = WorkspaceSection(rawValue: id) { select(section) }
            }
            .equatable()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var title: some View {
        ViewThatFits(in: .horizontal) {
            titleLabel.frame(maxWidth: 216).fixedSize(horizontal: true, vertical: false)
            titleLabel.frame(maxWidth: 116).fixedSize(horizontal: true, vertical: false)
            titleLabel
        }
        .help(folder.isRemote ? "\(folder.machineLabel ?? L10n.text("apple.shellchrome.remote_machine.d9dd1af3")) · \(folder.path)" : folder.path)
    }

    private var titleLabel: some View {
        HStack(spacing: 6) {
            Image(systemName: folder.isRemote ? "network" : "folder.fill")
                .font(Theme.fixed(11, weight: .semibold))
                .foregroundStyle(Theme.accent)
            Text(folder.isRemote ? "\(folder.machineLabel ?? L10n.text("apple.shellchrome.remote.ffa98e02")) / \(folder.name)" : folder.name)
                .font(Theme.fit(13, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.middle)
        }
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
/// all but the first few, then secondary destinations enter a native menu.
/// The tab you are on always says what it is, even at the narrowest width.
/// One component for a project's sections, the SSH library's and the
/// automations place, so they read as the same control wherever they appear.
struct ChromeTabStrip: View, Equatable {
    let tabs: [ChromeTab]
    let selected: String?
    var primary: Int = 3
    /// Whose sections these are. Only for equality: a strip that compares
    /// equal keeps its previous `select`, which must never be a closure that
    /// was made for another project.
    var owner: String = ""
    let select: (String) -> Void

    /// What the strip draws. The closure is left out on purpose: no two
    /// closures compare equal, so with it every parent update re-measured
    /// all four `ViewThatFits` candidates, about 100 ms per chat switch.
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.tabs == rhs.tabs && lhs.selected == rhs.selected
            && lhs.primary == rhs.primary && lhs.owner == rhs.owner
    }

    var body: some View {
        MemoizedSizeLayout(key: sizeKey) {
            ViewThatFits(in: .horizontal) {
                strip(counts: true) { _, _ in true }
                strip(counts: false) { _, _ in true }
                primaryStrip(limit: primary)
                primaryStrip(limit: 2)
                sectionMenu(tabs)
            }
        }
    }

    /// Everything the strip's size depends on: what it draws and the display
    /// scale its type is fitted to.
    private var sizeKey: Int {
        var hasher = Hasher()
        hasher.combine(tabs)
        hasher.combine(selected)
        hasher.combine(primary)
        hasher.combine(DisplayFit.factor)
        return hasher.finalize()
    }

    /// Keep the two main destinations named before falling back to one
    /// native menu. A row of every icon still has a minimum width and can
    /// otherwise force the entire document beyond the window's trailing edge.
    private func primaryStrip(limit: Int) -> some View {
        HStack(spacing: 2) {
            ForEach(Array(tabs.prefix(limit))) { tab in
                ChromeTabButton(tab: tab, isSelected: tab.id == selected,
                                showsLabel: true, showsCount: false) { select(tab.id) }
            }
            if tabs.count > limit { sectionMenu(Array(tabs.dropFirst(limit))) }
        }
        .fixedSize()
    }

    private func sectionMenu(_ choices: [ChromeTab]) -> some View {
        let current = choices.first { $0.id == selected }
        return Menu {
            ForEach(choices) { tab in
                Button { select(tab.id) } label: {
                    Label(tab.count.map { "\(tab.label), \($0)" } ?? tab.label,
                          systemImage: tab.symbol)
                }
                .accessibilityAddTraits(tab.id == selected ? .isSelected : [])
            }
        } label: {
            Label(current?.label ?? L10n.text("apple.shellchrome.more.d47d7cb0"), systemImage: current?.symbol ?? "ellipsis")
                .font(Theme.fit(12, weight: .medium))
                .foregroundStyle(current == nil ? Theme.controlGlyph : Theme.accent)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .padding(.horizontal, 7)
        .frame(height: 26)
        .background(Capsule().fill(current == nil ? Color.clear : Theme.rowSelected))
        .frame(minHeight: ToolbarIconButton.diameter)
        .contentShape(Rectangle())
        .help(L10n.text("apple.shellchrome.switch_section.936d958d"))
        .accessibilityLabel(current.map { L10n.text("apple.shellchrome.0_switch_section.dac85de8", "\($0.label)") } ?? L10n.text("apple.shellchrome.more_sections.a8e35e36"))
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
            .background {
                // Hover grows in under the pointer. The selected seat grows
                // out of the tab it lands on while the old one shrinks away.
                ZStack {
                    Capsule().fill(Theme.rowHighlight.opacity(0.7))
                        .opacity(isHovering && !isSelected ? 1 : 0)
                        .scaleEffect(isHovering && !isSelected ? 1 : 0.85)
                    Capsule().fill(Theme.rowSelected)
                        .opacity(isSelected ? 1 : 0)
                        .scaleEffect(isSelected ? 1 : 0.7)
                }
            }
            .frame(minHeight: ToolbarIconButton.diameter)
            .contentShape(Rectangle())
        }
        .buttonStyle(ControlFeedbackStyle(highlights: false, pressScale: 0.95))
        .onHover { isHovering = $0 }
        .animation(Motion.unless(reduceMotion, Motion.morph), value: isHovering)
        .animation(Motion.unless(reduceMotion, Motion.morph), value: isSelected)
        .help(tab.count.map { "\(tab.label), \($0)" } ?? tab.label)
        .accessibilityLabel(tab.count.map { "\(tab.label), \($0)" } ?? tab.label)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
#endif
