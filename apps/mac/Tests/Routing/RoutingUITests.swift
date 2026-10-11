// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import XCTest

final class RoutingUITests: XCTestCase {
    func capture(_ app: XCUIApplication, _ name: String) {
        let screenshot = app.screenshot()
        let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
            .appendingPathComponent("RoutingQA", isDirectory: true)
        try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try! screenshot.pngRepresentation.write(to: directory.appendingPathComponent(name + ".png"))
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
    func testRoutingControlsAndLimitCard() {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.staticTexts["Conversation"].waitForExistence(timeout: 30), app.debugDescription)
        let detail = app.staticTexts["Chat detail"]
        XCTAssertTrue(detail.exists)
        XCTAssertGreaterThan(detail.frame.minY, app.staticTexts["Conversation"].frame.minY)
        XCTAssertLessThan(detail.frame.minY, app.staticTexts["Routing"].firstMatch.frame.minY)
        capture(app, "iphone17-conversation-detail")
        let setup = app.buttons["Set up routing"]
        for _ in 0..<5 { if setup.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(setup.isHittable, app.debugDescription)
        capture(app, "iphone17-routing-section")
        setup.tap()
        let save = app.buttons["Save"]
        XCTAssertTrue(save.waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["high"].exists)
        XCTAssertTrue(save.isEnabled && save.isHittable)
        capture(app, "iphone17-routing-settings")
        let settings = app.buttons.matching(identifier: "Settings").allElementsBoundByIndex.last!
        for _ in 0..<5 { if settings.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(settings.isHittable, app.debugDescription)
        // Tap at the far edge of the header, away from its text and chevron.
        settings.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.5)).tap()
        XCTAssertTrue(app.switches["Use fallbacks when an agent needs sign-in"].exists, app.debugDescription)
        capture(app, "iphone17-routing-expanded")
        app.buttons.matching(identifier: "Cancel").firstMatch.tap()
        app.buttons["Limit"].tap()
        XCTAssertTrue(app.staticTexts["Codex usage limit reached"].waitForExistence(timeout: 10), app.debugDescription)
        capture(app, "iphone17-limit")
        let wait = app.switches["Continue when this limit resets"]
        XCTAssertEqual(wait.value as? String, "0")
        wait.tap()
        let cancelWait = app.buttons.matching(identifier: "Cancel").firstMatch
        XCTAssertTrue(cancelWait.waitForExistence(timeout: 5))
        XCTAssertEqual(wait.value as? String, "1")
        capture(app, "iphone17-reset-wait")
        cancelWait.tap()
        let cancelled = NSPredicate(format: "exists == false")
        expectation(for: cancelled, evaluatedWith: cancelWait)
        waitForExpectations(timeout: 5)
        wait.tap()
        XCTAssertTrue(app.buttons["Routing"].isHittable)
        app.buttons["Routing"].tap()
        XCTAssertTrue(save.waitForExistence(timeout: 10))
        app.buttons.matching(identifier: "Cancel").firstMatch.tap()
        app.buttons["Conversation"].tap()
        let draft = app.textFields.firstMatch
        XCTAssertTrue(draft.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(draft.isHittable, "Limit notice must leave the composer reachable")
        draft.tap()
        draft.typeText("QA draft remains writable")
        // The keyboard also exposes a Send key. Target the composer action.
        let send = app.buttons.matching(identifier: "paperplane").firstMatch
        expectation(for: NSPredicate(format: "isHittable == true"), evaluatedWith: send)
        waitForExpectations(timeout: 5)
        XCTAssertTrue(send.isEnabled && send.isHittable, app.debugDescription)
        capture(app, "iphone17-limit-composer-keyboard")
    }
}
