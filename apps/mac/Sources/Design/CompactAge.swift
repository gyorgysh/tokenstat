// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

import Foundation

/// "now", "5m", "3h", "2d", "6w": an age a sidebar row or a table cell can
/// afford.
///
/// Fixed English units rather than a formatter's, because the point is the
/// width: a column of "2 days ago" is a column of the same two words.
enum CompactAge {
    static func text(ms: Int64, now: Date = Date()) -> String {
        guard ms > 0 else { return "" }
        return text(Date(timeIntervalSince1970: TimeInterval(ms) / 1000), now: now)
    }

    static func text(_ date: Date, now: Date = Date()) -> String {
        let seconds = now.timeIntervalSince(date)
        switch seconds {
        case ..<60: return "now"
        case ..<3600: return "\(Int(seconds / 60))m"
        case ..<86_400: return "\(Int(seconds / 3600))h"
        case ..<(86_400 * 14): return "\(Int(seconds / 86_400))d"
        case ..<(86_400 * 365): return "\(Int(seconds / (86_400 * 7)))w"
        default: return "\(Int(seconds / (86_400 * 365)))y"
        }
    }

    /// The same, as "2d ago", or "just now" for the first minute.
    static func ago(_ date: Date, now: Date = Date()) -> String {
        let short = text(date, now: now)
        return short == "now" ? "just now" : "\(short) ago"
    }
}
