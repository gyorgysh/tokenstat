// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available: source sharing and own builds are permitted.
// Distribution of builds is reserved. See LICENSE for terms.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

#if os(macOS)
import AppKit
import SwiftTerm

/// Sends the wheel to full-screen programs that asked for mouse reporting.
///
/// The app owns SGR forwarding for full-screen agent CLIs. Shell scrollback
/// remains native. A local monitor sees the event before SwiftUI, observes
/// modal ownership, and consumes an event only when it forwards it.
@MainActor
enum TerminalWheelForwarder {
    /// Wheel up and wheel down in xterm's Cb encoding.
    private static let wheelUp = 64
    private static let wheelDown = 65

    private static var monitor: Any?

    /// Install the monitor. Safe to call more than once.
    static func install() {
        guard monitor == nil else { return }
        // AppKit delivers local monitors on the main thread, which is where
        // this type and every view it touches live.
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            handle(event)
        }
    }

    /// The terminal views currently in a window, held weakly.
    ///
    /// Every wheel event in the app used to pay for a hit test of the whole
    /// window's view tree before the scroll view underneath was allowed to see
    /// it. A trackpad sends those at the display's rate, and a window showing a
    /// long pull request or a long chat has a very large tree to walk, so
    /// reading prose spent its time searching for a terminal that was either
    /// not on screen or nowhere near the pointer.
    ///
    /// The registry answers both of those cheaply. The hit test still runs, so
    /// occlusion is still decided by AppKit rather than by this file, but only
    /// once the pointer is known to be inside a terminal's own rectangle.
    @MainActor private static let live = NSHashTable<TerminalView>.weakObjects()

    static func terminalAppeared(_ view: TerminalView) { live.add(view) }
    static func terminalDisappeared(_ view: TerminalView) { live.remove(view) }

    private static func handle(_ event: NSEvent) -> NSEvent? {
        guard live.count > 0, event.deltaY.isFinite, event.deltaY != 0, let window = event.window,
              window.attachedSheet == nil, NSApp.modalWindow == nil else { return event }
        let point = event.locationInWindow
        let overTerminal = live.allObjects.contains { candidate in
            candidate.window === window
                && !candidate.isHiddenOrHasHiddenAncestor
                && candidate.convert(candidate.bounds, to: nil).contains(point)
        }
        guard overTerminal,
              let view = TerminalView.inputSurface(containing: window.contentView?.hitTest(point)),
              let terminal = view.terminalInputStateSnapshot()
        else { return event }

        // Only when a program is both full screen and listening. In the normal
        // buffer the scrollback is the right answer and the user wants it, so
        // the event goes on to SwiftTerm untouched.
        guard terminal.mouseMode != .off,
              terminal.isAlternateBuffer
        else { return event }

        let flags = TerminalMouse.sgrButton(
            base: event.deltaY > 0 ? wheelUp : wheelDown,
            event: event
        )
        let position = TerminalMouse.gridPosition(of: event, in: view, terminal: terminal)
        // One wheel event covers several lines. Clamped, because a trackpad
        // flick reports a delta that would send a hundred events at once.
        let lines = Int(min(5, max(1, abs(event.deltaY).rounded())))
        // Keep the established SGR wire format for host-backed agent CLIs.
        if let session = (view as? TerminalDropView)?.session {
            for _ in 0 ..< lines {
                session.sendBytes(
                    TerminalMouse.sgr(
                        button: flags,
                        col: position.col + 1,
                        row: position.row + 1,
                        release: false
                    )
                )
            }
        } else {
            for _ in 0 ..< lines {
                view.send(data: TerminalMouse.sgr(button: flags, col: position.col + 1, row: position.row + 1, release: false)[...])
            }
        }
        return nil
    }
}
#endif
