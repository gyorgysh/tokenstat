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
        }

        /// Hide AppKit's stock sidebar toggle item so only our custom marks
        /// (with ⌘B / ⌥⌘B in the help string) remain.
        private func stripSystemSidebarToggle(in window: NSWindow) {
            guard let toolbar = window.toolbar else { return }
            for item in toolbar.items {
                let id = item.itemIdentifier.rawValue
                // Stock identifiers across recent macOS releases.
                let isSystemSidebar =
                    item.itemIdentifier == .toggleSidebar
                    || id.contains("toggleSidebar")
                    || id.contains("ToggleSidebar")
                    || id.contains("sidebar.toggle")
                guard isSystemSidebar else { continue }
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
