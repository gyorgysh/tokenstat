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
        var unlock = ReviewBuild.LoginLogoUnlock(defaults: defaults)
        for _ in 0..<9 {
            precondition(!unlock.tap())
            precondition(!ReviewBuild.offersDemoLogin(testFlight: false, defaults: defaults))
        }
        precondition(unlock.tap(), "The tenth tap confirms developer mode")
        precondition(ReviewBuild.offersDemoLogin(testFlight: false, defaults: defaults),
                     "Production sign-in uses the same review flag after opt-in")
        let reopened = UserDefaults(suiteName: suite)!
        precondition(ReviewBuild.offersDemoLogin(testFlight: false, defaults: reopened),
                     "The demo-login preference survives reopening the app")
        var anotherPresentation = ReviewBuild.LoginLogoUnlock(defaults: reopened)
        precondition(!anotherPresentation.tap(), "A presentation starts a fresh tap count")
        print("ReviewBuild: production opt-in after ten taps, persistence and automatic TestFlight demo sign-in passed")
    }
}
