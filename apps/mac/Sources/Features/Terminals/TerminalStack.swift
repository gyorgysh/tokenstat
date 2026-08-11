// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

#if os(macOS)
import AppKit
import SwiftTerm
import SwiftUI

/// Every terminal in a workspace, stacked, with one of them visible.
///
/// One `NSViewRepresentable` holding all of the session views, rather than one
/// per session in a SwiftUI stack. Two reasons, both learned the hard way:
///
/// - **Sizing.** A `TerminalView` has no useful intrinsic width, so a SwiftUI
///   stack asked to size itself around several of them settles on something
///   tiny and the terminal renders one character per line. Here the frames are
///   set from `bounds` and there is nothing to infer.
/// - **Switching.** Showing a terminal must not mean adding it to the view
///   hierarchy, because that lays it out again, which resizes the pty, which
///   raises SIGWINCH, which makes a full screen program repaint from scratch.
///   Every view stays mounted at the same size and switching is `isHidden`.
struct TerminalStack: NSViewRepresentable {
    let sessions: [TerminalSession]
    /// The session to show, or nil to show none, which is what happens while a
    /// file is open over the top.
    let active: TerminalSession?
    /// Whether this stack may claim first responder. False while the workspace
    /// surface is kept mounted under another destination (Home, Insights, …).
    var claimsFocus: Bool = true

    func makeNSView(context: Context) -> TerminalStackView {
        TerminalStackView()
    }

    func updateNSView(_ nsView: TerminalStackView, context: Context) {
        // Only sessions that already have an emulator. Pending ones have no
        // view on purpose: the pane draws a starting state over them instead.
        let loaded = sessions.compactMap(\.terminalViewIfLoaded)
        let activeView = active.flatMap(\.terminalViewIfLoaded)
        nsView.sync(views: loaded, active: activeView, claimsFocus: claimsFocus)
    }
}

final class TerminalStackView: NSView {
    /// The view that was in front last time, so focus is claimed on a change
    /// rather than on every update. Claiming it every time would pull the
    /// keyboard out of whatever else the user was typing in.
    private weak var shown: NSView?
    /// Last value of `claimsFocus` seen by `sync`. Falling edge clears
    /// `shown` so rising edge reclaims the keyboard when the surface returns.
    private var lastClaimsFocus = false
    /// Full buffer paint waiting for a non-zero layout. Re-parent can run
    /// while the stack still has a zero frame (fresh `makeNSView`); painting
    /// then marks an empty rect and the buffer never appears.
    private var needsFullPaint = false

    func sync(views: [TerminalView], active: TerminalView?, claimsFocus: Bool) {
        // Views just re-parented into this stack need a repaint even when they
        // stay visible: a fresh TerminalStackView after a folder switch hands
        // the same emulator instance into a new hierarchy, and without a
        // display the screen shows only a caret until the process prints.
        var reparented = Set<ObjectIdentifier>()
        for view in views where view.superview !== self {
            view.frame = bounds
            view.autoresizingMask = [.width, .height]
            addSubview(view)
            reparented.insert(ObjectIdentifier(view))
        }
        // A session closed elsewhere leaves a view here with nothing behind it.
        for sub in subviews where !views.contains(where: { $0 === sub }) {
            sub.removeFromSuperview()
        }

        var requestPaint = !reparented.isEmpty
        for view in views {
            let visible = view === active
            // isHidden and visible disagree when the view needs to flip.
            let needsFlip = view.isHidden == visible
            if needsFlip {
                view.isHidden = !visible
                if visible { requestPaint = true }
            }
        }
        if requestPaint {
            scheduleFullPaint()
        }

        if !claimsFocus {
            // Surface is mounted but not in front. Do not steal first
            // responder from Home (or any other destination). Clear `shown`
            // so the next claimsFocus rising edge reclaims the keyboard.
            if lastClaimsFocus {
                shown = nil
            }
            lastClaimsFocus = false
            return
        }

        let focusReturning = !lastClaimsFocus
        lastClaimsFocus = true

        if let active, focusReturning || shown !== active {
            shown = active
            // Hiding a view makes AppKit drop first responder, so the one now in
            // front has to take it back or the terminal accepts no keystrokes
            // until it is clicked.
            //
            // Not from here, though. `sync` is called from `updateNSView`, which
            // SwiftUI runs inside a layout pass, and moving first responder there
            // re-enters layout on a hierarchy that is already being laid out.
            // Next turn of the runloop is soon enough for a keystroke.
            //
            // Re-check `lastClaimsFocus` when the block runs: the user can leave
            // for Home in the same turn this was scheduled, and without the
            // guard the terminal would steal the keyboard from that destination.
            DispatchQueue.main.async { [weak self, weak active] in
                guard let self, let active, active.superview === self else { return }
                guard self.lastClaimsFocus else { return }
                self.window?.makeFirstResponder(active)
            }
        } else if active == nil {
            shown = nil
        }
    }

    /// Mark every visible terminal for a full redraw once bounds are real.
    private func scheduleFullPaint() {
        needsFullPaint = true
        if bounds.width > 1, bounds.height > 1 {
            paintVisibleTerminals()
        }
    }

    private func paintVisibleTerminals() {
        needsFullPaint = false
        for sub in subviews where !sub.isHidden {
            sub.setNeedsDisplay(sub.bounds)
        }
    }

    override func layout() {
        super.layout()
        // Every terminal is the full pane, visible or not. Same size for all of
        // them is what makes switching free: nothing resizes, so nothing repaints.
        for sub in subviews {
            if sub.frame != bounds { sub.frame = bounds }
        }
        // Paint after a real size exists. Re-parent often lands while the
        // stack is still 0×0; setNeedsDisplay then was a no-op and the buffer
        // never recovered.
        if needsFullPaint, bounds.width > 1, bounds.height > 1 {
            paintVisibleTerminals()
        }
    }
}
#endif
