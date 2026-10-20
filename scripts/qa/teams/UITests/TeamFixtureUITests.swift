// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import XCTest

final class TeamFixtureUITests: XCTestCase {
    private func launch(_ state: String = "ready", largeText: Bool = false) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "ai.tokenstat.qa.teams")
        app.launchArguments = ["--fixture-state", state]
        if largeText { app.launchArguments.append("--fixture-large-text") }
        app.launch()
        return app
    }
    private func capture(_ app: XCUIApplication, _ name: String) {
        let image = XCTAttachment(screenshot: app.screenshot())
        image.name = name; image.lifetime = .keepAlways
        add(image)
    }
    func testInvitationStartsWithoutAccessAndRefusesRealWrites() {
        let app = launch()
        XCTAssertTrue(app.buttons["Invite member"].waitForExistence(timeout: 15))
        capture(app, "Members")
        app.buttons["Invite member"].tap()
        let handle = app.textFields["team.invitation.handle"]
        XCTAssertTrue(handle.waitForExistence(timeout: 5))
        let submit = app.buttons["team.editor.submit"]
        XCTAssertFalse(submit.isEnabled)
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Website")).firstMatch.exists)
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "No access")).firstMatch.exists)
        capture(app, "Invitation defaults")
        handle.tap(); handle.typeText("@example-invited")
        XCTAssertTrue(submit.isEnabled)
        submit.tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "This fixture is read-only")).firstMatch.waitForExistence(timeout: 5))
    }
    func testAuthorizationRequiresConsentWithLargeText() {
        let app = launch("authorization", largeText: true)
        XCTAssertTrue(app.buttons["Set up Teams"].waitForExistence(timeout: 15))
        app.buttons["Set up Teams"].tap()
        let submit = app.buttons["team.editor.submit"]
        XCTAssertTrue(submit.waitForExistence(timeout: 5))
        XCTAssertFalse(submit.isEnabled)
        capture(app, "Device consent large text")
        let consent = app.switches["team.authorization.confirm"]
        if !consent.isHittable { app.scrollViews.firstMatch.swipeUp() }
        XCTAssertTrue(consent.waitForExistence(timeout: 5))
        consent.tap()
        XCTAssertTrue(submit.isEnabled)
    }
    func testEmptyDirectoryAndUnavailableRecovery() {
        let app = launch("empty")
        XCTAssertTrue(app.staticTexts["No organizations yet"].waitForExistence(timeout: 15))
        capture(app, "Empty directory")
        app.terminate()
        app.launchArguments = ["--fixture-state", "unavailable"]
        app.launch()
        XCTAssertTrue(app.staticTexts["Teams unavailable"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons["Refresh"].exists)
        capture(app, "Teams unavailable")
    }
}
