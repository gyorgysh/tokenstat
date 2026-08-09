// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

#if os(macOS)
import AppKit
import SwiftUI

/// Keeps the layout's display fit and the window itself honest to the screen
/// the window is actually on.
///
/// The app opens with a size computed from the main display, and the fixed
/// layout numbers were tuned on a full-size desktop. A window that starts on,
/// or is dragged onto, a smaller display was born wider than that screen
/// presents in points, and the inspector ran past the edge. This observes the
/// window's screen so [`DisplayFit`] always scales against the right display,
/// and clamps the window back inside the visible frame when the display
/// changes or its resolution does.
///
/// Window chrome is also owned here, because SwiftUI's hidden-title-bar style
/// alone cannot express two different modes cleanly:
///
/// - **Windowed:** transparent titlebar + `fullSizeContentView`, with a small
///   AppKit patch so the sidebar colour fills the strip above the leading
///   column (the split lays the sidebar below the toolbar while the detail
///   extends under it).
/// - **Full screen:** a normal native titlebar/toolbar above the content. That
///   is the system full-screen reveal bar with real close / minimize / zoom
///   buttons. Content sits under it, square and edge to edge, with no custom
///   traffic lights and no painting into `NSToolbarFullScreenWindow`.
struct WindowScreenObserver: NSViewRepresentable {
    /// The window's content width, published from resize notifications.
    ///
    /// The inspector fit decision lives on this. A width read inside the split
    /// view re-enters AppKit's constraints pass (a hosted column changing its
    /// minimum size while that pass is running is exactly what threw); a
    /// resize notification is delivered outside any layout pass, so writing
    /// state from it cannot re-enter one.
    @Binding var contentWidth: CGFloat
    /// Whether the window is currently full screen. Drives toolbar background
    /// visibility in SwiftUI and the AppKit chrome mode below.
    @Binding var isFullScreen: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        let view = WindowReportingView()
        view.onWindowChange = { [weak coordinator = context.coordinator] window in
            Task { @MainActor in
                coordinator?.attach(
                    to: window,
                    contentWidth: $contentWidth,
                    isFullScreen: $isFullScreen
                )
            }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        // A rebuilt representable must not leave the coordinator writing
        // through a stale binding.
        MainActor.assumeIsolated {
            context.coordinator.contentWidth = $contentWidth
            context.coordinator.isFullScreen = $isFullScreen
            // SwiftUI may rebuild the toolbar after attach. Re-apply chrome so
            // a full-screen enter mid-rebuild cannot leave a transparent bar.
            if let window = context.coordinator.attachedWindow {
                context.coordinator.applyChrome(on: window)
            }
        }
    }

    @MainActor
    final class Coordinator {
        private var window: NSWindow?
        /// Exposed so `updateNSView` can re-apply chrome without re-attaching.
        var attachedWindow: NSWindow? { window }
        private var observers: [NSObjectProtocol] = []
        /// Paints the sidebar column's slice of the titlebar with the sidebar
        /// colour in **windowed** mode only. Full screen uses a real titlebar
        /// above the content, so the gap does not exist there.
        private var sidebarGapPatch: NSView?
        /// Where the measured width goes. Refreshed from `updateNSView` so a
        /// rebuilt representable never writes through a stale binding.
        var contentWidth: Binding<CGFloat>?
        var isFullScreen: Binding<Bool>?

        /// Attaches to whatever window the view reports, detaching from any
        /// previous one first.
        ///
        /// Called from `WindowReportingView.viewDidMoveToWindow`, which fires
        /// on every window transition, so a view that lands in a window a
        /// frame late still attaches and a re-parented view re-attaches
        /// instead of observing a dead window. The old one-shot
        /// `DispatchQueue.main.async` gave up silently when the view had no
        /// window on that turn, which froze the inspector fit at its initial
        /// value for the whole session.
        func attach(
            to window: NSWindow?,
            contentWidth: Binding<CGFloat>,
            isFullScreen: Binding<Bool>
        ) {
            guard let window else { return }
            detach()
            self.window = window
            self.contentWidth = contentWidth
            self.isFullScreen = isFullScreen
            observe(window)
            apply(window)
            publishWidth(from: window)
            publishFullScreen(from: window)
            applyChrome(on: window)
            // SwiftUI's `.toolbar(removing: .sidebarToggle)` is not always
            // enough: NavigationSplitView re-installs the stock control (glyph
            // + "Hide Sidebar", no shortcut). Hide it on the real NSToolbar
            // whenever we attach or the toolbar changes.
            stripSystemSidebarToggle(in: window)
            scheduleSidebarToggleStrip(for: window)
        }

        private func detach() {
            observers.forEach(NotificationCenter.default.removeObserver)
            observers.removeAll()
            sidebarGapPatch?.removeFromSuperview()
            sidebarGapPatch = nil
            window = nil
        }

        /// Switch between the windowed transparent-titlebar look and the
        /// full-screen native bar. Called on attach, enter/exit full screen,
        /// and every `updateNSView`.
        func applyChrome(on window: NSWindow) {
            let fullScreen = window.styleMask.contains(.fullScreen)
            if fullScreen {
                applyFullScreenChrome(on: window)
            } else {
                applyWindowedChrome(on: window)
            }
            // Always keep the real traffic lights available. Full screen hosts
            // them in the native reveal bar; windowed hosts them in the
            // titlebar. Custom drawn circles are never used.
            for buttonType: NSWindow.ButtonType in [.closeButton, .miniaturizeButton, .zoomButton] {
                if let button = window.standardWindowButton(buttonType) {
                    button.isHidden = false
                    button.alphaValue = 1
                }
            }
            if let toolbar = window.toolbar {
                toolbar.isVisible = true
            }
            updateSidebarTopGap(in: window)
        }

        /// Windowed: content draws under a transparent titlebar so the sidebar
        /// colour can meet the traffic-light band. The gap patch fills the
        /// strip above the leading column.
        private func applyWindowedChrome(on window: NSWindow) {
            if !window.styleMask.contains(.fullSizeContentView) {
                window.styleMask.insert(.fullSizeContentView)
            }
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            if #available(macOS 11.0, *) {
                window.titlebarSeparatorStyle = .none
            }
            // Windowed keeps its natural corner radius from the system chrome.
            restoreContentCorners(in: window)
        }

        /// Full screen: put a real native titlebar/toolbar above the content.
        /// That is the system control bar (close / minimize / zoom on reveal).
        /// Content is square and flush to the screen edges under that bar.
        private func applyFullScreenChrome(on window: NSWindow) {
            // Content must sit *below* the titlebar, not under it. Drawing
            // under a transparent bar is what produced the grey strip, the
            // floating rounded card look, and the need for toolbar-window
            // patches. A normal titlebar is the native method.
            if window.styleMask.contains(.fullSizeContentView) {
                window.styleMask.remove(.fullSizeContentView)
            }
            window.titlebarAppearsTransparent = false
            window.titleVisibility = .hidden
            if #available(macOS 11.0, *) {
                // Keep a hairline under the bar so it reads as chrome, not as
                // a second content band. The sidebar itself stays borderless.
                window.titlebarSeparatorStyle = .automatic
            }
            flattenFullScreenContent(in: window)
            // No windowed gap patch in full screen: there is no gap.
            sidebarGapPatch?.removeFromSuperview()
            sidebarGapPatch = nil
        }

        /// Full screen content must be square and flush. Hidden-title-bar
        /// windows keep a corner radius on the content hierarchy even after
        /// entering full screen, which reads as padding + roundness on the
        /// left sidebar. Zero those radii and paint an opaque backdrop.
        private func flattenFullScreenContent(in window: NSWindow) {
            // The theme-window frame view and the content view both get a
            // radius from AppKit. Walk a shallow set of parents and clear it.
            var views: [NSView] = []
            if let content = window.contentView {
                views.append(content)
                if let parent = content.superview {
                    views.append(parent)
                    if let grand = parent.superview {
                        views.append(grand)
                    }
                }
            }
            for view in views {
                view.wantsLayer = true
                view.layer?.cornerRadius = 0
                view.layer?.masksToBounds = true
                // Drop any mask image AppKit uses for the rounded window shape.
                view.layer?.mask = nil
            }
        }

        private func restoreContentCorners(in window: NSWindow) {
            // Leaving full screen: stop forcing square masks so the windowed
            // chrome can round itself again.
            var views: [NSView] = []
            if let content = window.contentView {
                views.append(content)
                if let parent = content.superview {
                    views.append(parent)
                }
            }
            for view in views {
                view.layer?.masksToBounds = false
            }
        }

        private func publishFullScreen(from window: NSWindow) {
            let fullScreen = window.styleMask.contains(.fullScreen)
            guard let isFullScreen, isFullScreen.wrappedValue != fullScreen else { return }
            isFullScreen.wrappedValue = fullScreen
        }

        private func observe(_ window: NSWindow) {
            let center = NotificationCenter.default
            // NavigationSplitView re-inserts its stock "Toggle Sidebar" item
            // whenever the split state changes or the toolbar is rebuilt —
            // long after `attach` and the scheduled strips have run. A
            // deferred removal let the freshly inserted stock button paint
            // for a frame first: a light system button flashing in at the
            // sidebar toggle position, which is the white flash seen when
            // switching destinations. `willAddItem` fires *before* the item
            // is inserted, so the item is neutralised synchronously here and
            // can never render or reserve a slot.
            observers.append(
                center.addObserver(
                    forName: NSToolbar.willAddItemNotification,
                    object: nil,
                    queue: .main
                ) { [weak self] note in
                    guard let self else { return }
                    guard let toolbar = note.object as? NSToolbar,
                          let item = note.userInfo?[NSToolbarUserInfoKey.itemKey] as? NSToolbarItem,
                          Self.isSystemSidebarToggle(item) else { return }
                    // Neutralise synchronously so the fresh item cannot paint
                    // a light button at the toggle position...
                    Self.neutraliseSidebarToggle(item)
                    // ...then remove it on the next main-queue turn, which
                    // runs before the toolbar draws. Removal (not just hiding)
                    // is what collapses the reserved slot: an invisible item
                    // still held an enforced minimum width, leaving the empty
                    // gap that kept the custom buttons from sitting flush
                    // left once the sidebar closed.
                    DispatchQueue.main.async { [weak self, weak toolbar] in
                        guard let self, let toolbar else { return }
                        self.removeSystemSidebarToggle(from: toolbar)
                    }
                }
            )
            // Moving the window to another display.
            observers.append(
                center.addObserver(
                    forName: NSWindow.didChangeScreenNotification,
                    object: window,
                    queue: .main
                ) { [weak self] _ in
                    Task { @MainActor in
                        self?.apply(window)
                        // The fit threshold is display-scaled, so a screen
                        // change can move the edge without the width moving.
                        self?.publishWidth(from: window)
                    }
                }
            )
            // Resolution or arrangement changes (e.g. "More Space" toggled, a
            // display unplugged). Object is nil: the whole app cares.
            observers.append(
                center.addObserver(
                    forName: NSApplication.didChangeScreenParametersNotification,
                    object: nil,
                    queue: .main
                ) { [weak self] _ in
                    Task { @MainActor in
                        self?.apply(window)
                        self?.publishWidth(from: window)
                    }
                }
            )
            // The width the inspector fit is decided on. Published live, during
            // a drag as well as after: the live-resize gate was written for the
            // inspector *divider* drag, whose constraint pass re-entered AppKit
            // and crashed. That divider no longer exists (the column is a
            // single fixed width), and a window resize is a different pass,
            // with the state write deferred off it in `applyWidth`. Waiting
            // until the drag ended is what left the inspector open and the
            // sidebar pushed out for the whole gesture.
            observers.append(
                center.addObserver(
                    forName: NSWindow.didResizeNotification,
                    object: window,
                    queue: .main
                ) { [weak self] _ in
                    Task { @MainActor in self?.windowResized(window) }
                }
            )
            observers.append(
                center.addObserver(
                    forName: NSWindow.didEndLiveResizeNotification,
                    object: window,
                    queue: .main
                ) { [weak self] _ in
                    Task { @MainActor in self?.liveResizeEnded(window) }
                }
            )
            // The sidebar column moves when the split layout changes (a
            // divider drag or a ⌘B toggle). The windowed gap patch follows it.
            observers.append(
                center.addObserver(
                    forName: NSSplitView.didResizeSubviewsNotification,
                    object: nil,
                    queue: .main
                ) { [weak self] _ in
                    Task { @MainActor in self?.updateSidebarTopGap(in: window) }
                }
            )
            observers.append(
                center.addObserver(
                    forName: NSWindow.willEnterFullScreenNotification,
                    object: window,
                    queue: .main
                ) { [weak self] _ in
                    Task { @MainActor in
                        // Apply before the transition finishes so the first
                        // full-screen frame is already the native-bar mode.
                        self?.applyFullScreenChrome(on: window)
                    }
                }
            )
            observers.append(
                center.addObserver(
                    forName: NSWindow.didEnterFullScreenNotification,
                    object: window,
                    queue: .main
                ) { [weak self] _ in
                    Task { @MainActor in
                        self?.publishFullScreen(from: window)
                        self?.applyChrome(on: window)
                        self?.stripSystemSidebarToggle(in: window)
                        // AppKit re-applies corner radii and style masks for a
                        // few frames after the transition. Re-assert.
                        for delay in [0.05, 0.2, 0.5] {
                            try? await Task.sleep(for: .seconds(delay))
                            guard self?.window === window else { return }
                            self?.applyChrome(on: window)
                            self?.stripSystemSidebarToggle(in: window)
                        }
                    }
                }
            )
            observers.append(
                center.addObserver(
                    forName: NSWindow.willExitFullScreenNotification,
                    object: window,
                    queue: .main
                ) { [weak self] _ in
                    Task { @MainActor in
                        self?.applyWindowedChrome(on: window)
                    }
                }
            )
            observers.append(
                center.addObserver(
                    forName: NSWindow.didExitFullScreenNotification,
                    object: window,
                    queue: .main
                ) { [weak self] _ in
                    Task { @MainActor in
                        self?.publishFullScreen(from: window)
                        self?.applyChrome(on: window)
                        self?.stripSystemSidebarToggle(in: window)
                        self?.scheduleSidebarToggleStrip(for: window)
                    }
                }
            )
        }

        private func windowResized(_ window: NSWindow) {
            publish(quantised(window.contentLayoutRect.width, step: 4))
            updateSidebarTopGap(in: window)
            // Full screen layout can reintroduce corner masks on resize.
            if window.styleMask.contains(.fullScreen) {
                flattenFullScreenContent(in: window)
            }
        }

        private func liveResizeEnded(_ window: NSWindow) {
            // Final settle, so the last width always lands even if a live
            // resize notification was dropped.
            publish(quantised(window.contentLayoutRect.width, step: 4))
            updateSidebarTopGap(in: window)
        }

        /// Windowed only: fill the gap above the sidebar column so the
        /// transparent titlebar does not show the toolbar's grey surface.
        private func updateSidebarTopGap(in window: NSWindow) {
            // Full screen has a real titlebar above content: no gap to patch.
            guard !window.styleMask.contains(.fullScreen) else {
                sidebarGapPatch?.removeFromSuperview()
                sidebarGapPatch = nil
                return
            }
            guard let contentView = window.contentView,
                  let frameInContent = Self.sidebarColumnFrame(in: window)
            else {
                sidebarGapPatch?.isHidden = true
                return
            }
            let gapAboveColumn = contentView.bounds.height - frameInContent.maxY
            let layoutInContent = contentView.convert(window.contentLayoutRect, from: nil)
            let gapAboveLayout = max(0, contentView.bounds.maxY - layoutInContent.maxY)
            let gap = max(gapAboveColumn, gapAboveLayout)
            guard gap > 1 else {
                sidebarGapPatch?.isHidden = true
                return
            }
            let patch = sidebarGapPatch ?? SidebarGapPatchView()
            sidebarGapPatch = patch
            patch.frame = NSRect(
                x: frameInContent.minX,
                y: contentView.bounds.height - gap,
                width: frameInContent.width + 1,
                height: gap
            )
            if patch.superview !== contentView {
                contentView.addSubview(patch, positioned: .below, relativeTo: nil)
            }
            patch.isHidden = false
        }

        /// Frame of the leading sidebar column wrapper, in the main window's
        /// content-view coordinates. Nil when the sidebar is collapsed or the
        /// split has not been built yet.
        private static func sidebarColumnFrame(in window: NSWindow) -> NSRect? {
            guard let wrapper = sidebarColumnWrapper(in: window),
                  let contentView = window.contentView
            else {
                return nil
            }
            return wrapper.convert(wrapper.bounds, to: contentView)
        }

        /// The leading sidebar column's wrapper view, or nil when the sidebar
        /// is collapsed or the split has not been built yet.
        private static func sidebarColumnWrapper(in window: NSWindow) -> NSView? {
            guard let contentView = window.contentView,
                  let split = outerSplit(in: contentView)
            else {
                return nil
            }
            return split.subviews
                .filter {
                    $0.frame.minX < 8
                        && $0.frame.width > 100
                        && $0.frame.width < 600
                        && $0.frame.height > 120
                }
                .sorted { $0.frame.minX < $1.frame.minX }
                .first
        }

        /// The outermost split view in the window's content.
        private static func outerSplit(in view: NSView) -> NSSplitView? {
            if let split = view as? NSSplitView {
                return split
            }
            for sub in view.subviews {
                if let found = outerSplit(in: sub) {
                    return found
                }
            }
            return nil
        }

        /// Writes the width out to the binding. Only ever called from resize or
        /// end-of-resize notifications, never from inside a layout pass. Writes
        /// only when the value moved, so a drag that crosses no 4pt step is a
        /// no-op.
        private func publish(_ width: CGFloat) {
            guard let contentWidth, contentWidth.wrappedValue != width else { return }
            contentWidth.wrappedValue = width
        }

        private func publishWidth(from window: NSWindow) {
            publish(quantised(window.contentLayoutRect.width, step: 4))
        }

        private func apply(_ window: NSWindow) {
            DisplayFit.update(screen: window.screen)
            clamp(window)
            stripSystemSidebarToggle(in: window)
            paintWindowBackground(in: window)
        }

        /// Give the window an opaque dark backdrop.
        ///
        /// SwiftUI's `NavigationSplitView` leaves the window's own background
        /// visible wherever a column has not painted yet — for a frame or two
        /// while the inspector column appears or leaves on a destination
        /// switch. The system default there is a light surface, which read as
        /// a white replica of the sidebar flashing on the left edge. An
        /// explicit opaque background (the app's own theme values, so light
        /// and dark mode both stay correct) means an unpainted area shows the
        /// app's backdrop, never a white bar.
        private func paintWindowBackground(in window: NSWindow) {
            let background = NSColor(name: nil) { appearance in
                let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                if isDark {
                    // Theme.background dark: #08070D
                    return NSColor(red: 0x08 / 255.0, green: 0x07 / 255.0, blue: 0x0D / 255.0, alpha: 1)
                }
                // Theme.background light: #FBFBFD
                return NSColor(red: 0xFB / 255.0, green: 0xFB / 255.0, blue: 0xFD / 255.0, alpha: 1)
            }
            window.backgroundColor = background
            window.isOpaque = true
        }

        /// Remove AppKit's stock sidebar toggle item so only our custom marks
        /// (with ⌘B / ⌥⌘B in the help string) remain.
        ///
        /// The item is removed outright rather than hidden: hiding its view
        /// and zeroing its frame still left a wide empty slot in the toolbar,
        /// which read as a big blank button beside the traffic lights.
        private func stripSystemSidebarToggle(in window: NSWindow) {
            guard let toolbar = window.toolbar else { return }
            removeSystemSidebarToggle(from: toolbar)
        }

        private func removeSystemSidebarToggle(from toolbar: NSToolbar) {
            var index = 0
            while index < toolbar.items.count {
                let item = toolbar.items[index]
                if Self.isSystemSidebarToggle(item) {
                    toolbar.removeItem(at: index)
                } else {
                    index += 1
                }
            }
        }

        /// Whether this is the stock toggle NavigationSplitView installs.
        private static func isSystemSidebarToggle(_ item: NSToolbarItem) -> Bool {
            let id = item.itemIdentifier.rawValue
            return item.itemIdentifier == .toggleSidebar
                || id.contains("toggleSidebar")
                || id.contains("ToggleSidebar")
                || id.contains("sidebar.toggle")
        }

        /// Make a stock toggle item impossible to render, before it is
        /// inserted. Everything it could draw is removed and its size is
        /// zeroed, so the toolbar inserts an invisible, zero-width item and
        /// the layout does not shift when the item later goes away.
        private static func neutraliseSidebarToggle(_ item: NSToolbarItem) {
            item.isEnabled = false
            item.image = nil
            item.label = ""
            item.toolTip = nil
            item.minSize = .zero
            item.maxSize = .zero
            if #available(macOS 15.0, *) {
                item.isHidden = true
                item.isBordered = false
            }
            item.view?.isHidden = true
            item.view?.frame = .zero
        }

        /// Fallback: hide and disable any stock item the removal above missed
        /// (macOS 15 `isHidden`; on 14 hide the view and take its space).
        private func hideSystemSidebarToggle(in window: NSWindow) {
            guard let toolbar = window.toolbar else { return }
            for item in toolbar.items {
                guard Self.isSystemSidebarToggle(item) else { continue }
                // `NSToolbarItem.isHidden` is macOS 15+. On 14 hide the view
                // and disable the item so it cannot be activated.
                if #available(macOS 15.0, *) {
                    item.isHidden = true
                }
                item.isEnabled = false
                item.toolTip = nil
                item.view?.isHidden = true
                item.view?.frame = .zero
                // Zero min size so a disabled stock item does not reserve a
                // toolbar slot beside our custom mark.
                item.minSize = .zero
                item.maxSize = .zero
            }
        }

        /// SwiftUI rebuilds the toolbar after first paint; strip again shortly
        /// and on a couple of follow-up turns so a re-inserted stock item does
        /// not stick.
        private func scheduleSidebarToggleStrip(for window: NSWindow) {
            for delay in [0.05, 0.2, 0.6, 1.2] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self, weak window] in
                    guard let self, let window, self.window === window else { return }
                    self.stripSystemSidebarToggle(in: window)
                    self.hideSystemSidebarToggle(in: window)
                }
            }
        }

        /// Pull the window back inside the visible frame when the display
        /// changed under it.
        ///
        /// Deliberately not invoked on every drag: a live move that keeps the
        /// window on the same screen must not fight the user. It runs when the
        /// screen changes or its resolution does, which are the two moments a
        /// window can be born larger than the display it lands on.
        private func clamp(_ window: NSWindow) {
            guard let screen = window.screen else { return }
            let visible = screen.visibleFrame
            var frame = window.frame
            var changed = false

            if frame.width > visible.width {
                frame.size.width = visible.width
                changed = true
            }
            if frame.height > visible.height {
                frame.size.height = visible.height
                changed = true
            }
            if frame.maxX > visible.maxX {
                frame.origin.x = visible.maxX - frame.width
                changed = true
            }
            if frame.minX < visible.minX {
                frame.origin.x = visible.minX
                changed = true
            }
            if frame.maxY > visible.maxY {
                frame.origin.y = visible.maxY - frame.height
                changed = true
            }
            if frame.minY < visible.minY {
                frame.origin.y = visible.minY
                changed = true
            }

            if changed {
                window.setFrame(frame, display: false)
            }
        }

        deinit {
            observers.forEach(NotificationCenter.default.removeObserver)
        }
    }
}

/// Reports its own window transitions.
///
/// The previous version attached from a `DispatchQueue.main.async` one-shot. If
/// the view had no window on that turn it gave up silently and never retried,
/// and the inspector fit, which reads its width from here, was then frozen at
/// its initial value for the whole session. `viewDidMoveToWindow` fires every
/// time the view gains, loses, or changes a window, which is what makes the
/// attach retryable.
final class WindowReportingView: NSView {
    var onWindowChange: ((NSWindow?) -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onWindowChange?(window)
    }
}

/// The windowed gap patch: never claims mouse events, so it cannot block the
/// traffic lights or any click that passes over it, and repaints itself when
/// the system appearance changes.
private final class SidebarGapPatchView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = Self.sidebarCGColor
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    static var sidebarCGColor: CGColor {
        let isDark = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        if isDark {
            // Theme.sidebar dark: #12101D
            return CGColor(srgbRed: 0x12 / 255.0, green: 0x10 / 255.0, blue: 0x1D / 255.0, alpha: 1)
        }
        // Theme.sidebar light: #F3F2F8
        return CGColor(srgbRed: 0xF3 / 255.0, green: 0xF2 / 255.0, blue: 0xF8 / 255.0, alpha: 1)
    }
}

#endif
