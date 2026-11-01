// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
// Run with terminal-native.py after building the Mac app.
import AppKit
import SwiftTerm

final class FrameCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func presented() { lock.lock(); count += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}

@MainActor final class InputCapture: TerminalViewDelegate {
    var bytes: [UInt8] = []
    nonisolated func send(source: TerminalView, data: ArraySlice<UInt8>) {
        let copied = Array(data)
        Task { @MainActor in self.bytes += copied }
    }
    nonisolated func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {}
    nonisolated func setTerminalTitle(source: TerminalView, title: String) {}
    nonisolated func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    nonisolated func scrolled(source: TerminalView, position: Double) {}
    nonisolated func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {}
    nonisolated func bell(source: TerminalView) {}
    nonisolated func clipboardCopy(source: TerminalView, content: Data) {}
    nonisolated func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
    nonisolated func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}

@main enum NativeTerminalCheck {
    @MainActor static func main() {
        setbuf(stdout, nil)
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        Task {
            do { try await check(); exit(0) }
            catch { print("FAIL \(error)"); exit(1) }
        }
        app.run()
    }

    @MainActor static func check() async throws {
        let frames = FrameCounter()
        TerminalView.onFramePresented = { frames.presented() }
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 960, height: 600),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let view = TerminalSelectionView(frame: window.contentView!.bounds)
        view.autoresizingMask = [.width, .height]
        view.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        view.changeScrollback(20_000)
        let capture = InputCapture()
        view.terminalDelegate = capture
        window.contentView!.addSubview(view)
        window.orderFrontRegardless()
        func settle() async { try? await Task.sleep(nanoseconds: 200_000_000) }
        func require(_ value: Bool, _ label: String) {
            precondition(value, label)
            print("PASS \(label)")
        }
        require(view.isUsingMetalRenderer, "Metal renderer initialized")
        let started = Date()
        view.feedOutput((0..<10_000).map { "\u{1b}[32mrow \($0)\u{1b}[0m\r\n" }.joined())
        await settle()
        require(view.getBufferAsData().count > 80_000, "10,000 colored history rows retained")
        print("10,000 colored rows plus frame settle: \(Date().timeIntervalSince(started)) seconds")
        require(view.visibleRowsText(0..<view.terminalDimensions.rows).joined().contains("row 9999"), "visible screen snapshot follows output")
        let hit = window.contentView!.hitTest(view.convert(CGPoint(x: 100, y: 100), to: nil))
        require(TerminalView.inputSurface(containing: hit) === view, "Metal child hit resolves to its terminal")
        let scrollbar = NSScroller(frame: .zero)
        view.addSubview(scrollbar)
        require(TerminalView.inputSurface(containing: scrollbar) == nil, "scrollbar is not captured as terminal input")
        scrollbar.removeFromSuperview()
        require(view.tailTextSnapshot(lines: 200).contains("row 9900") && !view.tailTextSnapshot(lines: 200).contains("row 9000"),
                "follow snapshot retains requested bounded history above screen")
        func mouse(_ type: NSEvent.EventType, x: CGFloat) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: view.convert(CGPoint(x: x, y: view.bounds.height - 24), to: nil),
                modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
                eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        view.mouseDown(with: mouse(.leftMouseDown, x: 5))
        view.mouseDragged(with: mouse(.leftMouseDragged, x: 100))
        view.mouseUp(with: mouse(.leftMouseUp, x: 100))
        let selected = view.getSelection() ?? ""
        view.feedOutput("streaming line\r\n")
        await settle()
        require(!selected.isEmpty && view.selectionActive, "selection survives streaming output")
        view.selectNone()
        view.feedOutput("\u{1b}[?2004h")
        view.pasteText("first\nsecond")
        await settle()
        require(String(decoding: capture.bytes, as: UTF8.self).contains("\u{1b}[200~first\nsecond\u{1b}[201~"), "bracketed multiline paste reaches input delegate")
        capture.bytes = []
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.shift, .control],
            timestamp: 0, windowNumber: window.windowNumber, context: nil,
            characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 123)!
        require(view.forwardModifiedArrow(event), "modified arrow is handled")
        await settle()
        require(capture.bytes == Array("\u{1b}[1;6D".utf8), "Shift-Control arrow bytes remain correct")
        view.feedOutput("\u{1b}[?1049h\u{1b}[?1000hfull screen")
        await settle()
        require(view.terminalInputStateSnapshot()?.isAlternateBuffer == true && view.terminalInputStateSnapshot()?.mouseMode != .off, "alternate buffer and mouse modes copied safely")
        view.feedOutput("\u{1b}[?1049l\u{1b}[?1000l")
        await settle()
        require(view.visibleRowsText(0..<view.terminalDimensions.rows).joined().contains("streaming line"), "normal screen restored after TUI")
        let peer = TerminalSelectionView(frame: NSRect(x: 0, y: 0, width: 400, height: 250))
        peer.feedOutput("independent Codex pane")
        view.feedOutput("independent Claude pane")
        require(!String(decoding: peer.getBufferAsData(), as: UTF8.self).contains("Claude"), "two terminal buffers remain independent")
        let longURL = "https://example.com/" + String(repeating: "abcdefghij", count: 16)
        peer.feedOutput("\r\n" + longURL + "\r\n")
        require(peer.visibleTextSnapshot().contains(longURL), "soft-wrapped links remain contiguous in copied screen text")
        view.isHidden = true
        view.feedOutput("hidden output\r\n")
        view.isHidden = false
        view.requestRedraw()
        window.setContentSize(NSSize(width: 800, height: 480))
        await settle()
        require(view.visibleRowsText(0..<view.terminalDimensions.rows).joined().contains("hidden output"), "hidden output survives reveal and resize")
        let streamStarted = Date()
        for batch in 0..<60 {
            view.feedOutput((0..<40).map { "stream \(batch):\($0)\r\n" }.joined())
            try? await Task.sleep(nanoseconds: 16_000_000)
        }
        await settle()
        print("2,400 streaming rows: \(Date().timeIntervalSince(streamStarted)) seconds; frames=\(frames.value)")
        view.scrollerStyle = .legacy
        view.feedOutput("\rabcdef")
        await settle()
        require(view.terminalCursorAnchor.map { abs($0.point.x - view.caretFrame.minX) < 0.1 } == true,
                "SSH cursor anchor excludes classic scrollbar width")
        view.drawMetalFrameNow()
        require(frames.value > 5, "Metal frames presented")
        let beforeFallback = frames.value
        try view.setUseMetal(false)
        view.feedOutput("\r\nCore Graphics fallback\r\n")
        await settle()
        require(!view.isUsingMetalRenderer && view.visibleTextSnapshot().contains("Core Graphics fallback") && frames.value > beforeFallback,
                "Core Graphics fallback renders output")
        try view.setUseMetal(true)
        view.requestRedraw()
        await settle()
        view.drawMetalFrameNow()
        require(view.isUsingMetalRenderer && view.visibleTextSnapshot().contains("Core Graphics fallback"),
                "Metal can resume without losing terminal contents")
        print("PASS native terminal integration; render loop=\(view.isUsingRenderLoop), frames=\(frames.value)")
        window.close()
    }
}
