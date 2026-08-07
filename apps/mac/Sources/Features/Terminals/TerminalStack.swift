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

    func makeNSView(context: Context) -> TerminalStackView {
        TerminalStackView()
    }

    func updateNSView(_ nsView: TerminalStackView, context: Context) {
        nsView.sync(
            views: sessions.map(\.view),
            active: sessions.first { $0 === active }?.view
        )
    }
}

final class TerminalStackView: NSView {
    /// The view that was in front last time, so focus is claimed on a change
    /// rather than on every update. Claiming it every time would pull the
    /// keyboard out of whatever else the user was typing in.
    private weak var shown: NSView?

    func sync(views: [TerminalView], active: TerminalView?) {
        for view in views where view.superview !== self {
            view.frame = bounds
            view.autoresizingMask = [.width, .height]
            addSubview(view)
        }
        // A session closed elsewhere leaves a view here with nothing behind it.
        for sub in subviews where !views.contains(where: { $0 === sub }) {
            sub.removeFromSuperview()
        }

        for view in views {
            let visible = view === active
            if view.isHidden == visible {
                view.isHidden = !visible
                // A view that was hidden while output arrived has not drawn it.
                if visible { view.setNeedsDisplay(view.bounds) }
            }
        }

        if let active, shown !== active {
            shown = active
            // Hiding a view makes AppKit drop first responder, so the one now in
            // front has to take it back or the terminal accepts no keystrokes
            // until it is clicked.
            //
            // Not from here, though. `sync` is called from `updateNSView`, which
            // SwiftUI runs inside a layout pass, and moving first responder there
            // re-enters layout on a hierarchy that is already being laid out.
            // Next turn of the runloop is soon enough for a keystroke.
            DispatchQueue.main.async { [weak self, weak active] in
                guard let self, let active, active.superview === self else { return }
                self.window?.makeFirstResponder(active)
            }
        } else if active == nil {
            shown = nil
        }
    }

    override func layout() {
        super.layout()
        // Every terminal is the full pane, visible or not. Same size for all of
        // them is what makes switching free: nothing resizes, so nothing repaints.
        for sub in subviews {
            if sub.frame != bounds { sub.frame = bounds }
        }
    }
}
#endif
