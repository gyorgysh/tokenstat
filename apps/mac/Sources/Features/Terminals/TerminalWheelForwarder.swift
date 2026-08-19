// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

#if os(macOS)
import AppKit
import SwiftTerm

/// Sends the wheel to full-screen programs that asked for mouse reporting.
///
/// SwiftTerm always scrolls its own scrollback on a wheel event. That is right
/// for a shell and wrong for everything else: a full-screen program runs in the
/// alternate buffer, which has no scrollback by design, so the wheel does
/// nothing at all and an agent CLI's own output cannot be scrolled back. Every
/// terminal worth using forwards the wheel as a mouse event once the program
/// has asked for mouse reporting, and lets the program scroll itself.
///
/// This is a local event monitor rather than a `TerminalView` subclass because
/// SwiftTerm declares `scrollWheel` `public override` and not `open`, so it
/// cannot be overridden from here. The monitor sees the event first and returns
/// nil when it has dealt with it, which keeps it away from SwiftTerm.
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

    private static func handle(_ event: NSEvent) -> NSEvent? {
        guard event.deltaY != 0,
              let window = event.window,
              let view = window.contentView?.hitTest(event.locationInWindow) as? TerminalView,
              let terminal = view.terminal
        else { return event }

        // Only when a program is both full screen and listening. In the normal
        // buffer the scrollback is the right answer and the user wants it, so
        // the event goes on to SwiftTerm untouched.
        guard view.allowMouseReporting,
              terminal.mouseMode != .off,
              terminal.isCurrentBufferAlternate
        else { return event }

        let flags = TerminalMouse.sgrButton(
            base: event.deltaY > 0 ? wheelUp : wheelDown,
            event: event
        )
        let position = TerminalMouse.gridPosition(of: event, in: view, terminal: terminal)
        // One wheel event covers several lines. Clamped, because a trackpad
        // flick reports a delta that would send a hundred events at once.
        let lines = min(5, max(1, Int(abs(event.deltaY).rounded())))
        // SGR, not SwiftTerm's last-write protocol. A program that enabled
        // both 1006 and 1015 is left on urxvt inside SwiftTerm, and Grok
        // does not read that encoding.
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
                terminal.sendEvent(buttonFlags: flags, x: position.col, y: position.row)
            }
        }
        return nil
    }
}
#endif
