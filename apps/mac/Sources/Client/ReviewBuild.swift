// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

import Foundation

/// Whether this copy of the app came from TestFlight or from App Review rather
/// than from the App Store.
///
/// Exists for one reason: every screen in the client is behind a sign-in, and
/// sign-in is Apple, Google, GitHub or X through a page. There is no password
/// field, so Apple's usual "here are the demo account details" cannot be
/// honoured. TestFlight and App Review offer the demo sign-in by default.
/// Ten taps on the login logo toggle that offer in any build.
///
/// What this gates is a query flag on the sign-in page, nothing more. The
/// account it leads to is a real one on the account service, and whether the
/// page offers it is the site's decision. Read `ClientWebAuth.start`.
///
/// The receipt is what tells them apart. A build delivered by TestFlight, and a
/// build App Review is running, carry `sandboxReceipt`; an App Store install
/// carries `receipt`. App Review therefore sees the door, which is the point,
/// and an App Store install needs the explicit developer-mode gesture.
///
/// An absent or unrecognised receipt never enables the automatic offer.
enum ReviewBuild {
    static func offersDemoLogin(testFlight: Bool = isTestFlight, defaults: UserDefaults = .standard) -> Bool {
        (defaults.object(forKey: LoginLogoUnlock.preference) as? Bool) ?? testFlight
    }

    /// Counts only taps made on this login presentation. The one persisted
    /// preference changes the web sign-in flag; it grants no local access.
    struct LoginLogoUnlock {
        fileprivate static let preference = "client.developerDemoLoginEnabled"
        private let defaults: UserDefaults
        private let testFlight: Bool
        private var taps = 0

        init(testFlight: Bool = ReviewBuild.isTestFlight, defaults: UserDefaults = .standard) {
            self.testFlight = testFlight
            self.defaults = defaults
        }

        /// Nil until the tenth tap; then the newly persisted on/off state.
        mutating func tap() -> Bool? {
            taps += 1
            guard taps == 10 else { return nil }
            taps = 0
            let enabled = !ReviewBuild.offersDemoLogin(testFlight: testFlight, defaults: defaults)
            defaults.set(enabled, forKey: Self.preference)
            return enabled
        }
    }

    static let isTestFlight: Bool = {
        #if targetEnvironment(simulator)
        // A simulator has no receipt, and a developer running one is not a
        // reviewer. Debug builds get the door so the flow can be worked on;
        // a release build in a simulator does not.
        #if DEBUG
        return true
        #else
        return false
        #endif
        #else
        guard let url = Bundle.main.appStoreReceiptURL else { return false }
        return url.lastPathComponent == "sandboxReceipt"
        #endif
    }()
}
