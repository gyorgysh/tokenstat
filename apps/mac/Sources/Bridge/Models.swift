// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

import Foundation
import SwiftUI

/// Filters accepted by every reporting method.
struct Query: Sendable, Equatable {
    var since: String?
    var until: String?
    var model: String?
    var project: String?
    var billing: String?

    var payload: [String: Any] {
        var out: [String: Any] = [:]
        if let since { out["since"] = since }
        if let until { out["until"] = until }
        if let model { out["model"] = model }
        if let project { out["project"] = project }
        if let billing { out["billing"] = billing }
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
        case .source: return "Harness"
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

    /// Fresh input plus output: what the work actually was, cache reads left
    /// out. They are the largest number in the archive by a wide margin and
    /// they measure how much context was re-sent, not how much was done.
    var workTokens: UInt64 {
        (inputFresh ?? 0) + (output ?? 0)
    }
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

struct FetchReport: Codable, Sendable, Hashable {
    var vendor: String
    var events: Int
    var fromCache: Bool
    var skippedNoToken: Bool
    var message: String?
}

struct FileText: Codable, Sendable, Hashable {
    var path: String
    var content: String
}

// MARK: - Activity

/// One day of the activity grid.
struct HeatCell: Codable, Sendable, Hashable, Identifiable {
    /// `YYYY-MM-DD`. Kept as the archive's own string, which is also the format
    /// a `Query` filters by, so a click on a day can become a filter with no
    /// reformatting in between.
    var date: String
    /// What the day was worth at list rates, in microdollars. Spend rather than
    /// tokens, so the grid ranks a day by what it cost and not by how many
    /// cheap tokens went through it.
    var value: UInt64
    /// `0...4`. Zero is a day inside the range with no usage, which has to read
    /// as "nothing happened" and not as "no data".
    var level: Int

    var id: String { date }
}

struct MonthLabel: Codable, Sendable, Hashable, Identifiable {
    var column: Int
    var name: String

    var id: Int { column }
}

/// The activity calendar, as the core computed it.
///
/// The rows arrive built. Do not rebuild the grid from a list of days: the
/// archive stores only days that had events, so packing them together draws a
/// plausible calendar with every date in the wrong column.
struct ActivityCalendar: Codable, Sendable, Hashable {
    /// Seven rows, Monday first. `nil` is a day outside the rendered range.
    var rows: [[HeatCell?]]
    var months: [MonthLabel]
    var weeks: Int
    /// Value of the whole grid at list rates, in microdollars, matching the
    /// unit every `HeatCell` carries.
    var total: UInt64
    var activeDays: Int
    /// Consecutive active days up to the most recent one with data. A quiet day
    /// that is not over yet does not break it.
    var streakCurrent: Int
    var streakBest: Int
    var busiest: HeatCell?
    var first: String
    var last: String
    /// Which grid this is: `"local"` or `"account"`. Optional because a peer
    /// running an older host does not send it, and a missing answer is local.
    var scope: String?
    /// Why this is not the grid that was asked for, in words to show.
    var notice: String?
    /// What kind of fallback this is, so the interface can act on it instead
    /// of parsing the sentence: `"auth"` (sign-in would fix it), `"upgrade"`
    /// (the account does not include it), `"other"`. Absent when the grid is
    /// the one asked for.
    var noticeCode: String?
}

// MARK: - Day detail

/// One day's hover detail, the same shape the profile page draws.
///
/// The heatmap cell carries one number so the grid can be built cheaply; this
/// is what sits behind a hovered day: the totals line plus every
/// `model × harness` slice, so the app and the website tell the same story
/// about the day.
struct DayDetail: Codable, Sendable, Hashable, Identifiable {
    /// `YYYY-MM-DD`, echoed so the popover never has to guess which day it is
    /// describing while a fetch races a hover change.
    var date: String
    var tokens: UInt64
    var events: UInt64
    var valueMicros: Int64
    var estimated: Bool
    var unpricedModels: [String]
    var rows: [DayPart]

    var id: String { date }

    /// List-rate value, with the same "not billed / floor" qualifiers money
    /// everywhere else carries.
    var value: Money {
        Money(micros: valueMicros, estimated: estimated, complete: unpricedModels.isEmpty)
    }
}

/// One `model × harness` slice of a day.
struct DayPart: Codable, Sendable, Hashable, Identifiable {
    var model: String
    /// The harness that recorded the events, e.g. `"codex"`.
    var src: String
    var fresh: UInt64?
    var cacheRead: UInt64?
    var cacheWrite5m: UInt64?
    var cacheWrite1h: UInt64?
    var output: UInt64?
    /// Sum of every known counter field, as the host sent it.
    var tokens: UInt64
    var events: UInt64

    var id: String { "\(src)\u{1}\(model)" }
}

/// Display label for a model id, matching tokenstat.ai.
///
/// Model ids are long and the useful part is at the end: "claude-opus-4-8"
/// reads fine, "claude-haiku-4-5-20251001" does not. Cursor's auto router logs
/// as bare "default"/"auto", which would otherwise render as a mystery.
func shortModel(_ id: String) -> String {
    let raw = id.trimmingCharacters(in: .whitespaces)
    let leaf = raw.split(separator: "/").last.map(String.init) ?? raw
    let lower = leaf.lowercased()
    if ["default", "auto", "cursor-auto", "cursor-default", "cursor-router-auto"].contains(lower) {
        return "cursor-router-auto"
    }
    if let colon = leaf.range(of: ": ") {
        let after = String(leaf[colon.upperBound...]).trimmingCharacters(in: .whitespaces)
        if !after.isEmpty { return after }
    }
    return leaf.isEmpty ? "model" : leaf
}

// MARK: - Syntax highlighting

/// What a run of source text is.
///
/// Mirrors `tokenstat_highlight::Kind`. The Rust side never sends a colour, so
/// the mapping from a kind to a colour lives in `Theme` and switching to light
/// mode is not a round trip through a parser.
enum SyntaxKind: String, Codable, Sendable, Hashable {
    case keyword
    case string
    case number
    case comment
    case type
    case function
    case constant
    case attribute
    case property
    case variable
    case `operator`
    case punctuation
    case markup
    /// A kind this build does not know. Newer core, older app: colour it as
    /// plain text rather than refusing to decode the whole file.
    case unknown

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = SyntaxKind(rawValue: raw) ?? .unknown
    }
}

/// One coloured run.
///
/// `start` and `length` are **UTF-16 code units**, which is what `NSTextStorage`
/// indexes by, so they drop straight into an `NSRange` with no conversion. The
/// Rust side does that conversion in the pass it was already making.
struct SyntaxSpan: Codable, Sendable, Hashable {
    var start: Int
    var len: Int
    var kind: SyntaxKind

    var range: NSRange { NSRange(location: start, length: len) }
}

/// How a language is commented and indented.
///
/// Comes from the core so there is one table of these facts rather than one per
/// front end.
struct SyntaxRules: Codable, Sendable, Hashable {
    var lineComment: String?
    var blockComment: [String]?
    var indent: Int

    /// What pressing Tab inserts.
    var indentUnit: String { String(repeating: " ", count: max(1, indent)) }

    static let fallback = SyntaxRules(lineComment: nil, blockComment: nil, indent: 4)
}

/// The answer to a highlight request.
///
/// A file with no grammar and a file over the size limit both come back as a
/// successful call with an empty `spans` and a `note`. Neither is an error: the
/// file opened, it just is not colourable, and a red banner over a perfectly
/// good file is worse than plain text.
struct Highlighting: Codable, Sendable, Hashable {
    var language: String?
    var syntax: SyntaxRules?
    var spans: [SyntaxSpan]
    var note: String?

    static let none = Highlighting(language: nil, syntax: nil, spans: [], note: nil)

    var rules: SyntaxRules { syntax ?? .fallback }
}

struct Info: Codable, Sendable, Hashable {
    var protocolVersion: String
    var coreVersion: String
    var dbPath: String
    var timezone: String
    var priceBookEffectiveFrom: String
    var hasPrices: Bool
}

/// What `pricing.refresh` fetched and loaded.
struct PricingRefresh: Codable, Sendable, Hashable {
    var effectiveFrom: String
    var models: UInt64
    var hasPrices: Bool
}

struct AppUpdate: Codable, Sendable, Hashable {
    var current: String
    var latest: String
    var newer: Bool
    var htmlURL: String
    /// The signed, notarized disk image for this release, when it has one. A
    /// release cut before the app shipped has none, so this stays optional and
    /// the release page is the fallback.
    var dmgURL: String?

    enum CodingKeys: String, CodingKey {
        case current, latest, newer, htmlURL = "htmlUrl", dmgURL = "dmgUrl"
    }

    /// Where to send somebody who wants the update: the image if the release
    /// carries one, the release page otherwise.
    var downloadURL: URL? {
        URL(string: dmgURL ?? htmlURL)
    }

    var isAvailable: Bool { newer && latest != current }
}

/// Something the daemon fetched and checked, waiting on disk.
struct DownloadedFile: Codable, Sendable {
    var path: String
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

/// A heat value as money.
///
/// The activity calendar carries microdollars, not tokens: a day's colour is
/// what the day's work was worth at list rates, so a cheap high-volume day does
/// not outshine an expensive one. The qualifiers are dropped here because the
/// grid sends one number per day and the card above it already carries them.
func formatSpend(_ micros: UInt64) -> String {
    Money(micros: Int64(clamping: micros), estimated: false, complete: true).formatted
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

// MARK: - Account

/// A device authorization the user has not confirmed yet.
///
/// No device code here. That secret stays in the Rust bridge, which is why
/// polling takes no arguments.
struct DeviceLogin: Codable, Sendable, Hashable {
    var host: String
    /// The short code the user reads. Shown large, because reading it off a
    /// screen is the one manual step in the whole flow.
    var userCode: String
    /// Where to send them. Usually already carries the code.
    var openURL: String
    var verificationURI: String
    var expiresIn: UInt64
    var interval: UInt64

    enum CodingKeys: String, CodingKey {
        case host
        case userCode
        case openURL = "openUrl"
        case verificationURI = "verificationUri"
        case expiresIn
        case interval
    }
}

/// One poll's answer.
struct DevicePoll: Codable, Sendable, Hashable {
    var state: String
    var interval: UInt64?
    var handle: String?
    var host: String?
    var machine: String?

    var isConfirmed: Bool { state == "confirmed" }
}

/// Who is signed in.
struct Account: Codable, Sendable, Hashable {
    var signedIn: Bool
    var host: String
    var handle: String?
    /// The name the user chose to be shown as. The handle is the identifier,
    /// this is the label.
    var displayName: String?
    var tier: String?
    /// Profile picture URL, when the account has one.
    ///
    /// Always nil today: `/api/v1/me` does not carry an avatar field yet, so
    /// every surface draws the monogram. Not a bug in the app.
    var avatar: String?
    /// When this account last synced, from any machine.
    ///
    /// Derived in the host from the machine list, because `/api/v1/me` carries
    /// a timestamp per machine and none for the account. Reading the top level
    /// gave nil, so the Account screen said "never" for an account that had
    /// synced minutes earlier.
    var lastSyncAt: String?
    /// The machine this app is running on, so the list below can say which row
    /// is the one you are sitting at.
    var thisMachineID: String?
    /// Server-side machine records. The shape belongs to the API, so this
    /// decodes the few fields the UI shows and ignores the rest.
    var machines: [Machine]
    var schemaCurrent: UInt32?

    /// What to call this person on screen: their chosen name, or the handle
    /// when they have not set one.
    var title: String? {
        let name = displayName?.trimmingCharacters(in: .whitespaces)
        if let name, !name.isEmpty { return name }
        return handle
    }
}

/// A machine on the account.
///
/// Field names follow the server (`id`, `label`, `last_sync_at`), not this
/// app's preferences. Every one is optional because the shape belongs to the
/// API: a machine that arrives with only an id still renders instead of
/// failing the whole account decode.
struct Machine: Codable, Sendable, Hashable, Identifiable {
    var machineID: String?
    var label: String?
    var lastSyncAt: String?
    var online: Bool?
    var lastSeenAt: String?
    var publicIdentity: String?
    var trustState: String?

    enum CodingKeys: String, CodingKey {
        case machineID = "id"
        case label
        case lastSyncAt
        case online
        case lastSeenAt
        case publicIdentity
        case trustState
    }

    /// Falls back to the label so two unnamed machines do not collapse into
    /// one row in a ForEach.
    var id: String { machineID ?? label ?? "unidentified" }

    var displayName: String {
        switch (label, machineID) {
        case let (label?, _) where !label.isEmpty:
            return label
        case let (_, id?):
            return id
        default:
            return "unnamed machine"
        }
    }

    /// The id, shown alongside a label rather than instead of it.
    var subtitle: String? {
        guard let machineID, label?.isEmpty == false else { return nil }
        return machineID
    }
}

/// Outcome of a sync.
struct SyncOutcome: Codable, Sendable, Hashable {
    var host: String
    var rows: UInt64
    var dryRun: Bool
    var schemaV: UInt32
    var from: String
    var to: String
}

/// A loopback port on this machine that bridges to a service on a peer's own
/// localhost. The browser opens `url` as if the service were local.
struct ProxyListen: Codable, Sendable, Hashable {
    var url: String
}

/// What a machine can launch in a workspace, as its daemon reports it. A
/// remote folder asks the machine that owns it, so the launcher always means
/// the machine the session would actually run on.
struct RemoteLaunchProfile: Codable, Sendable, Hashable {
    var id: String
    var name: String
    var command: String
    var args: [String]
    var bypassArgs: [String]
    var harnessId: String?
    var symbol: String?
}

struct SyncScheduleStatus: Codable, Sendable {
    let loggedIn: Bool
    let cliScheduleActive: Bool
    let due: Bool
}

/// Render an ISO-8601 instant from the server as something readable.
///
/// Returns nil rather than a placeholder when it cannot be parsed, so the
/// caller decides what absence looks like.
/// "3 minutes ago", for a timestamp whose exact minute nobody reads.
///
/// The absolute date stays available as a tooltip. "Last synced 4 Aug 2026 at
/// 18:41" makes you work out whether that was recent. "12 minutes ago" is the
/// answer to the question actually being asked.
func formatRelativeDate(_ raw: String?) -> String? {
    guard let date = parseServerDate(raw) else { return nil }
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .full
    return formatter.localizedString(for: date, relativeTo: Date())
}

func parseServerDate(_ raw: String?) -> Date? {
    guard let raw else { return nil }
    let parsers = [ISO8601DateFormatter(), {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()]
    for p in parsers {
        if let date = p.date(from: raw) { return date }
    }
    return nil
}

func formatServerDate(_ raw: String?) -> String? {
    guard let raw else { return nil }
    let parsers = [ISO8601DateFormatter(), {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()]
    for p in parsers {
        if let date = p.date(from: raw) {
            return date.formatted(date: .abbreviated, time: .shortened)
        }
    }
    return raw
}

/// One row of a two-level report.
struct SplitBucket: Codable, Sendable, Hashable, Identifiable {
    var key: String
    var split: String
    var counters: Counters
    var events: UInt64
    var sessions: UInt64

    var id: String { "\(key)\u{1}\(split)" }
}

/// An archive project with the harnesses that ran in it.
///
/// Not a workspace. A workspace is a folder the user registered; this is a
/// label the archive recovered from a slug, and the two are deliberately
/// separate concepts with separate types so they cannot be confused.
struct ProjectHarnesses: Identifiable, Hashable {
    var path: String
    var harnesses: [SplitBucket]
    var tokens: UInt64

    var id: String { path }

    /// Last path component, which is what someone calls the project. The full
    /// path stays available for the row's tooltip, since two checkouts of the
    /// same repository share a leaf name.
    var name: String {
        let trimmed = path.hasSuffix("/") ? String(path.dropLast()) : path
        let leaf = trimmed.split(separator: "/").last.map(String.init)
        return leaf?.isEmpty == false ? leaf! : (trimmed.isEmpty ? "unknown" : trimmed)
    }
}

/// Display name for a harness, the agent CLI that produced the events.
///
/// The archive stores source ids like `claude_code`. These are shown to
/// people, so they get the same spelling tokenstat.ai uses. Keep the two in
/// step: a user reading their profile on the web and their app should not see
/// two names for one tool.
func harnessName(_ id: String) -> String {
    switch id {
    case "claude_code": return "Claude Code"
    case "claude_code_rollup": return "Claude Code rollup"
    case "codex": return "Codex"
    case "grok": return "Grok Build"
    case "opencode": return "OpenCode"
    case "cline": return "Cline"
    case "openclaw": return "OpenClaw"
    case "muse": return "Muse"
    case "pi": return "Pi"
    case "zed": return "Zed"
    case "copilot": return "Copilot CLI"
    case "antigravity": return "Antigravity CLI"
    case "antigravity_ide": return "Antigravity IDE"
    case "cursor": return "Cursor"
    case "gemini": return "Gemini"
    case "": return "unknown"
    default: return id
    }
}

/// Asset name for a harness's brand mark, or nil when none is bundled.
///
/// Vendor marks, not ours. See TRADEMARK.md. A missing one falls back to a
/// letter tile rather than borrowing another tool's logo.
func harnessBrandAsset(_ id: String) -> String? {
    let known: Set<String> = [
        "claude_code", "claude_code_rollup", "codex", "grok", "opencode",
        "cline", "openclaw", "muse", "pi", "zed", "copilot", "antigravity",
        "antigravity_ide", "cursor", "gemini",
    ]
    return known.contains(id) ? "brand_\(id)" : nil
}

// MARK: - Workspaces

/// What happened to one file, as git reports it.
enum ChangeKind: String, Codable, Sendable {
    case added, modified, deleted, renamed, untracked, conflicted

    var symbol: String {
        switch self {
        case .added: return "plus.square"
        case .modified: return "square.righthalf.filled"
        case .deleted: return "minus.square"
        case .renamed: return "arrow.right.square"
        case .untracked: return "questionmark.square"
        case .conflicted: return "exclamationmark.triangle"
        }
    }

    var tint: Color {
        switch self {
        case .added: return .green
        case .deleted: return .red
        case .conflicted: return .orange
        case .untracked: return .secondary
        case .modified, .renamed: return Theme.secondary
        }
    }
}

/// One changed file.
struct FileChange: Codable, Sendable, Hashable, Identifiable {
    var path: String
    var kind: ChangeKind
    /// Nil when unknown rather than zero: an untracked file has nothing to diff
    /// against, and a changed binary is not an unchanged one.
    var added: UInt64?
    var removed: UInt64?

    var id: String { path }

    /// Directory the file sits in, for grouping. Empty at the repo root.
    var directory: String {
        let parts = path.split(separator: "/")
        return parts.count > 1 ? parts.dropLast().joined(separator: "/") : ""
    }

    var fileName: String {
        String(path.split(separator: "/").last ?? "")
    }
}

/// Git state of a workspace folder.
struct GitStatus: Codable, Sendable, Hashable {
    var isRepo: Bool
    var branch: String?
    var upstream: String?
    var ahead: UInt32
    var behind: UInt32
    var files: [FileChange]
    var added: UInt64
    var removed: UInt64
    /// True when some file's counts were unknown, so the totals are a floor.
    var partial: Bool
}

/// One entry in a workspace's file tree.
struct TreeEntry: Codable, Sendable, Hashable, Identifiable {
    var name: String
    /// Path relative to the workspace root, with `/` separators.
    var path: String
    var isDir: Bool
    /// True when git would ignore this. Shown dimmed rather than hidden:
    /// `target/` and a generated project file are things people look for.
    var ignored: Bool

    var id: String { path }
}

/// What one line of a diff is.
enum DiffLineKind: String, Codable, Sendable {
    case context, added, removed

    var tint: Color {
        switch self {
        case .added: return .green
        case .removed: return .red
        case .context: return .secondary
        }
    }
}

/// One line of a diff, with the numbers each side shows in its gutter.
struct DiffLine: Codable, Sendable, Hashable, Identifiable {
    var kind: DiffLineKind
    var oldLine: UInt32?
    var newLine: UInt32?
    /// The line without its leading `+`, `-` or space.
    var text: String

    /// Unique within a hunk: a line is one or the other, never neither.
    var id: String { "\(oldLine.map(String.init) ?? "")-\(newLine.map(String.init) ?? "")" }
}

struct DiffHunk: Codable, Sendable, Hashable, Identifiable {
    var header: String
    var lines: [DiffLine]

    var id: String { header }
}

/// One file's diff against HEAD.
struct FileDiff: Codable, Sendable, Hashable {
    var path: String
    var hunks: [DiffHunk]
    /// True when git refused to diff it as text. Showing nothing without saying
    /// why looks like an empty file.
    var binary: Bool
    /// True when the file is not tracked, so every line reads as added.
    var untracked: Bool

    var fileName: String { String(path.split(separator: "/").last ?? "") }
}

/// What a git command that changed something reported.
struct GitOutcome: Codable, Sendable, Hashable {
    var ok: Bool
    /// Git's own words. Shown verbatim on failure: they name the file, the
    /// hook, or the conflict, and rewording loses that.
    var message: String
}

/// One commit in a workspace's history.
struct Commit: Codable, Sendable, Hashable, Identifiable {
    /// Full hash. Abbreviating is the view's job.
    var id: String
    var subject: String
    var author: String
    /// Author email. Optional because the running daemon can be older than the
    /// app: a launchd agent is updated on its own schedule, and a field it does
    /// not send must not fail the whole decode.
    var email: String?
    /// Author time in unix seconds: when the work was done, not when a rebase
    /// last touched it.
    var timestamp: Int64
    /// True while the commit is not on the upstream branch yet. False when
    /// there is no upstream at all, because then nothing is known either way.
    var unpushed: Bool
    /// Authored by the identity this repository is configured with. The host
    /// decides it, because `user.email` is git's answer to "who am I here" and
    /// can differ per repository. Optional for the same reason as `email`.
    var mine: Bool?

    /// The seven characters everyone actually reads.
    var shortID: String { String(id.prefix(7)) }

    var date: Date { Date(timeIntervalSince1970: TimeInterval(timestamp)) }
}

/// How close to a limit a window is.
enum LimitSeverity: String, Codable, Sendable {
    case normal, warning, critical

    var tint: Color {
        switch self {
        case .normal: return Theme.accent
        case .warning: return .orange
        case .critical: return .red
        }
    }
}

/// One quota window a vendor reports.
struct UsageWindow: Codable, Sendable, Hashable, Identifiable {
    /// `5-hour`, `weekly`, `monthly`.
    var label: String
    /// Percent of the allowance used, 0 to 100.
    var percent: Double
    var resetsAtMs: Int64?
    var severity: LimitSeverity

    var id: String { label }

    var resetsAt: Date? {
        resetsAtMs.map { Date(timeIntervalSince1970: TimeInterval($0) / 1000) }
    }

    /// Clamped for drawing. A vendor reporting 104% is telling you it is over,
    /// not asking for a bar that runs off the edge.
    var fraction: Double { min(1, max(0, percent / 100)) }
}

/// What one provider says about its own limits.
struct ProviderLimits: Codable, Sendable, Hashable, Identifiable {
    /// Archive source id, so the brand mark is the same one used elsewhere.
    var source: String
    var plan: String?
    var windows: [UsageWindow]
    var observedAtMs: Int64
    /// Why the vendor could not be read. With windows present it explains why
    /// they are old rather than why they are missing.
    var note: String?
    /// These windows were remembered from an earlier read, because this one
    /// failed. Real numbers, just not current ones.
    var stale: Bool?

    var id: String { source }

    var observedAt: Date? {
        observedAtMs > 0 ? Date(timeIntervalSince1970: TimeInterval(observedAtMs) / 1000) : nil
    }

    var isStale: Bool { stale == true }

    /// Something to draw, as opposed to only a reason there is nothing.
    var hasWindows: Bool { !windows.isEmpty }

    /// When the soonest window rolls over, which is the next moment these
    /// numbers can change on their own.
    var nextReset: Date? {
        windows.compactMap(\.resetsAt).min()
    }
}

/// One commit in full: what it says, and what it changed.
struct CommitDetail: Codable, Sendable, Hashable, Identifiable {
    var id: String
    var subject: String
    /// Everything after the subject. Empty when there is none.
    var body: String
    var author: String
    var email: String
    var timestamp: Int64
    /// Two or more parents means a merge, which is why its diff can be empty
    /// for a commit that plainly changed things.
    var parents: [String]
    var files: [FileChange]
    var added: UInt64
    var removed: UInt64
    var diffs: [FileDiff]

    var shortID: String { String(id.prefix(7)) }
    var date: Date { Date(timeIntervalSince1970: TimeInterval(timestamp)) }
    var isMerge: Bool { parents.count > 1 }
}

/// A folder the user registered.
struct WorkspaceFolder: Codable, Sendable, Hashable, Identifiable {
    var id: String
    var path: String
    var name: String
    var addedAtMs: Int64
    /// False when the folder is gone. Kept and marked rather than dropped.
    var exists: Bool
    /// Absent when the folder is missing, so "we did not look" cannot be
    /// mistaken for "no changes".
    var git: GitStatus?
    /// Public key of the machine that owns this workspace. Local folders have
    /// no machine id. The id is optional for compatibility with older daemons.
    var machineID: String?
    var machineLabel: String?

    var changeCount: Int { git?.files.count ?? 0 }

    /// `+120 −8`, or nil when there is nothing to say.
    var diffStat: String? {
        guard let git, git.isRepo, !git.files.isEmpty else { return nil }
        let plus = "+\(git.added)"
        let minus = git.removed > 0 ? " −\(git.removed)" : ""
        return git.partial ? "\(plus)\(minus)+" : "\(plus)\(minus)"
    }

    var isRemote: Bool { machineID != nil }
}

// MARK: - Automations

/// An agent CLI the daemon can run: a backend, a prompt, a workspace, and a
/// schedule with a budget the run stops at.
struct Automation: Codable, Sendable, Hashable, Identifiable {
    var id: String
    var name: String
    /// One of the ids `automation.backends` reports. The daemon owns the argv
    /// for each backend, so a client never builds a command line.
    var backend: String
    /// Model alias passed to the CLI, when the backend advertises models.
    var model: String?
    /// Reasoning effort passed to the CLI, when the backend advertises levels.
    var effort: String?
    var workspaceID: String
    var prompt: String
    var schedule: AutomationSchedule
    var budgetSeconds: UInt64
    var enabled: Bool
    var lastRunAtMs: Int64?
    var nextRunAtMs: Int64?
    var lastRunID: String?

    enum CodingKeys: String, CodingKey {
        case id, name, backend, model, effort, workspaceID = "workspaceId", prompt, schedule
        case budgetSeconds, enabled, lastRunAtMs, nextRunAtMs, lastRunID
    }

    var lastRun: Date? { lastRunAtMs.map { Date(timeIntervalSince1970: Double($0) / 1000) } }
    var nextRun: Date? { nextRunAtMs.map { Date(timeIntervalSince1970: Double($0) / 1000) } }
}

/// When a job fires, as a plain struct so the form edits one field at a time.
struct AutomationSchedule: Codable, Sendable, Hashable {
    var kind: ScheduleKind
    /// Interval only, seconds.
    var everySeconds: UInt64
    /// Wall-clock kinds only, local hour and minute.
    var hour: Int
    var minute: Int
    /// Weekly single-day, 0 = Monday to 6 = Sunday.
    var weekday: Int
    /// Multi-day bitset, Monday = bit 0 … Sunday = bit 6. Used by custom and
    /// weekdays; weekly with a single day keeps using `weekday` (this stays 0).
    var weekdays: Int

    enum CodingKeys: String, CodingKey {
        case kind, everySeconds, hour, minute, weekday, weekdays
    }

    init(
        kind: ScheduleKind,
        everySeconds: UInt64 = 0,
        hour: Int = 9,
        minute: Int = 0,
        weekday: Int = 0,
        weekdays: Int = 0
    ) {
        self.kind = kind
        self.everySeconds = everySeconds
        self.hour = hour
        self.minute = minute
        self.weekday = weekday
        self.weekdays = weekdays
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decode(ScheduleKind.self, forKey: .kind)
        everySeconds = try c.decodeIfPresent(UInt64.self, forKey: .everySeconds) ?? 0
        hour = try c.decodeIfPresent(Int.self, forKey: .hour) ?? 0
        minute = try c.decodeIfPresent(Int.self, forKey: .minute) ?? 0
        weekday = try c.decodeIfPresent(Int.self, forKey: .weekday) ?? 0
        weekdays = try c.decodeIfPresent(Int.self, forKey: .weekdays) ?? 0
    }

    static let `default` = AutomationSchedule(kind: .once, everySeconds: 3600, hour: 9, minute: 0, weekday: 0)
    /// Monday through Friday bits, matching the host.
    static let weekdaysMask = 0b0001_1111
}

enum ScheduleKind: String, Codable, Sendable, Hashable, CaseIterable {
    case once
    case interval
    case daily
    case weekdays
    case weekly
    case custom

    var label: String {
        switch self {
        case .once: return "Once"
        case .interval: return "Interval"
        case .daily: return "Daily"
        case .weekdays: return "Weekdays"
        case .weekly: return "Weekly"
        case .custom: return "Custom"
        }
    }
}

/// One completed or still-running agent run.
struct RunRecord: Codable, Sendable, Identifiable {
    var id: String
    var jobId: String
    var name: String
    var backend: String
    var workspaceID: String
    var startedAtMs: Int64
    var endedAtMs: Int64?
    var exitCode: Int?
    var status: String
    var transcriptPath: String

    enum CodingKeys: String, CodingKey {
        case id, jobId, name, backend, workspaceID = "workspaceId"
        case startedAtMs, endedAtMs, exitCode, status, transcriptPath
    }

    var startedAt: Date { Date(timeIntervalSince1970: Double(startedAtMs) / 1000) }
    var isRunning: Bool { status == "running" }
    var endedLabel: String {
        switch status {
        case "running": return "Running"
        case "ok": return "Done"
        case "stopped": return "Stopped at budget"
        case "error": return "Failed"
        case "interrupted": return "Interrupted by restart"
        default: return status
        }
    }
}

/// A slice of a run's transcript, asked for by byte offset.
struct TranscriptChunk: Codable, Sendable {
    var text: String
    var nextOffset: UInt64
}

/// One agent CLI a job can run on, as the daemon advertises it.
struct AgentBackend: Codable, Sendable, Identifiable {
    var id: String
    var label: String
    var command: String
    /// Model aliases the CLI accepts on its `--model` flag. Empty means the
    /// client offers no model picker for this backend.
    var models: [String]
    /// Effort levels the CLI accepts. Empty means no effort picker.
    var efforts: [String]

    init(id: String, label: String, command: String, models: [String] = [], efforts: [String] = []) {
        self.id = id
        self.label = label
        self.command = command
        self.models = models
        self.efforts = efforts
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        label = try c.decode(String.self, forKey: .label)
        command = try c.decode(String.self, forKey: .command)
        // An older daemon does not advertise the lists yet; both default to
        // empty so the pickers simply do not appear.
        models = try c.decodeIfPresent([String].self, forKey: .models) ?? []
        efforts = try c.decodeIfPresent([String].self, forKey: .efforts) ?? []
    }
}

// MARK: - Todo

enum TodoKind: String, Codable, Sendable, Hashable {
    case task
    case note
}

/// A card on the kanban board.
struct TodoCard: Codable, Sendable, Identifiable, Hashable {
    var id: String
    var title: String
    var kind: TodoKind
    var notes: String
    var column: String
    var order: Int64
    var priority: String
    var backend: String
    var model: String?
    var effort: String?
    var workspaceID: String
    var budgetSeconds: UInt64
    var createdAtMs: Int64
    var updatedAtMs: Int64
    var delegate: TodoDelegate?

    enum CodingKeys: String, CodingKey {
        case id, title, notes, column, order, priority, backend, model, effort
        case kind
        case workspaceID = "workspaceId", budgetSeconds, createdAtMs, updatedAtMs, delegate
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        title = try values.decode(String.self, forKey: .title)
        kind = try values.decodeIfPresent(TodoKind.self, forKey: .kind) ?? .task
        notes = try values.decode(String.self, forKey: .notes)
        column = try values.decode(String.self, forKey: .column)
        order = try values.decode(Int64.self, forKey: .order)
        priority = try values.decode(String.self, forKey: .priority)
        backend = try values.decode(String.self, forKey: .backend)
        model = try values.decodeIfPresent(String.self, forKey: .model)
        effort = try values.decodeIfPresent(String.self, forKey: .effort)
        workspaceID = try values.decode(String.self, forKey: .workspaceID)
        budgetSeconds = try values.decode(UInt64.self, forKey: .budgetSeconds)
        createdAtMs = try values.decode(Int64.self, forKey: .createdAtMs)
        updatedAtMs = try values.decode(Int64.self, forKey: .updatedAtMs)
        delegate = try values.decodeIfPresent(TodoDelegate.self, forKey: .delegate)
    }

    var columnLabel: String {
        switch column {
        case "doing": return "Doing"
        case "done": return "Done"
        default: return "To Do"
        }
    }

    var isNote: Bool { kind == .note }
}

/// The live state of a card handed to an agent.
struct TodoDelegate: Codable, Sendable, Hashable {
    var runId: String
    var status: String
    var startedAtMs: Int64
    var endedAtMs: Int64?
    var error: String?

    enum CodingKeys: String, CodingKey {
        case runId, status, startedAtMs, endedAtMs, error
    }

    var isRunning: Bool { status == "running" }
    var label: String {
        switch status {
        case "running": return "Running"
        case "ok": return "Done"
        case "stopped": return "Stopped"
        case "error": return "Failed"
        default: return status
        }
    }
}

// MARK: - Terminals

/// A pty session as the host reports it.
///
/// The process is owned by the host, not by the app: a session survives the
/// window closing, and a client that reconnects resumes by offset. Field names
/// follow the Rust `SessionInfo`, which is the single definition of the shape.
struct PtySessionInfo: Codable, Sendable, Hashable, Identifiable {
    var id: String
    /// The command as launched, for a tab label.
    var command: String
    var cwd: String
    /// Workspace this belongs to, so sessions can be grouped by folder.
    var workspaceID: String?
    var rows: Int
    var cols: Int
    var alive: Bool
    /// Set once the process has exited. `nil` while it still runs, which is
    /// not the same as having exited with status 0.
    var exitCode: Int?
    /// Total bytes ever produced. A client's read offset is against this.
    var totalBytes: UInt64

    enum CodingKeys: String, CodingKey {
        case id
        case command
        case cwd
        // The host spells it `workspaceId`, serde's camelCase for
        // `workspace_id`. Swift's own camelCase writes `workspaceID`.
        case workspaceID = "workspaceId"
        case rows
        case cols
        case alive
        case exitCode
        case totalBytes
    }
}

/// One poll's worth of terminal output.
///
/// The wire carries base64, because the bytes are not valid UTF-8 in general:
/// an escape sequence can be cut in half at a read boundary. The decode happens
/// here, in `init(from:)`, which runs on the bridge's own queue. That placement
/// is the point: a burst of build output is up to half a megabyte per poll, and
/// decoding it in the session actor put that work on the thread that draws.
struct PtyChunk: Decodable, Sendable {
    /// The output itself, already decoded.
    var bytes: Data
    /// Offset to ask for next time.
    var nextOffset: UInt64
    /// Bytes dropped before this chunk because this reader fell behind the
    /// host's bounded buffer. Zero in normal use, and never silently ignored.
    var dropped: UInt64

    private enum CodingKeys: String, CodingKey {
        case data
        case nextOffset
        case dropped
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let encoded = try container.decode(String.self, forKey: .data)
        // An unreadable chunk is empty output rather than a failed poll. The
        // offset still advances, so the session carries on instead of asking
        // for the same bytes forever.
        bytes = Data(base64Encoded: encoded) ?? Data()
        nextOffset = try container.decode(UInt64.self, forKey: .nextOffset)
        dropped = try container.decode(UInt64.self, forKey: .dropped)
    }
}

// MARK: - Machines

/// Who this machine is to another one.
struct MachineIdentity: Codable, Sendable {
    /// The public key as hex. Long, and the thing that is actually pinned.
    let key: String
    /// The short form somebody reads aloud to check two ends match.
    let fingerprint: String
    /// The same key as three words. What the screen leads with, because it is
    /// the comparison a person performs rather than skims.
    let words: String?
    let label: String
    /// Whether somebody named this machine, as opposed to it carrying the name
    /// the operating system gave it. Decides whether there is anything to undo.
    var labelIsChosen: Bool?
}

/// A machine this one knows about.
struct Peer: Codable, Sendable, Identifiable, Hashable {
    enum Trust: String, Codable, Sendable {
        /// It made contact and nobody has decided yet. The only state a new
        /// peer can arrive in.
        case pending
        case approved
        /// Somebody withdrew access. Remembered rather than deleted, so the
        /// same machine coming back is known as one that was turned away.
        case revoked
    }

    let key: String
    let fingerprint: String
    let words: String?
    let label: String
    let trust: Trust
    /// Where it was reached or seen from. A hint for dialling, never a
    /// credential: an address proves nothing about who is at it.
    let address: String?
    let firstSeen: String
    let lastSeen: String

    var id: String { key }
}

/// Whether this machine is reachable by others.
struct RemoteStatus: Codable, Sendable {
    /// Whether this machine keeps an outbound connection to the blind tunnel.
    let tunnel: Bool
    /// What the tunnel is actually doing. The toggle can be on while the
    /// daemon is being refused (plan gate, revoked token, endpoint down), so
    /// the screen has to read these rather than trust the setting.
    let tunnelOnline: Bool?
    /// Whether the account directory carries this machine's key and name.
    let tunnelRegistered: Bool?
    /// Why the tunnel is not connected, when it is not.
    let tunnelError: String?
    let key: String
    let fingerprint: String
    let words: String?
    let label: String
}

struct TunnelOutcome: Codable, Sendable {
    let tunnel: Bool
}
