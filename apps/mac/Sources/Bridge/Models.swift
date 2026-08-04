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
    var tier: String?
    /// Profile picture URL, when the account has one.
    var avatar: String?
    var lastSyncAt: String?
    /// Server-side machine records. The shape belongs to the API, so this
    /// decodes the few fields the UI shows and ignores the rest.
    var machines: [Machine]
    var schemaCurrent: UInt32?
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

    enum CodingKeys: String, CodingKey {
        case machineID = "id"
        case label
        case lastSyncAt
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

/// Render an ISO-8601 instant from the server as something readable.
///
/// Returns nil rather than a placeholder when it cannot be parsed, so the
/// caller decides what absence looks like.
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
        "cline", "openclaw", "zed", "copilot", "antigravity",
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
    /// Author time in unix seconds: when the work was done, not when a rebase
    /// last touched it.
    var timestamp: Int64
    /// True while the commit is not on the upstream branch yet. False when
    /// there is no upstream at all, because then nothing is known either way.
    var unpushed: Bool

    /// The seven characters everyone actually reads.
    var shortID: String { String(id.prefix(7)) }

    var date: Date { Date(timeIntervalSince1970: TimeInterval(timestamp)) }
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

    var changeCount: Int { git?.files.count ?? 0 }

    /// `+120 −8`, or nil when there is nothing to say.
    var diffStat: String? {
        guard let git, git.isRepo, !git.files.isEmpty else { return nil }
        let plus = "+\(git.added)"
        let minus = git.removed > 0 ? " −\(git.removed)" : ""
        return git.partial ? "\(plus)\(minus)+" : "\(plus)\(minus)"
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
/// `data` is base64 because the bytes are not valid UTF-8 in general: an
/// escape sequence can be cut in half at a read boundary.
struct PtyChunk: Codable, Sendable {
    var data: String
    /// Offset to ask for next time.
    var nextOffset: UInt64
    /// Bytes dropped before this chunk because this reader fell behind the
    /// host's bounded buffer. Zero in normal use, and never silently ignored.
    var dropped: UInt64
}
