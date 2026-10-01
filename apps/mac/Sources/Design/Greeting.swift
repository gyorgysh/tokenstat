// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

import Foundation

/// A short greeting that uses the device clock, not a server timezone.
///
/// The phrase is stable for the rest of the local day so a refresh does not
/// swap "Hello" for "What's up". The website does the same pick after mount,
/// for the same reason: UTC on the server is the wrong afternoon.
enum HomeGreeting {
    /// "Good afternoon, Gyorgy"
    static func line(
        name: String,
        hasHistory: Bool,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> String {
        "\(line(hasHistory: hasHistory, now: now, calendar: calendar)), \(firstName(name))"
    }

    /// "Good afternoon", with no name. A signed-in account that set
    /// neither a display name nor a handle is still signed in, and the
    /// greeting must not claim otherwise.
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
        // Fixed length so a later hasHistory flip only changes the returning
        // slots, not which index the day lands on.
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
