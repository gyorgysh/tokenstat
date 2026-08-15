// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

import Foundation

// The client is iOS and iPadOS only.
#if !os(macOS)

/// Every pull to refresh in the client goes through here.
///
/// Two jobs. It tells the top bar a refresh started, so the wordmark can
/// acknowledge the pull, and it stops a screen being pulled twenty times in
/// ten seconds from making twenty account requests. A phone in a pocket is the
/// easiest thing in the world to yank repeatedly, and every one of these
/// screens is account plane: the request leaves the device.
///
/// A pull inside the window is not ignored silently. The spinner runs for a
/// beat and the screen keeps what it has, which is the honest answer: the data
/// on screen is already this fresh. Refusing with no feedback reads as a
/// broken gesture, and people pull harder.
@MainActor
enum ClientRefresh {
    /// How close together two real fetches of one screen may be.
    ///
    /// Five seconds is far below any rate limit the account applies and far
    /// above the interval a thumb can produce by accident. Automatic refreshes
    /// (connectivity coming back, a tab appearing) do not come through here,
    /// so this bounds the deliberate gesture only.
    static let minimumInterval: TimeInterval = 5

    private static var lastRun: [String: Date] = [:]

    /// Announce a refresh to the rest of the app. Safe to call on its own for
    /// a screen with nothing to rate limit.
    static func began() {
        LogoRefresh.began()
    }

    /// Run `work` for a pull to refresh, at most once per window per screen.
    ///
    /// `key` names the screen. Two screens refresh independently: pulling
    /// Devices must not make Home's next pull a no-op.
    static func pull(_ key: String, work: () async -> Void) async {
        began()
        let now = Date()
        if let last = lastRun[key], now.timeIntervalSince(last) < minimumInterval {
            // Long enough that the spinner reads as a refresh that happened,
            // short enough that nobody waits for it.
            try? await Task.sleep(for: .milliseconds(450))
            return
        }
        await work()
        // Stamped on the way out, not on the way in. A slow fetch would
        // otherwise spend most of its window running, and the pull somebody
        // makes right after it finishes (because it finished badly) would be
        // the one that gets swallowed.
        lastRun[key] = Date()
    }
}

#endif
