// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

import Foundation

enum ComposerLimits {
    static func compactRow<T>(rows: [(display: String, window: T)],
                              label: (T) -> String, percent: (T) -> Double) -> (display: String, window: T)? {
        let valid = rows.filter { percent($0.window).isFinite && percent($0.window) >= 0 }
        return valid.first { tag(for: label($0.window)) == "5h" }
            ?? valid.first { tag(for: label($0.window)) == "7d" }
            ?? valid.first
    }
    static func tag(for label: String) -> String? {
        let plain = label.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let spaced = plain.replacingOccurrences(of: "·", with: " · ")
        let norm = spaced.replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        if norm == "5 hour" || norm == "5h" || norm.hasSuffix("· 5 hour") || norm.hasSuffix("· 5h") { return "5h" }
        if plain == "5-hour" || plain.hasSuffix("· 5-hour") { return "5h" }
        if norm.contains("per week") || norm == "weekly" || norm.hasSuffix("· weekly") || norm == "7d" || norm == "7 day" { return "7d" }
        if plain == "weekly" || plain.hasSuffix("· weekly") { return "7d" }
        if norm.contains("per month") || norm == "monthly" || norm.hasSuffix("· monthly") || norm == "30d" { return "30d" }
        if plain == "monthly" || plain.hasSuffix("· monthly") { return "30d" }
        return nil
    }

    static func codexHeadlineRows<T>(
        windows: [T],
        label: (T) -> String,
        scope: (T) -> String? = { _ in nil }
    ) -> [(display: String, window: T)] {
        var seat: [String: (general: Bool, window: T)] = [:]
        var rest: [(display: String, window: T)] = []
        for window in windows {
            let name = label(window).trimmingCharacters(in: .whitespacesAndNewlines)
            guard let tag = tag(for: name) else {
                rest.append((name, window))
                continue
            }
            let general = scope(window)?.lowercased() == "general"
            if let taken = seat[tag], taken.general || !general {
                continue
            }
            seat[tag] = (general, window)
        }
        let generalSeats = seat.filter { $0.value.general }
        let use = generalSeats.isEmpty ? seat : generalSeats
        let seated = use.map { (display: $0.key, rank: rank($0.key), window: $0.value.window) }
            .sorted { $0.rank < $1.rank }
        return seated.map { ($0.display, $0.window) } + rest
    }

    static func badgeRows<T>(
        windows: [T],
        label: (T) -> String,
        scope: (T) -> String? = { _ in nil }
    ) -> [(display: String, window: T)] {
        var best: [(display: String, rank: Int, index: Int, window: T)] = []
        var rest: [(display: String, window: T)] = []
        for (index, window) in windows.enumerated() {
            let name = label(window).trimmingCharacters(in: .whitespacesAndNewlines)
            guard let tag = tag(for: name) else {
                rest.append((name, window))
                continue
            }
            let source = scope(window)
            let display = switch source?.lowercased() {
            case "general":
                L10n.text("apple.composerlimits.0_general.71898c32", "\(name)")
            case "current model":
                L10n.text("apple.composerlimits.0_secondary.6cd2b67a", "\(name)")
            case "secondary":
                L10n.text("apple.composerlimits.all_models_0.1605636b", "\(tag)")
            case "primary", nil, _:
                tag
            }
            best.append((display, rank(tag), index, window))
        }
        best.sort { lhs, rhs in
            if lhs.rank == rhs.rank {
                return lhs.index < rhs.index
            }
            return lhs.rank < rhs.rank
        }
        return best.map { ($0.display, $0.window) } + rest
    }

    static func pick<T>(
        backend: String,
        canonical: (String) -> String,
        providers: [T],
        source: (T) -> String,
        hasWindows: (T) -> Bool
    ) -> T? {
        let want = canonical(backend)
        return providers.first { canonical(source($0)) == want && hasWindows($0) }
    }

    private static func rank(_ tag: String) -> Int {
        switch tag {
        case "5h": return 0
        case "7d": return 1
        case "30d": return 2
        default: return 3
        }
    }
}
