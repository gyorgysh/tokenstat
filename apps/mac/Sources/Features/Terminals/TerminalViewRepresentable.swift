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

/// SwiftUI wrapper around SwiftTerm's `TerminalView`.
///
/// The view instance is owned by the session, not by this wrapper: `makeNSView`
/// hands back the session's own view, so the emulator's scrollback survives tab
/// switches and navigation. The wrapper's only real job is to push the current
/// system appearance into the view and to give it focus.
///
/// Callers must give this an `.id(session.id)`. Without one SwiftUI treats a
/// switch to another session as an update of the same view and never calls
/// `makeNSView` again, which leaves the previous session's terminal on screen.
struct TerminalViewRepresentable: NSViewRepresentable {
    let session: TerminalSession
    @Environment(\.colorScheme) private var colorScheme

    /// Focus is **not** claimed here, deliberately. Every session in a folder is
    /// mounted at once so that switching tabs does not relayout the terminal,
    /// which means hidden sessions are created too. A view that grabbed the
    /// keyboard on creation would let whichever session happened to mount last
    /// take it, including one nobody can see. `TerminalPane` gives focus to the
    /// session that is actually in front.
    func makeNSView(context: Context) -> TerminalView {
        session.view
    }

    func updateNSView(_ nsView: TerminalView, context: Context) {
        session.applyColors(scheme: colorScheme, to: nsView)
    }

    /// SwiftUI removes the view from the hierarchy when the pane goes away. The
    /// session keeps it, so there is nothing to tear down: leaving the default
    /// alone would be fine, but saying so stops someone adding a teardown here
    /// and quietly losing every terminal on a screen change.
    static func dismantleNSView(_ nsView: TerminalView, coordinator: ()) {}
}
#endif
