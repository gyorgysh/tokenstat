// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import AppKit
import SwiftUI
@main struct Check {
    @MainActor static func main() {
        _ = NSApplication.shared
        let context = CGContext(data: nil, width: 1000, height: 500, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let image = context.makeImage()!
        let view = ChatImageScrollView(frame: CGRect(x: 0, y: 0, width: 600, height: 400))
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = view
        view.update(image: image, zoom: 1); view.layoutSubtreeIfNeeded()
        let picture = view.documentView!
        func near(_ a: CGPoint, _ b: CGPoint) { precondition(abs(a.x-b.x) < 1 && abs(a.y-b.y) < 1, "Point moved: \(a) -> \(b)") }
        near(picture.convert(CGPoint(x: 300, y: 150), to: view), CGPoint(x: 300, y: 200))
        let anchor = CGPoint(x: 160, y: 210)
        let pixel = picture.convert(anchor, from: view)
        view.setMagnification(2, centeredAt: view.contentView.convert(anchor, from: view))
        near(picture.convert(pixel, to: view), anchor)
        view.update(image: image, zoom: 1); view.layoutSubtreeIfNeeded()
        near(picture.convert(CGPoint(x: 300, y: 150), to: view), CGPoint(x: 300, y: 200))
        precondition(ChatImageViewerGeometry.swipe(x: -200, y: 10, width: 600) == 1)
        precondition(ChatImageViewerGeometry.swipe(x: 50, y: 100, width: 600) == 0)
        var moves: [Int] = []
        view.onMove = { moves.append($0) }
        func wheel(_ x: Int32, phase: NSEvent.Phase, momentum: NSEvent.Phase = []) {
            let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: 0, wheel2: x, wheel3: 0)!
            // Core Graphics phase values differ from NSEvent.Phase raw values.
            event.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase == .began ? 1 : phase == .changed ? 2 : phase == .ended ? 4 : phase == .cancelled ? 8 : 0)
            event.setIntegerValueField(.scrollWheelEventMomentumPhase, value: momentum == .began ? 1 : momentum == .changed ? 2 : momentum == .ended ? 3 : 0)
            let native = NSEvent(cgEvent: event)!
            precondition(native.phase == phase && native.momentumPhase == momentum)
            view.scrollWheel(with: native)
        }
        wheel(0, phase: .began)
        wheel(-180, phase: .changed)
        wheel(0, phase: .ended)
        precondition(moves == [1])
        wheel(-180, phase: [], momentum: .changed)
        wheel(0, phase: [], momentum: .ended)
        precondition(moves == [1], "Momentum must not switch the next image")
        wheel(0, phase: .began)
        wheel(-180, phase: .changed)
        wheel(0, phase: .cancelled)
        wheel(0, phase: .ended)
        precondition(moves == [1], "Cancelled gestures must not switch images")
        view.update(image: image, zoom: 2)
        wheel(0, phase: .began)
        wheel(-180, phase: .changed)
        wheel(0, phase: .ended)
        precondition(moves == [1], "Zoomed scrolling must pan, not navigate")
        view.update(image: image, zoom: 1)
        wheel(0, phase: .began)
        wheel(180, phase: .changed)
        wheel(0, phase: .ended)
        precondition(moves == [1, -1], "Fit must restore swipe navigation")
        print("Native macOS image viewport: fitted centering, off-center magnification, reset, swipes, zoomed scrolling and momentum pass")
    }
}
