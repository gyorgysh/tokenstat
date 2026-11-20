// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

#if !os(macOS)
import Foundation

/// When the phone may ask for an App Store rating.
///
/// Only somebody who is actually using the app: a linked machine, and real
/// work since the last ask (messages sent, terminals opened). At most once
/// every fourteen days, and never in the first week after install. The system
/// applies its own limit on top, and may show nothing at all, which is fine:
/// asking is a request, not a promise.
enum ClientReviewPrompt {
    private static let lastAskedKey = "review.lastAskedAt"
    private static let firstSeenKey = "review.firstSeenAt"
    private static let usesKey = "review.usesSinceAsk"
    static let interval: TimeInterval = 14 * 24 * 3600
    static let settle: TimeInterval = 7 * 24 * 3600
    static let usesNeeded = 5

    static func noteLaunch(now: Date = Date(), _ defaults: UserDefaults = .standard) {
        if defaults.object(forKey: firstSeenKey) == nil {
            defaults.set(now, forKey: firstSeenKey)
        }
    }

    /// A message sent or a terminal opened.
    static func noteUse(_ defaults: UserDefaults = .standard) {
        defaults.set(defaults.integer(forKey: usesKey) + 1, forKey: usesKey)
    }

    static func isDue(machines: Int, now: Date = Date(), _ defaults: UserDefaults = .standard) -> Bool {
        guard let firstSeen = defaults.object(forKey: firstSeenKey) as? Date,
              machines > 0,
              now.timeIntervalSince(firstSeen) >= settle,
              defaults.integer(forKey: usesKey) >= usesNeeded else { return false }
        if let last = defaults.object(forKey: lastAskedKey) as? Date {
            return now.timeIntervalSince(last) >= interval
        }
        return true
    }

    static func markAsked(now: Date = Date(), _ defaults: UserDefaults = .standard) {
        defaults.set(now, forKey: lastAskedKey)
        defaults.set(0, forKey: usesKey)
    }
}
#endif
