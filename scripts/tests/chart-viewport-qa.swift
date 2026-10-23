// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
// Native macOS fixture: compile with ChartViewport.swift, then run in a GUI session.
import AppKit

private final class ChartDocument: NSView { override var isFlipped: Bool { true } }

@main struct ChartViewportQA {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 400, height: 300),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let document = ChartDocument(frame: NSRect(x: 0, y: 0, width: 400, height: 12 * 450))
        scroll.documentView = document
        window.contentView = scroll
        var mounted: Set<Int> = [], created: Set<Int> = [], retired: Set<Int> = []
        let seats = (0..<12).map { index -> ChartViewportView in
            let seat = ChartViewportView()
            seat.frame = NSRect(x: 0, y: index * 450, width: 400, height: 430)
            seat.makeContent = {
                mounted.insert(index); created.insert(index)
                return NSView()
            }
            seat.releaseContent = { _ in mounted.remove(index); retired.insert(index) }
            document.addSubview(seat)
            return seat
        }
        func settle() {
            window.contentView?.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.08))
        }
        window.orderFront(nil)
        settle()
        precondition(mounted == [0], "An eager message must mount only the chart inside its viewport")
        for index in 0..<12 {
            scroll.contentView.scroll(to: NSPoint(x: 0, y: index * 450))
            scroll.reflectScrolledClipView(scroll.contentView)
            settle()
            precondition(mounted == [index], "Every chart, including the fifth and twelfth, must mount when scrolled into view")
            precondition(seats.allSatisfy { $0.frame.height == 430 }, "Releasing a browser must retain its chart's measured seat")
        }
        precondition(created.count == 12 && retired.contains(0), "Offscreen browsers must be released and all later charts remain available")
        scroll.contentView.scroll(to: .zero)
        scroll.reflectScrolledClipView(scroll.contentView)
        settle()
        precondition(mounted == [0], "A retired chart must mount again when revisited")
        document.isHidden = true
        settle()
        precondition(mounted.isEmpty, "A hidden ancestor must retire the browser")
        document.isHidden = false
        settle()
        precondition(mounted == [0])
        document.alphaValue = 0
        settle()
        precondition(mounted.isEmpty, "An inactive opacity-zero retained pane must retire the browser")
        document.alphaValue = 1
        settle()
        precondition(mounted == [0], "Reactivating a retained pane must remount the visible chart")
        window.orderOut(nil)
        settle()
        precondition(mounted.isEmpty, "A hidden window must retire the browser")
        seats.forEach { $0.shutdown() }
        window.close()
        settle()
        precondition(mounted.isEmpty, "Queued geometry callbacks cannot remount a retired chart")
        print("Chart viewport: 12 eager seats load on scroll, release offscreen, retain height and remount on revisit; hidden ancestors/windows retire content")
    }
}
