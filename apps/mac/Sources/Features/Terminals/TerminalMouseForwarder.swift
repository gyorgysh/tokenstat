// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available: source sharing and own builds are permitted.
// Store and commercial distribution of builds is reserved. See LICENSE.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

#if os(macOS)
import AppKit
import SwiftTerm

/// Sends clicks to programs that asked for mouse reporting.
///
/// The app's event monitor owns each gesture from press to release, including
/// across SwiftUI hit testing and modal transitions. Keep the established SGR
/// encoding for the host-backed agent CLIs and prevent duplicate native reports.
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

    private final class Capture {
        weak var view: TerminalDropView?
        init(_ view: TerminalDropView) { self.view = view }
    }

    private static var captured: [Int: Capture] = [:]

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

    private static func reportsMouse(_ event: NSEvent) -> TerminalDropView? {
        guard let window = event.window,
              // A sheet, an alert or a modal has the clicks. Let AppKit answer
              // them, including by flashing the dialog the person missed.
              window.attachedSheet == nil,
              NSApp.modalWindow == nil,
              window.isKeyWindow,
              let view = TerminalView.inputSurface(containing: window.contentView?.hitTest(event.locationInWindow)) as? TerminalDropView,
              let terminal = view.terminalInputStateSnapshot(),
              terminal.mouseMode != .off,
              terminal.isAlternateBuffer,
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
        guard let terminal = view.terminalInputStateSnapshot(), let session = view.session else { return }

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
        view.window?.makeFirstResponder(view)
    }
}

enum TerminalMouse {
    static func sgr(button: Int, col: Int, row: Int, release: Bool) -> [UInt8] {
        let suffix = release ? "m" : "M"
        return Array("\u{1b}[<\(button);\(col);\(row)\(suffix)".utf8)
    }

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

    static func gridPosition(
        of event: NSEvent,
        in view: TerminalView,
        terminal: TerminalInputStateSnapshot
    ) -> (col: Int, row: Int) {
        let cols = max(1, terminal.dimensions.cols)
        let rows = max(1, terminal.dimensions.rows)
        let bounds = view.bounds
        guard bounds.width > 0, bounds.height > 0 else { return (0, 0) }
        let point = view.convert(event.locationInWindow, from: nil)
        let col = Int(point.x / (bounds.width / CGFloat(cols)))
        let row = Int((bounds.height - point.y) / (bounds.height / CGFloat(rows)))
        return (min(cols - 1, max(0, col)), min(rows - 1, max(0, row)))
    }
}
#endif
