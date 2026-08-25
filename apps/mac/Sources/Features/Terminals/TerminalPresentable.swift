// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

import SwiftTerm

/// A session this stack can show: something that owns a `TerminalView`.
///
/// The only thing the AppKit layer below ever needed. `TerminalStackView`
/// works in views, not sessions, and the representable was the one piece that
/// named `TerminalSession` concretely, which is what kept SSH out of the split
/// and tab machinery the workspace terminals have had all along.
///
/// Generic rather than existential on purpose: a `[any TerminalPresentable]`
/// would push a downcast into every caller's `onActivate`, and there is no
/// screen that mixes the two kinds in one stack.
@MainActor
protocol TerminalPresentable: AnyObject, Identifiable {
    /// The emulator, if one has been made. Nil for a session that is still
    /// connecting: the pane draws a starting state over those instead.
    var terminalViewIfLoaded: TerminalView? { get }
}
