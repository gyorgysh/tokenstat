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
    func testSharedSourceKeepsPrivateDraftAtLargeText() {
        let app = XCUIApplication()
        app.launchArguments = ["--fixture-shared-source", "--fixture-large-text"]
        app.launch()
        XCTAssertTrue(app.otherElements["chat.sharing.notice"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["Stop sharing on its publishing computer."].exists)
        XCTAssertFalse(app.buttons["chat.sharing.manage"].exists)
        XCTAssertFalse(app.buttons["Send"].exists)
        let draft = app.textViews["fixture.source.draft"]
        XCTAssertTrue(draft.exists)
        XCTAssertEqual(draft.value as? String, "Private unsent note — keep this on my device.")
        if !draft.isHittable { app.scrollViews.firstMatch.swipeUp() }
        XCTAssertTrue(draft.isHittable)
        capture(app, "Shared source private draft large text")
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
    func testCheckoutAvailabilityUsesTheScopedRead() {
        let app = launch()
        XCTAssertTrue(app.buttons["Fixture"].waitForExistence(timeout: 15))
        app.buttons["Fixture"].tap()
        app.buttons["Checkouts"].tap()
        let check = app.buttons["Check availability"].firstMatch
        XCTAssertTrue(check.waitForExistence(timeout: 5))
        reveal(check, in: app)
        check.tap()
        XCTAssertTrue(app.staticTexts["Available at last check"].waitForExistence(timeout: 5))
        capture(app, "Scoped checkout availability")
    }
    func testSharedHistoryAndExplicitChatConsent() { sharedChatScenario(largeText: false) }
    func testSharedHistoryWithLargeText() { sharedChatScenario(largeText: true) }
    func testCommentPostsWithVerifiedAuthor() { commentScenario(uncertain: false, largeText: false) }
    func testUncertainAskRetriesTheSameRequestAndRecoversStop() {
        let app = launch("askUncertain")
        openSharedChat(app)
        let input = app.descendants(matching: .any)["team.ask.text"]
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        input.tap(); input.typeText("A fictional Ask")
        let send = app.buttons["team.ask.send"]
        send.tap()
        XCTAssertTrue(app.staticTexts["The fictional Ask reply was interrupted after acceptance."].waitForExistence(timeout: 5))
        XCTAssertFalse(input.isEnabled)
        send.tap()
        let stop = app.buttons["team.ask.stop"]
        XCTAssertTrue(stop.waitForExistence(timeout: 5))
        stop.tap()
        XCTAssertTrue(send.waitForExistence(timeout: 10))
        capture(app, "Lost Ask reply recovered without another run")
    }
    func testUncertainCommentSurvivesNavigationAndChecksReceiptWithLargeText() { commentScenario(uncertain: true, largeText: true) }
    func testViewerDoesNotHaveACommentComposer() {
        let app = launch("commentViewer")
        openSharedChat(app)
        XCTAssertFalse(app.buttons["team.comment.send"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["team.comment.text"].exists)
    }
    private func openSharedChat(_ app: XCUIApplication) {
        XCTAssertTrue(app.buttons["Fixture"].waitForExistence(timeout: 15))
        app.buttons["Fixture"].tap(); app.buttons["Team chats"].tap()
        let repository = app.buttons["team.chats.repository"]
        XCTAssertTrue(repository.waitForExistence(timeout: 5)); repository.tap(); app.buttons["Website"].firstMatch.tap()
        let shared = app.buttons["team.chats.open.share_" + String(repeating: "a", count: 32)]
        XCTAssertTrue(shared.waitForExistence(timeout: 5)); reveal(shared, in: app); shared.tap()
        XCTAssertTrue(app.staticTexts["Quarterly totals"].waitForExistence(timeout: 5))
    }
    private func commentScenario(uncertain: Bool, largeText: Bool) {
        let app = launch(uncertain ? "commentUncertain" : "comment", largeText: largeText)
        openSharedChat(app)
        if largeText {
            let expand = app.buttons["team.comment.expand"]
            XCTAssertTrue(expand.waitForExistence(timeout: 5)); XCTAssertTrue(expand.isHittable); expand.tap()
        }
        let input = app.descendants(matching: .any)["team.comment.text"].firstMatch
        XCTAssertTrue(input.waitForExistence(timeout: 5)); XCTAssertTrue(input.isHittable)
        input.tap(); input.typeText("A fictional UI comment")
        let send = app.buttons["team.comment.send"]
        XCTAssertTrue(send.isEnabled); XCTAssertTrue(send.isHittable)
        capture(app, largeText ? "Comment composer large text" : "Comment composer")
        send.tap()
        if uncertain {
            let check = app.buttons["team.comment.check"]
            XCTAssertTrue(check.waitForExistence(timeout: 5)); XCTAssertFalse(input.isEnabled)
            capture(app, "Uncertain comment large text")
            app.buttons["team.chat.back"].tap()
            let shared = app.buttons["team.chats.open.share_" + String(repeating: "a", count: 32)]
            XCTAssertTrue(shared.waitForExistence(timeout: 5)); reveal(shared, in: app); shared.tap()
            XCTAssertTrue(check.waitForExistence(timeout: 5)); XCTAssertFalse(input.isEnabled)
            XCTAssertTrue(String(describing: input.value).contains("A fictional UI comment"))
            check.tap()
        }
        XCTAssertTrue(app.staticTexts["Comment posted."].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["team.comment.check"].exists)
        XCTAssertTrue(app.staticTexts["A fictional UI comment"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts.matching(NSPredicate(format: "label == %@", "A fictional UI comment")).count, 1)
        capture(app, largeText ? "Accepted comment large text" : "Accepted comment")
    }
    func testCommentDraftRecoveryAfterAccessIsRemovedWithLargeText() {
        let app = launch("commentUncertain", largeText: true)
        openSharedChat(app)
        app.buttons["team.comment.expand"].tap()
        let input = app.descendants(matching: .any)["team.comment.text"].firstMatch
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        input.tap(); input.typeText("Keep my fictional comment")
        app.buttons["team.comment.send"].tap()
        XCTAssertTrue(app.buttons["team.comment.check"].waitForExistence(timeout: 5))
        app.buttons["Fixture"].tap(); app.buttons["Remove repository access"].tap()
        let drafts = app.buttons["team.drafts.open"]
        XCTAssertTrue(drafts.waitForExistence(timeout: 5)); drafts.tap()
        XCTAssertTrue(app.staticTexts["Keep my fictional comment"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Quarterly totals"].exists)
        XCTAssertGreaterThan(app.staticTexts["Comment drafts"].frame.height, 24, "The recovery sheet did not inherit the accessibility text size")
        XCTAssertTrue(app.staticTexts["Delivery isn’t confirmed."].exists)
        XCTAssertFalse(app.buttons["team.comment.send"].exists)
        capture(app, "Local comment recovery after access removal large text")
        let remove = app.buttons["team.drafts.remove"]
        reveal(remove, in: app); remove.tap()
        XCTAssertTrue(app.alerts["Remove local draft?"].waitForExistence(timeout: 5))
        capture(app, "Local draft removal disclosure large text")
        app.alerts.buttons["Cancel"].tap()
        XCTAssertTrue(app.staticTexts["Keep my fictional comment"].exists)
        remove.tap(); app.alerts.buttons["Remove draft"].tap()
        XCTAssertTrue(app.staticTexts["team.drafts.empty"].waitForExistence(timeout: 5))
    }
    func testKnownAccountRecoversLocalDraftWhenTeamsIsOffline() {
        let app = launch("draftOffline", largeText: true)
        let open = app.buttons["team.drafts.open"]
        XCTAssertTrue(open.waitForExistence(timeout: 15)); open.tap()
        XCTAssertTrue(app.staticTexts["Saved before the fictional outage"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Quarterly totals"].exists)
        XCTAssertTrue(app.staticTexts["Delivery isn’t confirmed."].exists)
        XCTAssertFalse(app.buttons["team.comment.send"].exists)
        capture(app, "Known account offline draft recovery large text")
    }
    private func sharedChatScenario(largeText: Bool) {
        let app = launch(largeText: largeText)
        XCTAssertTrue(app.buttons["Fixture"].waitForExistence(timeout: 15))
        app.buttons["Fixture"].tap()
        app.buttons["Team chats"].tap()
        let repository = app.buttons["team.chats.repository"]
        XCTAssertTrue(repository.waitForExistence(timeout: 5))
        repository.tap(); app.buttons["Website"].firstMatch.tap()
        let shared = app.buttons["team.chats.open.share_" + String(repeating: "a", count: 32)]
        XCTAssertTrue(shared.waitForExistence(timeout: 5)); reveal(shared, in: app)
        XCTAssertTrue(shared.label.contains("Quarterly totals"))
        capture(app, "Approved shared chat titles")
        shared.tap()
        XCTAssertTrue(app.staticTexts["Quarterly totals"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Local user (before Teams)")).firstMatch.exists)
        XCTAssertFalse(app.textViews.firstMatch.exists)
        capture(app, "Shared history reader")
        app.buttons["team.chat.back"].tap()
        let share = app.buttons["team.chats.share"]
        XCTAssertTrue(share.waitForExistence(timeout: 5)); reveal(share, in: app); share.tap()
        let review = app.buttons["team.chat.review"]
        XCTAssertTrue(review.waitForExistence(timeout: 5)); XCTAssertFalse(review.isEnabled)
        app.buttons["team.chat.picker"].tap(); app.buttons["Quarterly totals"].firstMatch.tap()
        XCTAssertTrue(review.isEnabled); review.tap()
        let publish = app.buttons["team.chat.publish"]
        XCTAssertTrue(publish.waitForExistence(timeout: 5)); XCTAssertFalse(publish.isEnabled)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Everyone with access to Website")).firstMatch.exists)
        capture(app, "Chat sharing consent")
        let confirm = app.switches["team.chat.confirm"]
        reveal(confirm, in: app); confirm.tap(); XCTAssertTrue(publish.isEnabled)
        publish.tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "This fixture is read-only")).firstMatch.waitForExistence(timeout: 5))
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
