// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

import Foundation

enum SetupTourPreferences {
    // Bump when the tour introduces something people should see.
    static let revision = 1
    static let seenKey = "setupTour.seenRevision"
    static let legacySeenKey = "setupTour.seenVersion"
    static let disabledKey = "setupTour.disabled"
    static let launchedKey = "setupTour.launchedBefore"

    /// Take the first-launch snapshot before setting the flag for next time.
    static let isFirstLaunch = recordLaunch()
    private static func recordLaunch() -> Bool {
        let defaults = UserDefaults.standard
        let before = defaults.bool(forKey: launchedKey)
        defaults.set(true, forKey: launchedKey)
        return !before
    }

    static func noteLaunch() { _ = isFirstLaunch }

    static func shouldShow(signedIn: Bool, _ defaults: UserDefaults = .standard,
                           firstLaunch: Bool = isFirstLaunch) -> Bool {
        guard signedIn, !firstLaunch, !defaults.bool(forKey: disabledKey) else { return false }
        var seenRevision = defaults.integer(forKey: seenKey)
        // A dismissal under the old app-version scheme counts as seeing
        // revision 1. It remains revision 1 when a later tour is introduced.
        if seenRevision == 0, defaults.string(forKey: legacySeenKey)?.isEmpty == false {
            seenRevision = 1
            defaults.set(seenRevision, forKey: seenKey)
        }
        return seenRevision < revision
    }

    static func markSeen(_ defaults: UserDefaults = .standard) {
        let seenRevision = defaults.integer(forKey: seenKey)
        defaults.set(max(seenRevision, revision), forKey: seenKey)
    }

    static func requestShow() {
        NotificationCenter.default.post(name: .tokenstatOpenSetupTour, object: nil)
    }
}

extension Notification.Name {
    static let tokenstatOpenSetupTour = Notification.Name("ai.tokenstat.setupTour.open")
}
