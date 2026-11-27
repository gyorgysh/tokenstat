// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available: source sharing and own builds are permitted.
// Store and commercial distribution of builds is reserved. See LICENSE.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

#if os(macOS)
import AppKit
import SwiftTerm

class TerminalSelectionView: TerminalView {
    private var modifiedArrowMonitor: Any?

    override init(frame: CGRect) {
        super.init(frame: frame)
        try? setUseMetal(true)
        allowMouseReporting = false
        installModifiedArrowMonitor()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        try? setUseMetal(true)
        allowMouseReporting = false
        installModifiedArrowMonitor()
    }

    deinit {
        if let modifiedArrowMonitor { NSEvent.removeMonitor(modifiedArrowMonitor) }
    }

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
    static func inputSurface(containing hit: NSView?) -> TerminalView? {
        var current = hit
        while let view = current {
            if view is NSScroller { return nil }
            if let terminal = view as? TerminalView { return terminal }
            current = view.superview
        }
        return nil
    }

    func feedOutput(_ bytes: ArraySlice<UInt8>) {
        allowMouseReporting = (terminalInputStateSnapshot()?.mouseMode ?? .off) != .off
        feed(byteArray: bytes)
        allowMouseReporting = (terminalInputStateSnapshot()?.mouseMode ?? .off) != .off
    }

    func feedOutput(_ text: String) {
        allowMouseReporting = (terminalInputStateSnapshot()?.mouseMode ?? .off) != .off
        feed(text: text)
        allowMouseReporting = (terminalInputStateSnapshot()?.mouseMode ?? .off) != .off
    }
}
#else
import UIKit
import SwiftTerm

class ClientTerminalInputView: TerminalView {
    private lazy var arrowResponder = ClientTerminalArrowResponder(view: self)
    private var readingOffset: CGFloat?
    private var updatingTerminal = false
    private var movingViewport = false
    private var draggingViewport = false
    private var firstRetainedRow = 0
    private var alternateBuffer = false

    var onReadingChanged: (Bool) -> Void = { _ in }
    var scrollMode = false {
        didSet {
            guard oldValue != scrollMode else { return }
            configureScrolling()
            if !scrollMode { followLatest() }
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        try? setUseMetal(true)
        delegate = self
        configureScrolling()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        try? setUseMetal(true)
        delegate = self
        configureScrolling()
    }

    private var lineHeight: CGFloat {
        getOptimalFrameSize().height / CGFloat(max(1, terminalDimensions.rows))
    }
    private var bottomOffset: CGFloat { max(0, contentSize.height - bounds.height) }

    override var contentOffset: CGPoint {
        get { super.contentOffset }
        set { super.contentOffset = protectedOffset(newValue) }
    }

    override func setContentOffset(_ contentOffset: CGPoint, animated: Bool) {
        // UIKit also scrolls the text-input caret through this method. That
        // path can bypass the property setter, especially with a keyboard
        // animation, and send a long transcript back towards its beginning.
        let protects = !movingViewport && (updatingTerminal || !draggingViewport)
        super.setContentOffset(protectedOffset(contentOffset), animated: protects ? false : animated)
    }

    private func protectedOffset(_ proposed: CGPoint) -> CGPoint {
        guard !movingViewport, updatingTerminal || !draggingViewport else { return proposed }
        return CGPoint(x: 0, y: min(bottomOffset, max(0, readingOffset ?? bottomOffset)))
    }

    private func configureScrolling() {
        allowMouseReporting = !scrollMode
        isScrollEnabled = scrollMode
        for gesture in gestureRecognizers ?? [] where gesture is UIPanGestureRecognizer && gesture !== panGestureRecognizer {
            gesture.isEnabled = !scrollMode
        }
    }

    nonisolated override func mouseModeChanged(source: Terminal) {
        super.mouseModeChanged(source: source)
        DispatchQueue.main.async { [weak self] in self?.configureScrolling() }
    }

    nonisolated override func bufferActivated(source: Terminal) {
        super.bufferActivated(source: source)
        DispatchQueue.main.async { [weak self] in self?.followLatest() }
    }

    private func updateRetainedRows() {
        guard let snapshot = terminalContentSnapshot(region: .history(maximumScrollbackRows: 0)) else { return }
        let alternate = snapshot.inputState.isAlternateBuffer
        let retained = alternate ? 0 : max(0, snapshot.liveTopRow - 4_000)
        if alternateBuffer != alternate || retained < firstRetainedRow {
            setReadingOffset(nil)
        } else if let held = readingOffset {
            readingOffset = max(0, held - CGFloat(retained - firstRetainedRow) * lineHeight)
        }
        alternateBuffer = alternate
        firstRetainedRow = retained
    }

    override func layoutSubviews() {
        let wasUpdating = updatingTerminal
        updatingTerminal = true
        defer { updatingTerminal = wasUpdating }
        super.layoutSubviews()
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) { draggingViewport = true }
    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate { draggingViewport = false }
    }
    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) { draggingViewport = false }
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard scrollMode, draggingViewport, !updatingTerminal, !movingViewport else { return }
        setReadingOffset(contentOffset.y < bottomOffset - lineHeight / 2 ? max(0, contentOffset.y) : nil)
    }

    private func setReadingOffset(_ offset: CGFloat?) {
        let wasReading = readingOffset != nil
        readingOffset = offset
        if wasReading != (offset != nil) { onReadingChanged(offset != nil) }
    }

    func followLatest() {
        setReadingOffset(nil)
        movingViewport = true
        setContentOffset(CGPoint(x: 0, y: bottomOffset), animated: false)
        movingViewport = false
    }

    func feedLiveOutput(_ bytes: ArraySlice<UInt8>) {
        let wasUpdating = updatingTerminal
        updatingTerminal = true
        defer { updatingTerminal = wasUpdating }
        super.feed(byteArray: bytes)
        updateRetainedRows()
        if readingOffset == nil { followLatest() }
    }

    override var next: UIResponder? { arrowResponder }
    fileprivate var systemNextResponder: UIResponder? { super.next }
}

extension TerminalView {
    func feedOutput(_ bytes: ArraySlice<UInt8>) {
        if let view = self as? ClientTerminalInputView { view.feedLiveOutput(bytes) }
        else { feed(byteArray: bytes) }
    }

    func feedOutput(_ text: String) { feedOutput(ArraySlice(text.utf8)) }
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

extension TerminalView {
    func visibleTextSnapshot() -> String {
        Self.logicalText(terminalStateSnapshot().visibleRows.map { ($0.text, $0.isWrapped) })
    }

    func tailTextSnapshot(lines: Int) -> String {
        let count = max(1, lines)
        guard let snapshot = terminalContentSnapshot(
            region: .history(maximumScrollbackRows: max(0, count - terminalDimensions.rows))) else { return "" }
        return Self.logicalText(snapshot.rows.suffix(count).map { ($0.text, $0.isWrapped) })
    }

    private static func logicalText(_ rows: [(text: String, wrapped: Bool)]) -> String {
        var result = ""
        for (index, row) in rows.enumerated() {
            if index > 0 && !row.wrapped { result += "\n" }
            result += row.text
        }
        return result
    }

    var terminalCursorAnchor: (point: CGPoint, lineHeight: CGFloat)? {
        let state = terminalStateSnapshot()
        let height = getOptimalFrameSize().height / CGFloat(max(1, state.dimensions.rows))
        guard caretFrame.height > 0, height > 0 else { return nil }
        return (CGPoint(x: caretFrame.minX, y: CGFloat(state.cursor.row) * height), height)
    }
}
