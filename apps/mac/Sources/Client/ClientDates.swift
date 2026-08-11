// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

import Foundation

// The client is iOS and iPadOS only.
#if !os(macOS)

/// `YYYY-MM-DD` as a person reads it, in one place.
///
/// Three screens turn an archive day into a title: the heatmap's VoiceOver
/// labels, the day sheet, and the Days breakdown. They each grew their own
/// formatter, which is how a sheet titled "11 August 2026" ends up over a row
/// that says "2026-08-11".
///
/// Both fall back to the raw string rather than to today's date. A screen
/// confidently showing the wrong day is worse than one showing an ISO string.

/// "11 August 2026". Used where the year matters or where it is being read
/// aloud, because a screen reader saying an ISO date says nothing.
func spokenDate(_ iso: String) -> String {
    guard let date = isoDayFormatter.date(from: iso) else { return iso }
    return date.formatted(.dateTime.day().month(.wide).year())
}

/// "11 August", with the year only when it is not this one. A column of dates
/// all carrying the same year is a column of noise.
func shortDate(_ iso: String) -> String {
    guard let date = isoDayFormatter.date(from: iso) else { return iso }
    let calendar = Calendar.current
    guard calendar.component(.year, from: date) == calendar.component(.year, from: Date()) else {
        return spokenDate(iso)
    }
    return date.formatted(.dateTime.day().month(.wide))
}

/// Fixed locale and Gregorian calendar: this parses a machine's date string,
/// which is not the reader's to interpret. Formatting it back out is.
let isoDayFormatter: DateFormatter = {
    let f = DateFormatter()
    f.calendar = Calendar(identifier: .gregorian)
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = .current
    f.dateFormat = "yyyy-MM-dd"
    return f
}()

#endif
