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
    func testInvitationReviewShowsExactAccessAndRefusesExpiredInvitations() {
        let app = launch("invitation")
        XCTAssertTrue(app.buttons["Review invitation"].waitForExistence(timeout: 15))
        app.buttons["Review invitation"].tap()
        XCTAssertTrue(app.staticTexts["Partner website"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Viewer"].exists)
        let submit = app.buttons["team.editor.submit"]
        XCTAssertTrue(submit.isEnabled)
        capture(app, "Invitation repository access")
        app.terminate()
        app.launchArguments = ["--fixture-state", "expiredInvitation"]
        app.launch()
        XCTAssertTrue(app.buttons["Review invitation"].waitForExistence(timeout: 15))
        app.buttons["Review invitation"].tap()
        XCTAssertTrue(submit.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "This invitation is no longer available")).firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Partner website"].exists)
        XCTAssertFalse(submit.isEnabled)
        capture(app, "Expired invitation")
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
    func testCheckoutPublicationAndWithdrawalRequireSeparateReviews() {
        checkoutScenario(largeText: false)
    }
    func testCheckoutPublicationWithLargeText() {
        checkoutScenario(largeText: true)
    }
    private func checkoutScenario(largeText: Bool) {
        let app = launch(largeText: largeText)
        XCTAssertTrue(app.buttons["Fixture"].waitForExistence(timeout: 15))
        app.buttons["Fixture"].tap()
        app.buttons["Checkouts"].tap()
        XCTAssertTrue(app.staticTexts["Published checkouts"].waitForExistence(timeout: 5))
        capture(app, largeText ? "Published checkouts large text" : "Published checkouts")
        app.buttons["Share a checkout"].tap()
        let review = app.buttons["team.checkout.review"]
        XCTAssertTrue(review.waitForExistence(timeout: 5))
        XCTAssertFalse(review.isEnabled)
        let picker = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Choose a checkout")).firstMatch
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        picker.tap()
        app.buttons["Website"].firstMatch.tap()
        XCTAssertTrue(review.isEnabled)
        review.tap()
        let publish = app.buttons["team.checkout.publish"]
        XCTAssertTrue(publish.waitForExistence(timeout: 5))
        XCTAssertFalse(publish.isEnabled)
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "Example Mac")).firstMatch.exists)
        capture(app, largeText ? "Checkout sharing review large text" : "Checkout sharing review")
        let confirm = app.switches["team.checkout.confirm"]
        reveal(confirm, in: app)
        confirm.tap()
        XCTAssertTrue(publish.isEnabled)
        publish.tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "This fixture is read-only")).firstMatch.waitForExistence(timeout: 5))
        app.buttons["Back"].tap()
        let stop = app.buttons["Stop sharing"].firstMatch
        if !stop.isHittable { app.scrollViews.firstMatch.swipeDown() }
        stop.tap()
        let submit = app.buttons["team.checkout.stop"]
        XCTAssertTrue(submit.waitForExistence(timeout: 5))
        XCTAssertFalse(submit.isEnabled)
        let stopConfirm = app.switches["team.checkout.stop.confirm"]
        reveal(stopConfirm, in: app)
        stopConfirm.tap()
        XCTAssertTrue(submit.isEnabled)
        capture(app, largeText ? "Checkout stop review large text" : "Checkout stop review")
        submit.tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "This fixture is read-only")).firstMatch.waitForExistence(timeout: 5))
    }
    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        let scroll = app.scrollViews.firstMatch
        for _ in 0..<8 {
            let center = CGPoint(x: element.frame.midX, y: element.frame.midY)
            if element.isHittable && scroll.frame.insetBy(dx: 0, dy: 8).contains(center) { return }
            scroll.swipeUp()
        }
        XCTAssertTrue(element.isHittable, "The control must be reachable with larger text")
    }
}
