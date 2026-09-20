// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

#if os(macOS)
import AppKit
import SwiftTerm

/// A `TerminalView` that keeps a drag selection across streaming output.
///
/// SwiftTerm clears the selection on every `feed` and linefeed while
/// `allowMouseReporting` is true, even when `mouseMode` is still off. That
/// flag stays false here until the guest enables mouse mode, so normal-buffer
/// programs can be selected without the highlight vanishing on each chunk.
/// Mouse-aware TUIs still receive SGR through `TerminalMouseForwarder`.
class TerminalSelectionView: TerminalView {
    override init(frame: CGRect) {
        super.init(frame: frame)
        allowMouseReporting = false
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        allowMouseReporting = false
    }

    override func linefeed(source: Terminal) {}
}

extension TerminalView {
    /// Feed output without wiping a drag selection unless the guest asked for
    /// mouse events. Syncs both before and after, because a chunk can turn
    /// mouse mode on mid-stream.
    func feedOutput(_ bytes: ArraySlice<UInt8>) {
        allowMouseReporting = terminal.mouseMode != .off
        feed(byteArray: bytes)
        allowMouseReporting = terminal.mouseMode != .off
    }

    /// Same policy as `feedOutput(_:)` for a text chunk.
    func feedOutput(_ text: String) {
        allowMouseReporting = terminal.mouseMode != .off
        feed(text: text)
        allowMouseReporting = terminal.mouseMode != .off
    }
}
#endif
