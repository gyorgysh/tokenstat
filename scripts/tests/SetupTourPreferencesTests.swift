// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
// Compile with SetupTourPreferences.swift.
import Foundation

@main enum SetupTourPreferencesTests {
    static func main() {
        let suite = "SetupTourPreferencesTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let tour = SetupTourPreferences.self

        precondition(tour.shouldShow(signedIn: true, defaults, firstLaunch: false))
        precondition(!tour.shouldShow(signedIn: false, defaults, firstLaunch: false))
        precondition(!tour.shouldShow(signedIn: true, defaults, firstLaunch: true))

        defaults.set("1.23", forKey: tour.legacySeenKey)
        precondition(!tour.shouldShow(signedIn: true, defaults, firstLaunch: false))
        precondition(defaults.integer(forKey: tour.seenKey) == 1)
        defaults.removeObject(forKey: tour.legacySeenKey)
        tour.markSeen(defaults)
        precondition(defaults.integer(forKey: tour.seenKey) == tour.revision)
        precondition(!tour.shouldShow(signedIn: true, defaults, firstLaunch: false))

        defaults.set(tour.revision + 1, forKey: tour.seenKey)
        tour.markSeen(defaults)
        precondition(defaults.integer(forKey: tour.seenKey) == tour.revision + 1)
        defaults.removeObject(forKey: tour.seenKey)
        defaults.set(true, forKey: tour.disabledKey)
        precondition(!tour.shouldShow(signedIn: true, defaults, firstLaunch: false))
        print("Setup tour: revision, legacy dismissal, first launch, and opt-out passed")
    }
}
