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
struct WindowScreenObserver: NSViewRepresentable {
    /// The window's content width, published from resize notifications.
    ///
    /// The inspector fit decision lives on this. A width read inside the split
    /// view re-enters AppKit's constraints pass (a hosted column changing its
    /// minimum size while that pass is running is exactly what threw); a
    /// resize notification is delivered outside any layout pass, so writing
    /// state from it cannot re-enter one.
    @Binding var contentWidth: CGFloat

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        let view = WindowReportingView()
        view.onWindowChange = { [weak coordinator = context.coordinator] window in
            Task { @MainActor in
                coordinator?.attach(to: window, contentWidth: $contentWidth)
            }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        // A rebuilt representable must not leave the coordinator writing
        // through a stale binding.
        MainActor.assumeIsolated {
            context.coordinator.contentWidth = $contentWidth
        }
    }

    @MainActor
    final class Coordinator {
        private var window: NSWindow?
        private var observers: [NSObjectProtocol] = []
        /// Where the measured width goes. Refreshed from `updateNSView` so a
        /// rebuilt representable never writes through a stale binding.
        var contentWidth: Binding<CGFloat>?

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
        func attach(to window: NSWindow?, contentWidth: Binding<CGFloat>) {
            guard let window else { return }
            detach()
            self.window = window
            self.contentWidth = contentWidth
            // Blend the toolbar into the window instead of giving it its own
            // material layer: with the opaque theme background below it, the
            // leading area cannot resolve to a light surface while the
            // toolbar rebuilds on a destination switch.
            window.titlebarAppearsTransparent = true
            observe(window)
            apply(window)
            publishWidth(from: window)
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
            window = nil
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
        }

        private func windowResized(_ window: NSWindow) {
            publish(quantised(window.contentLayoutRect.width, step: 4))
        }

        private func liveResizeEnded(_ window: NSWindow) {
            // Final settle, so the last width always lands even if a live
            // resize notification was dropped.
            publish(quantised(window.contentLayoutRect.width, step: 4))
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
#endif
