// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import XCTest

final class RoutingMacUITests: XCTestCase {
    private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
    func testRoutingSheetAndLimitControls() {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.staticTexts["Conversation"].waitForExistence(timeout: 30), app.debugDescription)
        capture(app, "mac-conversation-detail")
        let setup = app.buttons["Set up routing"]
        for _ in 0..<5 {
            if setup.isHittable { break }
            app.scrollViews.firstMatch.scroll(byDeltaX: 0, deltaY: -250)
        }
        XCTAssertTrue(setup.isHittable, app.debugDescription)
        capture(app, "mac-routing-section")
        setup.click()
        XCTAssertTrue(app.buttons["Save"].waitForExistence(timeout: 10))
        capture(app, "mac-routing-settings")
        guard let settings = app.buttons.matching(identifier: "Settings").allElementsBoundByIndex.last else {
            XCTFail("Routing disclosure missing: " + app.debugDescription)
            return
        }
        for _ in 0..<5 {
            if settings.isHittable { break }
            app.scrollViews.allElementsBoundByIndex.last!.scroll(byDeltaX: 0, deltaY: -200)
        }
        settings.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.5)).click()
        XCTAssertTrue(app.checkBoxes["Use fallbacks when an agent needs sign-in"].exists, app.debugDescription)
        capture(app, "mac-routing-expanded")
        app.buttons.matching(identifier: "Cancel").firstMatch.click()
        app.radioButtons["Limit"].click()
        XCTAssertTrue(app.staticTexts["Codex usage limit reached"].waitForExistence(timeout: 10), app.debugDescription)
        capture(app, "mac-limit")
        app.buttons["Routing"].click()
        XCTAssertTrue(app.buttons["Save"].waitForExistence(timeout: 10))
        app.buttons.matching(identifier: "Cancel").firstMatch.click()
    }
}
