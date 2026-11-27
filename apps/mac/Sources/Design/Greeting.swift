// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available: source sharing and own builds are permitted.
// Store and commercial distribution of builds is reserved. See LICENSE.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

import Foundation

enum HomeGreeting {
    static func line(
        name: String,
        hasHistory: Bool,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> String {
        "\(line(hasHistory: hasHistory, now: now, calendar: calendar)), \(firstName(name))"
    }

    static func line(
        hasHistory: Bool,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> String {
        let hour = calendar.component(.hour, from: now)
        let day = calendar.ordinality(of: .day, in: .year, for: now) ?? 1
        return phrase(hour: hour, hasHistory: hasHistory, dayOfYear: day)
    }

    static func firstName(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.split(whereSeparator: \.isWhitespace).first else {
            return trimmed
        }
        return String(first)
    }

    static func phrase(hour: Int, hasHistory: Bool, dayOfYear: Int) -> String {
        let timed: String
        switch hour {
        case 5..<12: timed = L10n.text("apple.greeting.good_morning.90a90a48")
        case 12..<17: timed = L10n.text("apple.greeting.good_afternoon.d325e1bb")
        case 17..<22: timed = L10n.text("apple.greeting.good_evening.15a421e4")
        default: timed = L10n.text("apple.greeting.hello.185f8db3")
        }
        let pool = [
            timed,
            L10n.text("apple.greeting.hello.185f8db3"),
            L10n.text("apple.greeting.what_s_up.11ec53bc"),
            hasHistory ? L10n.text("apple.greeting.welcome_back.66212495") : L10n.text("apple.greeting.welcome.0e2226b5"),
            hasHistory ? L10n.text("apple.greeting.back_at_it.9ce858b7") : timed,
        ]
        return pool[abs(dayOfYear) % pool.count]
    }
}
