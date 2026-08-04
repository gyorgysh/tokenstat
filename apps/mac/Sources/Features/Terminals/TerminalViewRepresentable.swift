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
/// returns the session's persistent view, so the emulator's scrollback survives
/// tab switches and navigation. The wrapper's only real job is to push the
/// current system appearance into the view.
struct TerminalViewRepresentable: NSViewRepresentable {
    let session: TerminalSession
    @Environment(\.colorScheme) private var colorScheme

    func makeNSView(context: Context) -> TerminalView {
        let view = session.makeView()
        // The view is not in a window yet, so grab focus once SwiftUI has
        // placed it. The user clicked into this pane to type here.
        DispatchQueue.main.async { [weak view] in
            view?.window?.makeFirstResponder(view)
        }
        return view
    }

    func updateNSView(_ nsView: TerminalView, context: Context) {
        session.applyColors(scheme: colorScheme, to: nsView)
    }
}
#endif
