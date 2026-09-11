// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

import Foundation

/// Which quota windows earn a seat in the composer, and for which agent.
///
/// Vendors report canonical window labels (`5-hour`, `weekly`, `monthly`: see
/// `window_label` in the core), so the badge reads "5h · 7d · 30d" the way
/// the plan screens read the same labels in full. Antigravity qualifies them
/// per model family (`"Gemini models · 5-hour"`), which tags the same way.
/// Anything else a vendor invents (Cursor's `"billing cycle"`) keeps its own
/// name in the badge rather than being squeezed into a duration it is not.
///
/// The functions are generic over the window and provider types so the rules
/// stay unit tested without compiling the app's model layer: callers pass
/// the label, source and window checks as closures over the real readings.
enum ComposerLimits {
    /// The badge tag for a vendor window label, or nil when the label is not
    /// one of the canonical three. Case-insensitive, and suffix-insensitive
    /// for qualified labels like `"Gemini models · 5-hour"`, because the
    /// labels arrive from several vendors' APIs in several shapes.
    static func tag(for label: String) -> String? {
        let plain = label.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        // Normalise vendor variants: "5 hour", "5h", "5-hour", "·5-hour".
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

    /// Collapsed headline rows for Codex: the account's own windows, bare.
    ///
    /// The composer shows general only, with no qualifier: a lone 7d needs
    /// no disambiguation. The running model's own secondary allowance (a
    /// small model like Spark) lives in the popover one tap away. With no
    /// general window at all, the model rows stand in, so a model-only
    /// reading still reads as one instead of vanishing.
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

    /// Badge rows: one per recognised window, 5h then 7d then 30d, then any
    /// unrecognised windows under their own names in reported order.
    /// When several windows share a tag, keep each one so scopes like
    /// “all models” stay visible.
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
            // Codex names the allowance itself, so it reads as written:
            // "weekly (general)", "5-hour (secondary)". Anything else keeps
            // the short tag, with "secondary" qualified, so two 7d figures
            // never say the same thing about two different limits.
            let display = switch source?.lowercased() {
            case "general":
                "\(name) (general)"
            case "current model":
                "\(name) (secondary)"
            case "secondary":
                "all models \(tag)"
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

    /// The readings for the agent a conversation runs on, when that vendor
    /// reports quota windows. No match, or a match with nothing to draw, is
    /// nil rather than somebody else's numbers: the badge answers "can I keep
    /// working in this chat", and another tool's quota is not that answer.
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
