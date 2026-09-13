// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

import Foundation

/// Wall-clock copy for jobs that fire on a connected computer.
///
/// The host scheduler owns the zone. A phone in another zone must not convert
/// 09:00 there into the device clock, and it must not invent a zone when the
/// host has not named one.
enum HostScheduleClock {
    /// IANA name the host sent, or nil when it is missing or unnamed.
    static func resolved(_ identifier: String?) -> String? {
        guard let identifier else { return nil }
        let trimmed = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "unknown" else { return nil }
        return trimmed
    }

    /// Short place name. `America/New_York` becomes `New York`.
    static func place(_ identifier: String?) -> String? {
        guard let identifier = resolved(identifier) else { return nil }
        if identifier == "UTC" || identifier == "GMT" { return "UTC" }
        guard let slash = identifier.lastIndex(of: "/") else { return identifier }
        return String(identifier[identifier.index(after: slash)...]).replacingOccurrences(of: "_", with: " ")
    }

    /// Hour and minute in the named zone. Tests use this so locale cannot hide a
    /// conversion to the device clock.
    static func civilTime(_ date: Date, timezone: String?) -> (hour: Int, minute: Int)? {
        guard let parts = civilParts(date, timezone: timezone) else { return nil }
        return (parts.hour, parts.minute)
    }

    /// Day in the host zone, without a time. `14 Sep`, or `14 Sep 2027` when
    /// the year is not this one there.
    static func shortDay(_ date: Date, timezone: String?) -> String? {
        guard let parts = civilParts(date, timezone: timezone) else { return nil }
        let month = months[parts.month - 1]
        if parts.year == currentYear(in: timezone) {
            return "\(parts.day) \(month)"
        }
        return "\(parts.day) \(month) \(parts.year)"
    }

    /// Next-run timestamp in the host zone. Nil when the zone is unknown, so
    /// the caller does not fall back to this device. Civil parts, not
    /// `Date.FormatStyle`: a region override on English UI can print
    /// year-first punctuation that still looks like this device's clock.
    static func wallClock(_ date: Date, timezone: String?) -> String? {
        guard let parts = civilParts(date, timezone: timezone),
              let day = shortDay(date, timezone: timezone)
        else { return nil }
        return "\(day), \(String(format: "%d:%02d", parts.hour, parts.minute))"
    }

    static func nextRun(_ date: Date, timezone: String?) -> String {
        guard let wall = wallClock(date, timezone: timezone) else {
            return "on the connected computer"
        }
        if let place = place(timezone) {
            return "\(wall) in \(place)"
        }
        return wall
    }

    static func clock(_ timezone: String?) -> String? {
        place(timezone)
    }

    static func timeCaption(hostName: String, timezone: String?) -> String {
        let host = hostName.trimmingCharacters(in: .whitespacesAndNewlines)
        if let place = place(timezone) {
            if host.isEmpty {
                return "This time is on the connected computer (\(place))."
            }
            return "This time is on \(host) (\(place))."
        }
        if host.isEmpty {
            return "This time is on the connected computer, not this device."
        }
        return "This time is on \(host), not this device."
    }

    static func listSubtitle(
        cadence: String,
        next: Date?,
        enabled: Bool,
        repeats: Bool,
        timezone: String?
    ) -> String {
        guard enabled, repeats, let next, let day = shortDay(next, timezone: timezone) else {
            return cadence
        }
        if let place = place(timezone) {
            return "\(cadence) · \(day), \(place)"
        }
        return "\(cadence) · \(day)"
    }

    private static let months = [
        "Jan", "Feb", "Mar", "Apr", "May", "Jun",
        "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
    ]

    private struct CivilParts {
        var year: Int
        var month: Int
        var day: Int
        var hour: Int
        var minute: Int
    }

    private static func civilParts(_ date: Date, timezone: String?) -> CivilParts? {
        guard let identifier = resolved(timezone), let zone = TimeZone(identifier: identifier) else {
            return nil
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        guard let year = parts.year,
              let month = parts.month, month >= 1, month <= 12,
              let day = parts.day,
              let hour = parts.hour,
              let minute = parts.minute
        else { return nil }
        return CivilParts(year: year, month: month, day: day, hour: hour, minute: minute)
    }

    private static func currentYear(in timezone: String?) -> Int? {
        guard let identifier = resolved(timezone), let zone = TimeZone(identifier: identifier) else {
            return nil
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return calendar.component(.year, from: Date())
    }
}
