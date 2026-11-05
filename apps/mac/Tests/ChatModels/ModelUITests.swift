// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import XCTest
import UIKit
final class ModelUITests: XCTestCase {
    let app = XCUIApplication()
    override func setUpWithError() throws { continueAfterFailure = false; app.launch() }
    func waitReady() {
        let ready = app.staticTexts["ready"]
        XCTAssertTrue(ready.waitForExistence(timeout: 10))
        XCTAssertTrue(wait { ready.label == "ready" })
    }
    func wait(_ condition: @escaping () -> Bool) -> Bool {
        XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in condition() }, object: nil)], timeout: 15) == .completed
    }
    func number(_ key: String) -> Int { Int(app.staticTexts[key].label.split(separator: " ").last ?? "") ?? -1 }
    func capture(_ label: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot()); attachment.name = label; attachment.lifetime = .keepAlways; add(attachment)
    }
    func whitePixels(in area: CGRect? = nil, wholeScreen: Bool = false) -> Int {
        let screenshot = (wholeScreen ? XCUIScreen.main.screenshot() : app.screenshot()).image.cgImage!
        let scale = CGFloat(screenshot.width) / app.frame.width
        let frame = area ?? app.webViews.firstMatch.frame
        let crop = CGRect(x: frame.minX * scale, y: frame.minY * scale, width: frame.width * scale, height: frame.height * scale)
        let image = screenshot.cropping(to: crop)!
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        pixels.withUnsafeMutableBytes { bytes in
            let context = CGContext(data: bytes.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return stride(from: 0, to: pixels.count, by: 4).filter { pixels[$0] > 220 && pixels[$0+1] > 220 && pixels[$0+2] > 220 }.count
    }
    func testOrbitKeepsTranscriptStillAndStopsRenderingAtRest() {
        waitReady(); capture("model-before-orbit")
        XCTAssertGreaterThan(whitePixels(), 1000, "The model must be visibly rendered")
        let position = number("position"), initial = number("draws")
        let web = app.webViews.firstMatch
        web.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7)).press(forDuration: 0.1,
            thenDragTo: web.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.3)), withVelocity: .slow, thenHoldForDuration: 0.2)
        XCTAssertTrue(wait { self.number("draws") > initial })
        XCTAssertEqual(number("position"), position, accuracy: 2, "Orbit must not scroll the transcript")
        capture("model-after-orbit")
        // Wait for OrbitControls damping to settle, then verify an idle interval.
        var last = -1, stable = 0
        for _ in 0..<30 {
            Thread.sleep(forTimeInterval: 0.2)
            let now = number("draws")
            stable = now == last ? stable + 1 : 0; last = now
            if stable == 5 { break }
        }
        XCTAssertEqual(stable, 5, "A model at rest must stop submitting draws")
        let idle = number("draws")
        Thread.sleep(forTimeInterval: 0.5)
        XCTAssertEqual(number("draws"), idle)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85)).press(forDuration: 0.1,
            thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6)), withVelocity: .slow, thenHoldForDuration: 0.2)
        XCTAssertTrue(wait { self.number("position") > position + 50 }, "Dragging outside the model must still scroll the transcript")
    }
    func testPinchZoomAndReset() {
        waitReady()
        let before = whitePixels(), position = number("position")
        XCTAssertGreaterThan(before, 1000)
        let textFrame = app.staticTexts["Chat row 0"].frame
        XCTAssertGreaterThan(whitePixels(in: textFrame, wholeScreen: true), 50)
        capture("model-before-pinch")
        app.webViews.firstMatch.pinch(withScale: 0.5, velocity: -1)
        XCTAssertTrue(wait { self.whitePixels() < before * 8 / 10 }, "Pinching inward should visibly shrink the model")
        let smaller = whitePixels()
        capture("model-pinched-smaller")
        XCTAssertTrue(wait { self.whitePixels(in: textFrame, wholeScreen: true) > 50 }, "Surrounding text must remain visible after zooming out")
        app.webViews.firstMatch.pinch(withScale: 2, velocity: 1)
        XCTAssertTrue(wait { self.whitePixels() > smaller * 12 / 10 }, "Pinching outward should visibly enlarge the model")
        XCTAssertEqual(number("position"), position, accuracy: 2)
        capture("model-zoomed")
        XCTAssertTrue(wait { self.whitePixels(in: textFrame, wholeScreen: true) > 50 }, "Surrounding text must remain visible after zooming in")
        app.webViews.buttons["Reset view"].tap()
        XCTAssertTrue(wait { abs(self.whitePixels() - before) < before / 10 }, "Reset restores the original view")
    }
    func testPinchKeepsSurroundingTextVisible() {
        waitReady()
        let frame = app.staticTexts["Chat row 0"].frame
        XCTAssertGreaterThan(whitePixels(in: frame), 50)
        app.webViews.firstMatch.pinch(withScale: 0.5, velocity: -1)
        capture("surrounding-text-after-pinch")
        let screen = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screen.name = "whole-screen-after-pinch"; screen.lifetime = .keepAlways; add(screen)
        print("Surrounding text pixels: app=\(whitePixels(in: frame)), screen=\(whitePixels(in: frame, wholeScreen: true))")
        XCTAssertTrue(wait { self.whitePixels(in: frame, wholeScreen: true) > 50 }, "Chat text outside the model must remain visible after pinching")
    }
    func testUnmountAndFailureRecovery() {
        waitReady()
        app.buttons["toggle"].tap()
        XCTAssertTrue(wait { !self.app.webViews.firstMatch.exists })
        app.buttons["toggle"].tap(); waitReady()
        app.buttons["size"].tap()
        XCTAssertTrue(app.staticTexts["This model cannot be previewed here. Open the original file."].waitForExistence(timeout: 5))
        XCTAssertFalse(app.webViews.firstMatch.exists)
        app.buttons["size"].tap(); waitReady()
        XCTAssertGreaterThan(whitePixels(), 1000)
    }
}
