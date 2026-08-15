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
/// - **Full screen:** same `fullSizeContentView` hosting so toolbar leading
///   items stay next to the traffic lights immediately (dropping that mask
///   moved them into a deferred full-screen toolbar host that only reflowed
///   after a mouse pass). Titlebar is opaque, corners flattened, traffic
///   lights unhidden. No custom drawn buttons, no `NSToolbar` reassignment.
struct WindowScreenObserver: NSViewRepresentable {
    /// The window's content width, published from resize notifications.
    ///
    /// The inspector fit decision lives on this. A width read inside the split
    /// view re-enters AppKit's constraints pass (a hosted column changing its
    /// minimum size while that pass is running is exactly what threw); a
    /// resize notification is delivered outside any layout pass, so writing
    /// state from it cannot re-enter one.
    @Binding var contentWidth: CGFloat
    /// Whether the window is currently full screen. Published for SwiftUI;
    /// chrome itself is applied only when this bit flips, not every frame.
    @Binding var isFullScreen: Bool
    /// Height of the titlebar band above `contentLayoutRect`, in points.
    /// Detail chrome uses this to sit in that band (same row as traffic
    /// lights) instead of under an empty second row.
    @Binding var titlebarInset: CGFloat

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
                    isFullScreen: $isFullScreen,
                    titlebarInset: $titlebarInset
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
            context.coordinator.titlebarInset = $titlebarInset
            // Do **not** call applyChrome on every SwiftUI pass. Re-setting
            // titlebar flags every frame fights the toolbar's own layout and
            // is what left the navigation mark unpositioned until a mouse
            // pass over the bar. Chrome is applied on attach and on enter/exit
            // full screen only.
        }
    }

    @MainActor
    final class Coordinator {
        private var window: NSWindow?
        /// Exposed for callers that need the attached window.
        var attachedWindow: NSWindow? { window }
        private var observers: [NSObjectProtocol] = []
        /// Paints the sidebar column's slice of the titlebar with the sidebar
        /// colour. Used windowed and full screen while `fullSizeContentView`
        /// is on (content draws under the toolbar on both).
        private var sidebarGapPatch: NSView?
        /// Same paint on the trailing inspector column. `.inspector` sits on
        /// the lifted detail, so without this the titlebar band over Files /
        /// Changes / History (and Insights) is liquid glass or unfocused grey.
        private var inspectorGapPatch: NSView?
        /// Last chrome mode applied. Avoids re-entry when notifications fire
        /// more than once for the same transition.
        private var lastChromeFullScreen: Bool?
        /// Keeps the toolbar on icon-only. Our marks are circular custom views
        /// with hover help strings; "Icon and Text" has nothing to show and
        /// blanked the controls. Observation snaps the mode back if the
        /// system context menu is used.
        private var toolbarDisplayModeObservation: NSKeyValueObservation?
        /// Where the measured width goes. Refreshed from `updateNSView` so a
        /// rebuilt representable never writes through a stale binding.
        var contentWidth: Binding<CGFloat>?
        var isFullScreen: Binding<Bool>?
        var titlebarInset: Binding<CGFloat>?

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
            isFullScreen: Binding<Bool>,
            titlebarInset: Binding<CGFloat>
        ) {
            guard let window else { return }
            detach()
            self.window = window
            self.contentWidth = contentWidth
            self.isFullScreen = isFullScreen
            self.titlebarInset = titlebarInset
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
            lockToolbarDisplayMode(in: window)
            publishTitlebarInset(from: window)
        }

        private func detach() {
            observers.forEach(NotificationCenter.default.removeObserver)
            observers.removeAll()
            toolbarDisplayModeObservation?.invalidate()
            toolbarDisplayModeObservation = nil
            sidebarGapPatch?.removeFromSuperview()
            sidebarGapPatch = nil
            inspectorGapPatch?.removeFromSuperview()
            inspectorGapPatch = nil
            lastChromeFullScreen = nil
            window = nil
        }

        /// Icon-only only. Labels live in the hover help, not under the glyph.
        ///
        /// The system toolbar menu still offers "Icon and Text"; our custom
        /// circular marks have no title to show in that mode, so the control
        /// vanished. Force icon-only and re-assert if the menu is used.
        private func lockToolbarDisplayMode(in window: NSWindow) {
            guard let toolbar = window.toolbar else { return }
            toolbar.displayMode = .iconOnly
            // No Customize sheet either: the bar is fixed app chrome, not a
            // user-assembled palette.
            toolbar.allowsUserCustomization = false
            toolbarDisplayModeObservation?.invalidate()
            toolbarDisplayModeObservation = toolbar.observe(
                \.displayMode,
                options: [.new]
            ) { toolbar, _ in
                guard toolbar.displayMode != .iconOnly else { return }
                // Snap back on the next turn so we are not inside KVO.
                DispatchQueue.main.async {
                    if toolbar.displayMode != .iconOnly {
                        toolbar.displayMode = .iconOnly
                    }
                }
            }
        }

        /// Switch between the windowed transparent-titlebar look and the
        /// full-screen opaque bar. Called on attach and on enter/exit full
        /// screen only, never from `updateNSView`.
        func applyChrome(on window: NSWindow, force: Bool = false) {
            let fullScreen = window.styleMask.contains(.fullScreen)
            if !force, lastChromeFullScreen == fullScreen {
                // Still keep lights visible and the gap patch sized; those are
                // cheap and can drift after a split resize.
                revealTrafficLights(on: window)
                updateSidebarTopGap(in: window)
                updateInspectorTopGap(in: window)
                return
            }
            lastChromeFullScreen = fullScreen
            if fullScreen {
                applyFullScreenChrome(on: window)
            } else {
                applyWindowedChrome(on: window)
            }
            revealTrafficLights(on: window)
            // App controls live in DetailChromeBar, not NSToolbar. An empty
            // toolbar host still steals a content band; hide the host. Traffic
            // lights stay on the titlebar (standardWindowButton), not the
            // toolbar. This is not a compact-chrome height trick.
            hideEmptyAppToolbar(on: window)
            updateSidebarTopGap(in: window)
            updateInspectorTopGap(in: window)
            publishTitlebarInset(from: window)
        }

        private func revealTrafficLights(on window: NSWindow) {
            // Real system buttons only. Custom drawn circles are never used.
            for buttonType: NSWindow.ButtonType in [.closeButton, .miniaturizeButton, .zoomButton] {
                if let button = window.standardWindowButton(buttonType) {
                    button.isHidden = false
                    button.alphaValue = 1
                }
            }
        }

        /// Hide the system toolbar when it has no app items left.
        ///
        /// Visibility only: do not change window toolbar style or titlebar
        /// height to "match" DetailChromeBar. After hide, re-check lights.
        private func hideEmptyAppToolbar(on window: NSWindow) {
            guard let toolbar = window.toolbar else { return }
            // Stock sidebar toggle may still be mid-strip; treat only real
            // remaining items as reason to keep the host.
            let hasAppItem = toolbar.items.contains { item in
                !Self.isSystemSidebarToggle(item)
            }
            toolbar.isVisible = hasAppItem
            revealTrafficLights(on: window)
        }

        /// Titlebar band height above the content layout rect, in points.
        ///
        /// With fullSizeContentView the content view extends under the
        /// titlebar; contentLayoutRect does not. The difference is the blank
        /// band DetailChromeBar was sitting under.
        private func publishTitlebarInset(from window: NSWindow) {
            guard let contentView = window.contentView else { return }
            // contentLayoutRect is in window coordinates; contentView origin
            // matches with fullSizeContentView.
            let inset = max(0, contentView.bounds.maxY - window.contentLayoutRect.maxY)
            // Quantise so sub-point jitter does not thrash SwiftUI layout.
            let next = (inset * 2).rounded() / 2
            guard let titlebarInset, titlebarInset.wrappedValue != next else { return }
            titlebarInset.wrappedValue = next
        }

        /// Windowed: content draws under a transparent titlebar so the sidebar
        /// colour can meet the traffic-light band. The gap patch fills the
        /// strip above the leading column.
        private func applyWindowedChrome(on window: NSWindow) {
            // Always keep fullSizeContentView. The unified titlebar hosts
            // `.navigation` toolbar items next to the traffic lights only while
            // this mask is set; dropping it for full screen deferred that
            // placement until a mouse pass over the bar.
            if !window.styleMask.contains(.fullSizeContentView) {
                window.styleMask.insert(.fullSizeContentView)
            }
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            if #available(macOS 11.0, *) {
                window.titlebarSeparatorStyle = .none
            }
            restoreContentCorners(in: window)
        }

        /// Full screen: same content-view mask as windowed (so toolbar items
        /// keep their host), opaque titlebar, square edges, native lights.
        private func applyFullScreenChrome(on window: NSWindow) {
            if !window.styleMask.contains(.fullSizeContentView) {
                window.styleMask.insert(.fullSizeContentView)
            }
            // Opaque bar so the top still reads as real chrome, while the
            // toolbar item host stays the same as windowed.
            window.titlebarAppearsTransparent = false
            window.titleVisibility = .hidden
            if #available(macOS 11.0, *) {
                window.titlebarSeparatorStyle = .none
            }
            flattenFullScreenContent(in: window)
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
                    Task { @MainActor in
                        self?.updateSidebarTopGap(in: window)
                        self?.updateInspectorTopGap(in: window)
                    }
                }
            )
            observers.append(
                center.addObserver(
                    forName: NSWindow.willEnterFullScreenNotification,
                    object: window,
                    queue: .main
                ) { [weak self] _ in
                    Task { @MainActor in
                        // styleMask may not yet contain `.fullScreen` here, so
                        // call the full-screen path directly.
                        self?.applyFullScreenChrome(on: window)
                        self?.lastChromeFullScreen = true
                        self?.revealTrafficLights(on: window)
                        self?.hideEmptyAppToolbar(on: window)
                        self?.updateSidebarTopGap(in: window)
                        self?.updateInspectorTopGap(in: window)
                        self?.publishTitlebarInset(from: window)
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
                        self?.applyFullScreenChrome(on: window)
                        self?.lastChromeFullScreen = true
                        self?.revealTrafficLights(on: window)
                        self?.hideEmptyAppToolbar(on: window)
                        self?.stripSystemSidebarToggle(in: window)
                        self?.updateSidebarTopGap(in: window)
                        self?.updateInspectorTopGap(in: window)
                        self?.publishTitlebarInset(from: window)
                        // One follow-up after AppKit finishes full-screen
                        // layout. Inset can change when the toolbar host goes.
                        try? await Task.sleep(for: .milliseconds(100))
                        guard self?.window === window else { return }
                        self?.stripSystemSidebarToggle(in: window)
                        self?.hideEmptyAppToolbar(on: window)
                        self?.revealTrafficLights(on: window)
                        self?.updateSidebarTopGap(in: window)
                        self?.updateInspectorTopGap(in: window)
                        self?.flattenFullScreenContent(in: window)
                        self?.publishTitlebarInset(from: window)
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
                        // styleMask still has `.fullScreen` during willExit.
                        self?.applyWindowedChrome(on: window)
                        self?.lastChromeFullScreen = false
                        self?.revealTrafficLights(on: window)
                        self?.hideEmptyAppToolbar(on: window)
                        self?.updateSidebarTopGap(in: window)
                        self?.updateInspectorTopGap(in: window)
                        self?.publishTitlebarInset(from: window)
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
                        self?.applyWindowedChrome(on: window)
                        self?.lastChromeFullScreen = false
                        self?.revealTrafficLights(on: window)
                        self?.hideEmptyAppToolbar(on: window)
                        self?.stripSystemSidebarToggle(in: window)
                        self?.scheduleSidebarToggleStrip(for: window)
                        self?.updateSidebarTopGap(in: window)
                        self?.updateInspectorTopGap(in: window)
                        self?.publishTitlebarInset(from: window)
                    }
                }
            )
        }

        private func windowResized(_ window: NSWindow) {
            publish(quantised(window.contentLayoutRect.width, step: 4))
            updateSidebarTopGap(in: window)
            updateInspectorTopGap(in: window)
            publishTitlebarInset(from: window)
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
            updateInspectorTopGap(in: window)
            publishTitlebarInset(from: window)
        }

        /// Fill the gap above the sidebar column so the titlebar band shows
        /// the sidebar colour rather than the toolbar grey (windowed and full
        /// screen; both keep `fullSizeContentView`).
        private func updateSidebarTopGap(in window: NSWindow) {
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

        /// Fill the gap above the trailing inspector column the same way.
        /// Hidden when the inspector is closed or floating (no column).
        private func updateInspectorTopGap(in window: NSWindow) {
            guard let contentView = window.contentView,
                  let frameInContent = Self.inspectorColumnFrame(in: window)
            else {
                inspectorGapPatch?.isHidden = true
                return
            }
            let gapAboveColumn = contentView.bounds.height - frameInContent.maxY
            let layoutInContent = contentView.convert(window.contentLayoutRect, from: nil)
            let gapAboveLayout = max(0, contentView.bounds.maxY - layoutInContent.maxY)
            let gap = max(gapAboveColumn, gapAboveLayout)
            guard gap > 1 else {
                inspectorGapPatch?.isHidden = true
                return
            }
            let patch = inspectorGapPatch ?? SidebarGapPatchView()
            inspectorGapPatch = patch
            patch.frame = NSRect(
                x: frameInContent.minX - 1,
                y: contentView.bounds.height - gap,
                width: frameInContent.width + 1,
                height: gap
            )
            if patch.superview !== contentView {
                contentView.addSubview(patch, positioned: .below, relativeTo: nil)
            }
            patch.isHidden = false
        }

        /// Frame of the trailing inspector column, in content-view coordinates.
        /// Nil when the inspector is closed, floating, or not yet in the tree.
        private static func inspectorColumnFrame(in window: NSWindow) -> NSRect? {
            guard let wrapper = inspectorColumnWrapper(in: window),
                  let contentView = window.contentView
            else {
                return nil
            }
            return wrapper.convert(wrapper.bounds, to: contentView)
        }

        /// The trailing inspector column's wrapper, found by geometry rather
        /// than class name. `.inspector` is a split item of about 400 points
        /// on the trailing edge. A full-width detail pane must not match.
        private static func inspectorColumnWrapper(in window: NSWindow) -> NSView? {
            guard let contentView = window.contentView else { return nil }
            return trailingInspectorColumn(in: contentView)
        }

        private static func trailingInspectorColumn(in view: NSView) -> NSView? {
            if let split = view as? NSSplitView {
                let found = split.subviews
                    .filter {
                        $0.frame.maxX > split.bounds.width - 8
                            && $0.frame.minX > 80
                            && $0.frame.width > 200
                            && $0.frame.width < 520
                            && $0.frame.height > 120
                    }
                    .sorted { $0.frame.minX < $1.frame.minX }
                    .last
                if let found { return found }
            }
            for sub in view.subviews {
                if let found = trailingInspectorColumn(in: sub) {
                    return found
                }
            }
            return nil
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
                    // Toolbar can appear after first attach; re-lock mode.
                    self.lockToolbarDisplayMode(in: window)
                    self.hideEmptyAppToolbar(on: window)
                    // contentLayoutRect settles after strip/hide; re-measure.
                    self.publishTitlebarInset(from: window)
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
