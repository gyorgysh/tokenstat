// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import Foundation

/// Calendar-day positions preserve gaps without inventing zero-value records.
enum InsightDayAxis {
    private static let parser: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        return formatter
    }()

    static func position(_ key: String) -> Double? {
        guard let date = parser.date(from: key) else { return nil }
        return floor(date.timeIntervalSince1970 / 86_400)
    }

    static func domain(_ keys: [String]) -> ClosedRange<Double> {
        let days = keys.compactMap(position)
        guard let first = days.min(), let last = days.max() else { return 0...1 }
        return (first - 0.5)...(last + 0.5)
    }

    static func title(_ key: String) -> String {
        guard let date = parser.date(from: key) else { return key }
        var style = Date.FormatStyle(date: .abbreviated, time: .omitted)
        style.timeZone = TimeZone(secondsFromGMT: 0)!
        return date.formatted(style)
    }
}
