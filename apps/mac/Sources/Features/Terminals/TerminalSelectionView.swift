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
    private var modifiedArrowMonitor: Any?

    override init(frame: CGRect) {
        super.init(frame: frame)
        allowMouseReporting = false
        installModifiedArrowMonitor()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        allowMouseReporting = false
        installModifiedArrowMonitor()
    }

    override func linefeed(source: Terminal) {}

    deinit {
        if let modifiedArrowMonitor { NSEvent.removeMonitor(modifiedArrowMonitor) }
    }

    // SwiftTerm's keyDown override is not open. Intercept only this focused
    // view's shifted arrows before AppKit turns them into selection commands.
    private func installModifiedArrowMonitor() {
        modifiedArrowMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let window = self.window, window.firstResponder === self,
                  event.window === window, window.isKeyWindow,
                  window.attachedSheet == nil, NSApp.modalWindow == nil,
                  !self.isHiddenOrHasHiddenAncestor,
                  self.forwardModifiedArrow(event) else { return event }
            return nil
        }
    }

    func forwardModifiedArrow(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags
        if flags.contains(.shift), !flags.contains(.command),
           let direction: UInt8 = [123: 0x44, 124: 0x43, 125: 0x42, 126: 0x41][Int(event.keyCode)] {
            send(TerminalArrowCode.encode(direction, shift: true, option: flags.contains(.option),
                                          control: flags.contains(.control)))
            return true
        }
        return false
    }
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
#else
import UIKit
import SwiftTerm

/// SwiftTerm handles plain arrows; shifted arrows need their modifier bytes.
class ClientTerminalInputView: TerminalView {
    private lazy var arrowResponder = ClientTerminalArrowResponder(view: self)

    // SwiftTerm rejects unknown selectors in its non-open canPerformAction.
    // A responder after the view can validate our commands without changing
    // the terminal's normal copy, paste, selection or text-input handling.
    override var next: UIResponder? { arrowResponder }
    fileprivate var systemNextResponder: UIResponder? { super.next }
}

private final class ClientTerminalArrowResponder: UIResponder {
    private weak var view: ClientTerminalInputView?

    init(view: ClientTerminalInputView) {
        self.view = view
        super.init()
    }

    override var next: UIResponder? { view?.systemNextResponder }

    private lazy var modifiedArrows: [UIKeyCommand] = {
        let modifiers: [UIKeyModifierFlags] = [.shift, [.shift, .alternate], [.shift, .control], [.shift, .alternate, .control]]
        return [UIKeyCommand.inputUpArrow, UIKeyCommand.inputDownArrow,
                UIKeyCommand.inputRightArrow, UIKeyCommand.inputLeftArrow].flatMap { input in
            modifiers.map { flags in
                let command = UIKeyCommand(input: input, modifierFlags: flags, action: #selector(sendModifiedArrow(_:)))
                command.wantsPriorityOverSystemBehavior = true
                return command
            }
        }
    }()

    override var keyCommands: [UIKeyCommand]? { modifiedArrows }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(sendModifiedArrow(_:)) { return view?.isFirstResponder == true }
        return super.canPerformAction(action, withSender: sender)
    }

    @objc private func sendModifiedArrow(_ command: UIKeyCommand) {
        let direction: UInt8
        switch command.input {
        case UIKeyCommand.inputUpArrow: direction = 0x41
        case UIKeyCommand.inputDownArrow: direction = 0x42
        case UIKeyCommand.inputRightArrow: direction = 0x43
        case UIKeyCommand.inputLeftArrow: direction = 0x44
        default: return
        }
        view?.send(TerminalArrowCode.encode(direction, shift: true,
            option: command.modifierFlags.contains(.alternate), control: command.modifierFlags.contains(.control)))
    }
}
#endif
