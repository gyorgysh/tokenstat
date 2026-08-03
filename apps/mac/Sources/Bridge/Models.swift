// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" and the tokenstat marks are trademarks of pueev OU and are not
// licensed with the code. See TRADEMARK.md.

import Foundation

/// Filters accepted by every reporting method.
struct Query: Sendable, Equatable {
    var since: String?
    var until: String?
    var model: String?
    var project: String?

    var payload: [String: Any] {
        var out: [String: Any] = [:]
        if let since { out["since"] = since }
        if let until { out["until"] = until }
        if let model { out["model"] = model }
        if let project { out["project"] = project }
        return out
    }
}

enum GroupBy: String, Sendable, CaseIterable, Identifiable {
    case day, week, model, project, source, session

    var id: String { rawValue }

    var label: String {
        switch self {
        case .day: return "Day"
        case .week: return "Week"
        case .model: return "Model"
        case .project: return "Project"
        case .source: return "Tool"
        case .session: return "Session"
        }
    }
}

/// Token counters.
///
/// Every field is optional on purpose. "This tool does not report cache writes"
/// and "this tool reported zero cache writes" are different facts, and the
/// product's one unbreakable reporting rule is that they must not be collapsed.
struct Counters: Codable, Sendable, Hashable {
    var inputFresh: UInt64?
    var cacheRead: UInt64?
    var cacheWrite5m: UInt64?
    var cacheWrite1h: UInt64?
    var output: UInt64?
    var total: UInt64
    var inputTotal: UInt64
    var hasUnknown: Bool
}

/// One report row with its list-rate value.
struct Bucket: Codable, Sendable, Hashable, Identifiable {
    var key: String
    var counters: Counters
    var events: UInt64
    var sessions: UInt64
    var valueMicros: Int64
    var estimated: Bool
    var unpricedModels: [String]

    var id: String { key }

    /// Never call this "spend" or "cost" in the UI. Subscription usage is
    /// valued the same way, so this is what the tokens were worth at list
    /// rates, not what anyone was billed.
    var value: Money {
        Money(micros: valueMicros, estimated: estimated, complete: unpricedModels.isEmpty)
    }
}

struct Totals: Codable, Sendable, Hashable {
    var counters: Counters
    var events: UInt64
    var sessions: UInt64
    var days: UInt64
    var firstDate: String?
    var lastDate: String?
}

struct Block: Codable, Sendable, Hashable, Identifiable {
    var startMs: Int64
    var endMs: Int64
    var counters: Counters
    var events: UInt64
    var sessions: UInt64
    var active: Bool

    var id: Int64 { startMs }

    var start: Date { Date(timeIntervalSince1970: Double(startMs) / 1000) }
    var end: Date { Date(timeIntervalSince1970: Double(endMs) / 1000) }
}

struct ScanReport: Codable, Sendable, Hashable {
    var filesFound: UInt64
    var filesRead: UInt64
    var rowsSeen: UInt64
    var eventsNew: UInt64
    var eventsRecovered: UInt64
    var daysRecovered: UInt64
    var elapsedMs: UInt64
    var warnings: [String]
}

struct Info: Codable, Sendable, Hashable {
    var protocolVersion: String
    var coreVersion: String
    var dbPath: String
    var timezone: String
    var priceBookEffectiveFrom: String
    var hasPrices: Bool
}

/// A list-rate value, carrying the two qualifiers it must never be shown
/// without.
struct Money: Sendable, Hashable {
    var micros: Int64
    /// At least one model was valued from an estimate rather than a published
    /// rate.
    var estimated: Bool
    /// Every model in the bucket could be priced. When false the figure is a
    /// floor, and presenting it as a total would understate silently.
    var complete: Bool

    var dollars: Double { Double(micros) / 1_000_000 }

    /// Rates are published in US dollars, so the figure is formatted as one
    /// regardless of where the user is. A Hungarian locale renders the same
    /// number as `6 786,57 US$`, which reads as a local amount and does not
    /// match the `$6,786.57` the CLI prints for the very same archive.
    private static let currency: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.locale = Locale(identifier: "en_US")
        f.currencyCode = "USD"
        f.minimumFractionDigits = 2
        f.maximumFractionDigits = 2
        return f
    }()

    var formatted: String {
        let amount = Self.currency.string(from: NSNumber(value: dollars))
            ?? String(format: "$%.2f", dollars)
        // A floor reads as "at least this much", an estimate as "about this
        // much". Both must survive truncation, so they are never dropped.
        if !complete { return "\(amount)+" }
        if estimated { return "~\(amount)" }
        return amount
    }

    /// Why the figure carries a qualifier, for a tooltip. Nil when it does not.
    var caveat: String? {
        if !complete {
            return "At least one model here has no published rate, so the real figure is higher."
        }
        if estimated {
            return "Estimated from the model catalog, because the price book has no rate for this model."
        }
        return nil
    }
}

extension Sequence where Element == Bucket {
    /// Fold rows into one value, keeping the qualifiers. A total built from an
    /// incomplete row is itself incomplete.
    var totalValue: Money {
        reduce(Money(micros: 0, estimated: false, complete: true)) { acc, row in
            Money(
                micros: acc.micros + row.valueMicros,
                estimated: acc.estimated || row.estimated,
                complete: acc.complete && row.unpricedModels.isEmpty
            )
        }
    }
}

/// Compact token counts. 1.2B rather than 1,214,203,912, because these numbers
/// are read at a glance and compared, not audited.
func formatTokens(_ n: UInt64) -> String {
    let value = Double(n)
    switch n {
    case 1_000_000_000...:
        return String(format: "%.1fB", value / 1_000_000_000)
    case 1_000_000...:
        return String(format: "%.1fM", value / 1_000_000)
    case 10_000...:
        return String(format: "%.0fk", value / 1_000)
    case 1_000...:
        return String(format: "%.1fk", value / 1_000)
    default:
        return "\(n)"
    }
}
