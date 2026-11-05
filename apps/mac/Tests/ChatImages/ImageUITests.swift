// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import XCTest
import UIKit
final class ImageUITests: XCTestCase {
    let app = XCUIApplication()
    override func setUpWithError() throws { continueAfterFailure = false; app.launch() }
    func viewport() -> XCUIElement { app.descendants(matching: .any).matching(identifier: "viewport").firstMatch }
    func zoom() -> Double { Double(app.staticTexts["zoom"].label.replacingOccurrences(of: "zoom ", with: "").replacingOccurrences(of: ",", with: ".")) ?? -1 }
    func marker() -> CGPoint {
        let image = app.screenshot().image.cgImage!
        let w = image.width, h = image.height
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        bytes.withUnsafeMutableBytes { raw in
            let context = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        var x = 0, y = 0, n = 0
        for row in 0..<h { for col in 0..<w { let i = (row * w + col) * 4
            if bytes[i] > 230 && bytes[i+1] < 40 && bytes[i+2] < 40 { x += col; y += row; n += 1 }
        } }
        XCTAssertGreaterThan(n, 8, "Image marker disappeared")
        return CGPoint(x: Double(x) / Double(max(1,n)), y: Double(y) / Double(max(1,n)))
    }
    func testPinchAnchor() {
        XCTAssertTrue(viewport().waitForExistence(timeout: 5))
        let before = marker()
        viewport().pinch(withScale: 2, velocity: 1)
        let after = marker()
        XCTAssertLessThan(abs(before.x-after.x), 8); XCTAssertLessThan(abs(before.y-after.y), 8)
        XCTAssertGreaterThan(zoom(), 1.5)
    }
    func testDoubleTapAnchor() {
        XCTAssertTrue(viewport().waitForExistence(timeout: 5))
        let before = marker()
        let frame = viewport().frame
        let scale = CGFloat(app.screenshot().image.cgImage!.width) / app.frame.width
        let anchor = CGPoint(x: (frame.minX + frame.width * 0.4) * scale, y: (frame.minY + frame.height * 0.5) * scale)
        viewport().coordinate(withNormalizedOffset: CGVector(dx: 0.4, dy: 0.5)).doubleTap()
        XCTAssertEqual(zoom(), 2, accuracy: 0.01)
        let after = marker()
        XCTAssertLessThan(abs(after.x - (before.x * 2 - anchor.x)), 8)
        XCTAssertLessThan(abs(after.y - (before.y * 2 - anchor.y)), 8)
    }
    func testZoomedPanStaysWithinImage() {
        XCTAssertTrue(viewport().waitForExistence(timeout: 5))
        viewport().doubleTap()
        XCTAssertEqual(zoom(), 2, accuracy: 0.01)
        let before = marker()
        let frame = viewport().frame
        let scale = CGFloat(app.screenshot().image.cgImage!.width) / app.frame.width
        let start = viewport().coordinate(withNormalizedOffset: CGVector(dx: 0.65, dy: 0.5))
        let end = viewport().coordinate(withNormalizedOffset: CGVector(dx: 0.35, dy: 0.55))
        start.press(forDuration: 0.1, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.3)
        let after = marker()
        // UIKit consumes some initial movement before recognizing a drag.
        XCTAssertGreaterThan(before.x - after.x, frame.width * 0.15 * scale)
        XCTAssertLessThan(before.x - after.x, frame.width * 0.35 * scale)
        XCTAssertLessThan(abs(after.y - before.y), 8, "Letterboxed image must stay vertically centered")
        XCTAssertEqual(app.staticTexts["page"].label, "page 0")
    }
    func testSwipeAfterReset() {
        XCTAssertTrue(viewport().waitForExistence(timeout: 5))
        viewport().swipeLeft(); XCTAssertEqual(app.staticTexts["page"].label, "page 1")
        viewport().pinch(withScale: 2, velocity: 1)
        viewport().swipeLeft(); XCTAssertEqual(app.staticTexts["page"].label, "page 1")
        app.buttons["reset"].tap()
        viewport().swipeRight(); XCTAssertEqual(app.staticTexts["page"].label, "page 0")
    }
    func testPinchBackToFitThenSwipe() {
        XCTAssertTrue(viewport().waitForExistence(timeout: 5))
        viewport().pinch(withScale: 2, velocity: 1)
        for _ in 0..<3 {
            if zoom() <= 1.01 { break }
            viewport().pinch(withScale: 0.2, velocity: -1)
        }
        XCTAssertEqual(zoom(), 1, accuracy: 0.01)
        XCTAssertEqual(app.staticTexts["page"].label, "page 0")
        viewport().swipeLeft(); XCTAssertEqual(app.staticTexts["page"].label, "page 1")
    }
}
