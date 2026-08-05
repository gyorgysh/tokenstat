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
    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        // The view has no window during `makeNSView`; attach once it lands.
        DispatchQueue.main.async {
            MainActor.assumeIsolated { context.coordinator.attach(to: view) }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    @MainActor
    final class Coordinator {
        private var window: NSWindow?
        private var observers: [NSObjectProtocol] = []

        func attach(to view: NSView) {
            guard window == nil, let window = view.window else { return }
            self.window = window
            apply(window)

            let center = NotificationCenter.default
            // Moving the window to another display.
            observers.append(
                center.addObserver(
                    forName: NSWindow.didChangeScreenNotification,
                    object: window,
                    queue: .main
                ) { [weak self] _ in
                    Task { @MainActor in self?.apply(window) }
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
                    Task { @MainActor in self?.apply(window) }
                }
            )
        }

        private func apply(_ window: NSWindow) {
            DisplayFit.update(screen: window.screen)
            clamp(window)
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
#endif
