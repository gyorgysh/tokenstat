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

    private func swipeBack() {
        let edge = app.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.5))
        edge.press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5)))
    }

    func testVisibleControlsKeepSystemBackSwipe() {
        swipeBack()
        XCTAssertTrue(app.staticTexts["Previous page"].waitForExistence(timeout: 3))
    }

    func testHiddenControlsEdgeSwipeUsesLogicalBack() {
        app.buttons["Hide controls"].tap()
        swipeBack()
        XCTAssertTrue(app.staticTexts["Conversation list"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.staticTexts["Previous page"].exists, "The same swipe must not also pop the containing screen")
    }

    func testHiddenControlsInPushedChatCanGoBack() {
        app.buttons["Open pushed chat"].tap()
        app.buttons["Hide pushed controls"].tap()
        swipeBack()
        XCTAssertTrue(app.buttons["Chat"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.staticTexts["Previous page"].exists)
    }

    func testHiddenControlsInCoveredChatCanClose() {
        app.buttons["Open covered chat"].tap()
        app.buttons["Hide pushed controls"].tap()
        swipeBack()
        XCTAssertTrue(app.buttons["Chat"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.staticTexts["Previous page"].exists)
    }

    func testBackSwipeIgnoresContentAndShortDrags() {
        app.buttons["Hide controls"].tap()
        let middle = app.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.5))
        middle.press(forDuration: 0.05, thenDragTo: middle.withOffset(CGVector(dx: 160, dy: 0)))
        let edge = app.coordinate(withNormalizedOffset: CGVector(dx: 0.002, dy: 0.5))
        edge.press(forDuration: 0.05, thenDragTo: edge.withOffset(CGVector(dx: 18, dy: 0)))
        edge.press(forDuration: 0.05, thenDragTo: edge.withOffset(CGVector(dx: 0, dy: -100)))
        XCTAssertTrue(app.buttons["Show controls"].exists)
        app.buttons["Open sheet"].tap()
        XCTAssertTrue(app.buttons["Sheet action"].waitForExistence(timeout: 3))
        swipeBack()
        app.buttons["Close sheet"].tap()
        XCTAssertTrue(app.buttons["Show controls"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.staticTexts["Conversation list"].exists)
    }

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
