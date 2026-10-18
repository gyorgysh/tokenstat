// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
// Compile with ReviewBuild.swift.
import Foundation

@main struct ReviewBuildTests {
    static func main() {
        let suite = "tokenstat-review-build-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        precondition(!ReviewBuild.offersDemoLogin(testFlight: false, defaults: defaults))
        precondition(ReviewBuild.offersDemoLogin(testFlight: true, defaults: defaults),
                     "TestFlight continues to offer Demo login automatically")
        var unlock = ReviewBuild.LoginLogoUnlock(testFlight: false, defaults: defaults)
        for _ in 0..<9 {
            precondition(unlock.tap() == nil)
            precondition(!ReviewBuild.offersDemoLogin(testFlight: false, defaults: defaults))
        }
        precondition(unlock.tap() == true, "The tenth tap confirms developer mode")
        precondition(ReviewBuild.offersDemoLogin(testFlight: false, defaults: defaults),
                     "Production sign-in uses the same review flag after opt-in")
        let reopened = UserDefaults(suiteName: suite)!
        precondition(ReviewBuild.offersDemoLogin(testFlight: false, defaults: reopened),
                     "The demo-login preference survives reopening the app")
        var anotherPresentation = ReviewBuild.LoginLogoUnlock(testFlight: false, defaults: reopened)
        for _ in 0..<9 {
            precondition(anotherPresentation.tap() == nil, "A presentation starts a fresh tap count")
            precondition(ReviewBuild.offersDemoLogin(testFlight: false, defaults: reopened))
        }
        precondition(anotherPresentation.tap() == false, "The next ten taps disable developer mode")
        let disabled = UserDefaults(suiteName: suite)!
        precondition(!ReviewBuild.offersDemoLogin(testFlight: false, defaults: disabled),
                     "The disabled preference survives reopening the app")
        for _ in 0..<9 { precondition(anotherPresentation.tap() == nil) }
        precondition(anotherPresentation.tap() == true, "Another ten taps enable developer mode again")

        defaults.removePersistentDomain(forName: suite)
        precondition(ReviewBuild.offersDemoLogin(testFlight: true, defaults: defaults))
        var testFlight = ReviewBuild.LoginLogoUnlock(testFlight: true, defaults: defaults)
        for _ in 0..<9 { precondition(testFlight.tap() == nil) }
        precondition(testFlight.tap() == false, "TestFlight starts enabled, so the first toggle disables it")
        precondition(!ReviewBuild.offersDemoLogin(testFlight: true, defaults: defaults),
                     "An explicit off choice overrides the automatic TestFlight offer")
        let testFlightReopened = UserDefaults(suiteName: suite)!
        precondition(!ReviewBuild.offersDemoLogin(testFlight: true, defaults: testFlightReopened))
        for _ in 0..<9 { precondition(testFlight.tap() == nil) }
        precondition(testFlight.tap() == true)
        precondition(ReviewBuild.offersDemoLogin(testFlight: true, defaults: defaults))
        print("ReviewBuild: ten-tap enable/disable cycles, persistence, fresh counters and TestFlight defaults/overrides passed")
    }
}
