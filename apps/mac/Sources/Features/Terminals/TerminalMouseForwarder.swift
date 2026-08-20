// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

#if os(macOS)
import AppKit
import SwiftTerm

/// Sends clicks to programs that asked for mouse reporting.
///
/// Three things stack against SwiftTerm doing this on its own:
///
/// - `mouseDown` is `public override`, not `open`, so this module cannot
///   wrap it.
/// - The protocol field is last-write-wins. A program that enables SGR
///   (`1006`) and then urxvt (`1015`) is left on urxvt. xterm prefers SGR
///   when both are set, and Grok (every modern TUI) speaks SGR.
/// - SwiftUI can swallow the click before the `NSView` sees it.
///
/// A local monitor sees the event first. When the program is listening we
/// send SGR ourselves and keep the event away from SwiftTerm so it cannot
/// send a second encoding.
///
/// Two rules keep that from wedging the window, and both are the reason this
/// is not a one-line hit test:
///
/// - Nothing is swallowed while a dialog, a menu or another modal owns the
///   clicks. The monitor runs before the window does, so a click meant to
///   flash an open sheet went into the program behind it instead and the
///   whole window read as dead.
/// - A release is swallowed when its press was, never because the pointer
///   happens to be over a terminal now. AppKit that saw a press and never the
///   matching release stays in mouse-down tracking and stops answering
///   clicks, which is the same frozen window by a different route.
@MainActor
enum TerminalMouseForwarder {
    private static var monitor: Any?

    /// The terminal a captured press belongs to.
    ///
    /// Weak, because this is a static that outlives any one session: a strong
    /// reference here would keep a closed terminal's view alive.
    private final class Capture {
        weak var view: TerminalDropView?
        init(_ view: TerminalDropView) { self.view = view }
    }

    /// Buttons whose press this monitor swallowed, and where each one went.
    ///
    /// The whole gesture belongs to the view that took the press. Deciding a
    /// release by where the pointer is *now* loses it whenever somebody drags
    /// out of the terminal before letting go, which is how anybody selects to
    /// the edge, and the program is left with a button still held down.
    private static var captured: [Int: Capture] = [:]

    /// Install the monitor. Safe to call more than once.
    static func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [
            .leftMouseDown, .leftMouseUp, .leftMouseDragged,
            .rightMouseDown, .rightMouseUp, .rightMouseDragged,
            .otherMouseDown, .otherMouseUp, .otherMouseDragged,
        ]) { event in
            handle(event)
        }
    }

    private static func handle(_ event: NSEvent) -> NSEvent? {
        let button = event.buttonNumber
        switch event.type {
        case .leftMouseUp, .rightMouseUp, .otherMouseUp:
            guard let capture = captured.removeValue(forKey: button) else { return event }
            // Swallowed either way: AppKit never saw this button go down, so
            // handing it the release is the half a click that wedges a window.
            if let view = capture.view {
                forward(event, to: view, isUp: true, isDrag: false)
            }
            return nil
        case .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            guard let capture = captured[button] else { return event }
            // Same rule as the release: the press was taken, so the drag is
            // not AppKit's to receive, whether or not the view is still there.
            if let view = capture.view {
                forward(event, to: view, isUp: false, isDrag: true)
            }
            return nil
        default:
            guard let view = reportsMouse(event) else {
                // This press is AppKit's. Anything still held for this button
                // is from a gesture whose release went somewhere this monitor
                // could not see, over another app or another space, and
                // keeping it would swallow the release of *this* press and
                // leave the window in mouse-down tracking.
                captured.removeValue(forKey: button)
                return event
            }
            captured[button] = Capture(view)
            forward(event, to: view, isUp: false, isDrag: false)
            return nil
        }
    }

    /// The terminal under the pointer, if a program there is listening for
    /// mouse events and the click is the window's to give away.
    private static func reportsMouse(_ event: NSEvent) -> TerminalDropView? {
        guard let window = event.window,
              // A sheet, an alert or a modal has the clicks. Let AppKit answer
              // them, including by flashing the dialog the person missed.
              window.attachedSheet == nil,
              NSApp.modalWindow == nil,
              window.isKeyWindow,
              let view = window.contentView?.hitTest(event.locationInWindow) as? TerminalDropView,
              let terminal = view.terminal,
              view.allowMouseReporting,
              terminal.mouseMode != .off,
              terminal.isCurrentBufferAlternate,
              view.session != nil
        else { return nil }
        return view
    }

    /// Send the SGR bytes for one event to the view that captured its press.
    ///
    /// The view is passed in rather than found again. A gesture that started
    /// on a terminal stays that terminal's for as long as the button is down,
    /// however far the pointer has travelled since.
    ///
    /// A mode that does not report drags or releases still swallows them:
    /// they belong to a press this monitor already took, and handing one half
    /// of a click to AppKit is what leaves a window stuck.
    private static func forward(
        _ event: NSEvent,
        to view: TerminalDropView,
        isUp: Bool,
        isDrag: Bool
    ) {
        guard let terminal = view.terminal, let session = view.session else { return }

        switch terminal.mouseMode {
        case .off:
            return
        case .x10:
            if isUp || isDrag { return }
        case .vt200:
            if isDrag { return }
        case .buttonEventTracking, .anyEvent:
            break
        }

        let position = TerminalMouse.gridPosition(of: event, in: view, terminal: terminal)
        let button = TerminalMouse.xtermButton(event.buttonNumber)
        let encoded = TerminalMouse.sgrButton(
            base: isDrag ? button + 32 : button,
            event: event
        )
        session.sendBytes(
            TerminalMouse.sgr(
                button: encoded,
                col: position.col + 1,
                row: position.row + 1,
                release: isUp
            )
        )
        // Make this view first responder, or a field that already has the
        // keyboard keeps it.
        view.window?.makeFirstResponder(view)
    }
}

/// SGR mouse bytes, the encoding every modern TUI actually reads.
enum TerminalMouse {
    static func sgr(button: Int, col: Int, row: Int, release: Bool) -> [UInt8] {
        let suffix = release ? "m" : "M"
        return Array("\u{1b}[<\(button);\(col);\(row)\(suffix)".utf8)
    }

    /// xterm Cb extras: shift +4, meta/option +8, control +16.
    static func sgrButton(base: Int, event: NSEvent) -> Int {
        var button = base
        if event.modifierFlags.contains(.shift) { button += 4 }
        if event.modifierFlags.contains(.option) { button += 8 }
        if event.modifierFlags.contains(.control) { button += 16 }
        return button
    }

    /// AppKit: 0 left, 1 right, 2 middle. xterm: 0 left, 1 middle, 2 right.
    static func xtermButton(_ buttonNumber: Int) -> Int {
        switch buttonNumber {
        case 1: return 2
        case 2: return 1
        default: return 0
        }
    }

    /// The cell under the pointer. Derived from the view's bounds and the
    /// grid rather than from SwiftTerm's cell metrics, which it keeps to
    /// itself.
    static func gridPosition(
        of event: NSEvent,
        in view: TerminalView,
        terminal: Terminal
    ) -> (col: Int, row: Int) {
        let cols = max(1, terminal.cols)
        let rows = max(1, terminal.rows)
        let bounds = view.bounds
        guard bounds.width > 0, bounds.height > 0 else { return (0, 0) }
        let point = view.convert(event.locationInWindow, from: nil)
        let col = Int(point.x / (bounds.width / CGFloat(cols)))
        let row = Int((bounds.height - point.y) / (bounds.height / CGFloat(rows)))
        return (min(cols - 1, max(0, col)), min(rows - 1, max(0, row)))
    }
}
#endif
