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
        if plain == "5-hour" || plain.hasSuffix("· 5-hour") { return "5h" }
        if plain == "weekly" || plain.hasSuffix("· weekly") { return "7d" }
        if plain == "monthly" || plain.hasSuffix("· monthly") { return "30d" }
        return nil
    }

    /// Badge rows: one per recognised window, 5h then 7d then 30d, then any
    /// unrecognised windows under their own names in reported order. When
    /// several windows share a tag (model families), the fullest one stands
    /// for the tag: the badge answers what is about to stop the work.
    static func badgeRows<T>(windows: [T], label: (T) -> String, percent: (T) -> Double) -> [(display: String, window: T)] {
        var best: [(tag: String, window: T)] = []
        var rest: [(display: String, window: T)] = []
        for window in windows {
            let name = label(window).trimmingCharacters(in: .whitespacesAndNewlines)
            guard let tag = tag(for: name) else {
                rest.append((name, window))
                continue
            }
            if let index = best.firstIndex(where: { $0.tag == tag }) {
                if percent(window) > percent(best[index].window) {
                    best[index] = (tag, window)
                }
            } else {
                best.append((tag, window))
            }
        }
        best.sort { rank($0.tag) < rank($1.tag) }
        return best.map { ($0.tag, $0.window) } + rest
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
