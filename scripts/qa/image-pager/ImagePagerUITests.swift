// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import XCTest
import UIKit

final class ImagePagerUITests: XCTestCase {
    let app = XCUIApplication()
    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        app.launch()
        XCTAssertTrue(viewport.waitForExistence(timeout: 5))
    }
    private var viewport: XCUIElement { app.descendants(matching: .any).matching(identifier: "viewport").firstMatch }
    private var zoom: Double {
        Double(app.staticTexts["zoom"].label.replacingOccurrences(of: "zoom ", with: "")
            .replacingOccurrences(of: ",", with: ".")) ?? -1
    }
    private func assertPage(_ index: Int, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(app.staticTexts["page"].label, "page \(index)", file: file, line: line)
    }
    private func marker() -> CGPoint {
        let image = app.screenshot().image.cgImage!
        let w = image.width, h = image.height
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        bytes.withUnsafeMutableBytes { raw in
            let context = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8,
                bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        var x = 0, y = 0, n = 0
        for row in 0..<h { for col in 0..<w {
            let i = (row * w + col) * 4
            if bytes[i] > 230 && bytes[i + 1] < 40 && bytes[i + 2] < 40 { x += col; y += row; n += 1 }
        } }
        XCTAssertGreaterThan(n, 8, "Image marker disappeared")
        return CGPoint(x: Double(x) / Double(max(1, n)), y: Double(y) / Double(max(1, n)))
    }
    func testPinchAnchor() {
        let before = marker()
        viewport.pinch(withScale: 2, velocity: 1)
        let after = marker()
        XCTAssertGreaterThan(zoom, 1.5)
        XCTAssertLessThan(abs(before.x - after.x), 8)
        XCTAssertLessThan(abs(before.y - after.y), 8)
    }
    func testDoubleTapAnchor() {
        let before = marker()
        let frame = viewport.frame
        let scale = CGFloat(app.screenshot().image.cgImage!.width) / app.frame.width
        let anchor = CGPoint(x: (frame.minX + frame.width * 0.4) * scale,
                             y: (frame.minY + frame.height * 0.5) * scale)
        viewport.coordinate(withNormalizedOffset: CGVector(dx: 0.4, dy: 0.5)).doubleTap()
        XCTAssertEqual(zoom, 2, accuracy: 0.01)
        let after = marker()
        XCTAssertLessThan(abs(after.x - (before.x * 2 - anchor.x)), 8)
        XCTAssertLessThan(abs(after.y - (before.y * 2 - anchor.y)), 8)
    }
    func testZoomedPanThenResetAndSwipe() {
        viewport.swipeLeft(); assertPage(1)
        viewport.pinch(withScale: 2, velocity: 1)
        XCTAssertGreaterThan(zoom, 1.5)
        // Repeated edge pans must not advance the outer pager.
        viewport.swipeLeft(); viewport.swipeLeft(); assertPage(1)
        viewport.swipeRight(); viewport.swipeRight(); assertPage(1)
        app.buttons["reset"].tap()
        XCTAssertEqual(zoom, 1, accuracy: 0.01)
        viewport.swipeRight(); assertPage(0)
    }
    func testPinchBackToFitThenSwipe() {
        viewport.pinch(withScale: 2, velocity: 1)
        XCTAssertGreaterThan(zoom, 1.5)
        viewport.pinch(withScale: 0.4, velocity: -1)
        XCTAssertEqual(zoom, 1, accuracy: 0.01)
        assertPage(0)
        viewport.swipeLeft(); assertPage(1)
    }
    func testBoundsAndCanceledSwipe() {
        viewport.swipeRight(); assertPage(0)
        let from = viewport.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.5))
        let to = viewport.coordinate(withNormalizedOffset: CGVector(dx: 0.56, dy: 0.5))
        from.press(forDuration: 0.1, thenDragTo: to, withVelocity: .slow, thenHoldForDuration: 0.3)
        assertPage(0)
        viewport.swipeLeft(); viewport.swipeLeft(); viewport.swipeLeft()
        assertPage(2)
        XCTAssertFalse(app.buttons["Next"].isEnabled)
    }
    func testButtonsThenPinchAndSwipe() {
        app.buttons["Next"].tap(); assertPage(1)
        viewport.pinch(withScale: 2, velocity: 1)
        XCTAssertGreaterThan(zoom, 1.5)
        app.buttons["reset"].tap()
        viewport.swipeLeft(); assertPage(2)
        app.buttons["Previous"].tap(); assertPage(1)
        viewport.pinch(withScale: 2, velocity: 1)
        XCTAssertGreaterThan(zoom, 1.5)
    }
    func testReducedMotionButtonsAndGestures() {
        app.terminate()
        app.launchArguments = ["--reduced-motion"]
        app.launch()
        XCTAssertTrue(viewport.waitForExistence(timeout: 5))
        app.buttons["Next"].tap(); assertPage(1)
        viewport.pinch(withScale: 2, velocity: 1)
        XCTAssertGreaterThan(zoom, 1.5)
        app.buttons["reset"].tap()
        viewport.swipeRight(); assertPage(0)
    }
}
