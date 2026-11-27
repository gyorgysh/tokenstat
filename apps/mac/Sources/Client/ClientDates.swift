// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available: source sharing and own builds are permitted.
// Store and commercial distribution of builds is reserved. See LICENSE.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

import Foundation

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

func spokenDate(_ iso: String) -> String {
    guard let date = isoDayFormatter.date(from: iso) else { return iso }
    return date.formatted(.dateTime.day().month(.wide).year())
}

func shortDate(_ iso: String) -> String {
    guard let date = isoDayFormatter.date(from: iso) else { return iso }
    let calendar = Calendar.current
    guard calendar.component(.year, from: date) == calendar.component(.year, from: Date()) else {
        return spokenDate(iso)
    }
    return date.formatted(.dateTime.day().month(.wide))
}

let isoDayFormatter: DateFormatter = {
    let f = DateFormatter()
    f.calendar = Calendar(identifier: .gregorian)
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = .current
    f.dateFormat = "yyyy-MM-dd"
    return f
}()

#endif
