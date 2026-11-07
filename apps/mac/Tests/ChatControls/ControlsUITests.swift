// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import XCTest

final class ControlsUITests: XCTestCase {
    private var app: XCUIApplication!
    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.buttons["Chat"].waitForExistence(timeout: 10))
    }
    override func tearDownWithError() throws { app?.terminate() }

    func testDirectionalSwipesPreserveTabsAndTaps() {
        let changes = app.buttons["Changes"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        changes.press(forDuration: 0.05, thenDragTo: changes.withOffset(CGVector(dx: -60, dy: 0)))
        XCTAssertTrue(app.staticTexts["Panel Chat"].exists)
        let swipe = app.buttons["Changes"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        swipe.press(forDuration: 0.05, thenDragTo: swipe.withOffset(CGVector(dx: 0, dy: -70)))
        XCTAssertTrue(app.buttons["Show controls"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Panel Chat"].exists)
        let top = app.buttons["Message at top"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        top.press(forDuration: 0.05, thenDragTo: top.withOffset(CGVector(dx: 0, dy: 80)))
        XCTAssertTrue(app.buttons["Chat"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Tapped 0"].exists)
        app.buttons["Changes"].tap()
        XCTAssertTrue(app.staticTexts["Panel Changes"].exists)
    }

    func testCollapsedControlsAllowTopMessageTapsAndIgnoreSheets() {
        app.buttons["Hide controls"].tap()
        app.buttons["Message at top"].tap()
        XCTAssertTrue(app.staticTexts["Tapped 1"].exists)
        app.buttons["Open sheet"].tap()
        let sheetAction = app.buttons["Sheet action"]
        XCTAssertTrue(sheetAction.waitForExistence(timeout: 3))
        let point = sheetAction.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        point.press(forDuration: 0.05, thenDragTo: point.withOffset(CGVector(dx: 0, dy: 80)))
        app.buttons["Close sheet"].tap()
        XCTAssertTrue(app.buttons["Show controls"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["Chat"].exists)
    }
}
