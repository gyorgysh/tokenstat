// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available: source sharing and own builds are permitted.
// Store and commercial distribution of builds is reserved. See LICENSE.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

import Foundation

enum CompactAge {
    static func text(ms: Int64, now: Date = Date()) -> String {
        guard ms > 0 else { return "" }
        return text(Date(timeIntervalSince1970: TimeInterval(ms) / 1000), now: now)
    }

    static func text(_ date: Date, now: Date = Date()) -> String {
        let seconds = now.timeIntervalSince(date)
        switch seconds {
        case ..<60: return L10n.text("apple.compactage.now.ed5eb9a3")
        case ..<3600: return L10n.text("apple.compactage.0_m.7f5ea983", "\(Int(seconds / 60))")
        case ..<86_400: return L10n.text("apple.compactage.0_h.360a8af5", "\(Int(seconds / 3600))")
        case ..<(86_400 * 14): return L10n.text("apple.compactage.0_d.6c61dd03", "\(Int(seconds / 86_400))")
        case ..<(86_400 * 365): return L10n.text("apple.compactage.0_w.f5fe75d1", "\(Int(seconds / (86_400 * 7)))")
        default: return L10n.text("apple.compactage.0_y.2956709f", "\(Int(seconds / (86_400 * 365)))")
        }
    }

    static func ago(_ date: Date, now: Date = Date()) -> String {
        let short = text(date, now: now)
        return short == "now" ? L10n.text("apple.compactage.just_now.7ddb44d8") : L10n.text("apple.compactage.0_ago.cace2682", "\(short)")
    }
}
