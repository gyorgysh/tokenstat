// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

import Foundation

/// What a repository needs next, as one answer.
///
/// A card that lists everything it knows leaves the reader to rank it. This
/// ranks it instead, always in the same order: a person blocking work, then
/// work that failed, then work that is done and only needs a press, then what
/// is running by itself, then what was left unfinished.
enum RepositoryNextStep: Equatable {
    /// The folder is gone, so nothing else known about it can be acted on.
    case missing
    case waiting(chatID: String)
    case checksFailed(pull: UInt32)
    case changesRequested(pull: UInt32)
    case reviewRequested(pull: UInt32)
    case readyToMerge(pull: UInt32)
    case working(count: Int)
    case asleep
    case uncommitted(files: Int)
    case unpushed(commits: Int)
    case behind(commits: Int)
    case clear

    /// Whether the strip at the top of the page names it. Only what a person
    /// has to answer: running work and unfinished work stay on their cards.
    var needsPerson: Bool {
        switch self {
        case .waiting, .checksFailed, .changesRequested, .reviewRequested, .readyToMerge: true
        default: false
        }
    }

    /// Position in the order the page sorts by, most pressing first.
    var rank: Int {
        switch self {
        case .waiting: 0
        case .checksFailed: 1
        case .changesRequested: 2
        case .reviewRequested: 3
        case .readyToMerge: 4
        case .working: 5
        case .missing: 6
        case .uncommitted: 7
        case .unpushed: 8
        case .behind: 9
        case .asleep, .clear: 10
        }
    }
}

/// Everything the ranking reads, in plain values so it can be tested without
/// a host, an account or a screen.
struct RepositoryFacts: Equatable {
    struct Pull: Equatable {
        var number: UInt32
        /// Opened by the signed-in person. Somebody else's failing checks are
        /// theirs to fix.
        var mine: Bool
        var draft = false
        var failing = false
        var passing = false
        /// `approved`, `changes_requested`, `review_required`, or nothing.
        var review: String?
        var reviewRequested = false
    }

    var exists = true
    /// False only when the owning computer is known to be away.
    var reachable = true
    var waitingChatIDs: [String] = []
    var runningChats = 0
    var liveTerminals = 0
    var pulls: [Pull] = []
    var changedFiles = 0
    var unpushedCommits = 0
    var behindCommits = 0
    var lastActivity: Date?
    /// Something in the last fourteen days of usage.
    var hasRecentUsage = false
}

extension RepositoryNextStep {
    /// Every step a person owes this repository, most pressing first.
    static func owed(_ facts: RepositoryFacts) -> [RepositoryNextStep] {
        guard facts.exists else { return [] }
        var steps = facts.waitingChatIDs.map { RepositoryNextStep.waiting(chatID: $0) }
        let mine = facts.pulls.filter { $0.mine && !$0.draft }
        steps += mine.filter(\.failing).map { .checksFailed(pull: $0.number) }
        steps += mine.filter { !$0.failing && $0.review == "changes_requested" }
            .map { .changesRequested(pull: $0.number) }
        steps += facts.pulls.filter { $0.reviewRequested && !$0.mine && !$0.draft }
            .map { .reviewRequested(pull: $0.number) }
        // Approved alone is not enough: checks still running may yet fail.
        steps += mine.filter { $0.passing && $0.review == "approved" }
            .map { .readyToMerge(pull: $0.number) }
        return steps
    }

    static func next(_ facts: RepositoryFacts) -> RepositoryNextStep {
        guard facts.exists else { return .missing }
        if let first = owed(facts).first { return first }
        if facts.runningChats > 0 { return .working(count: facts.runningChats) }
        guard facts.reachable else { return .asleep }
        if facts.changedFiles > 0 { return .uncommitted(files: facts.changedFiles) }
        if facts.unpushedCommits > 0 { return .unpushed(commits: facts.unpushedCommits) }
        if facts.behindCommits > 0 { return .behind(commits: facts.behindCommits) }
        return .clear
    }

    /// Nothing recent and nothing left over, so one line is enough for it.
    static func isQuiet(_ facts: RepositoryFacts, now: Date = Date()) -> Bool {
        switch next(facts) {
        // Being behind is the ordinary state of a repository nobody is in.
        case .clear, .asleep, .behind: break
        default: return false
        }
        if facts.hasRecentUsage || facts.liveTerminals > 0 { return false }
        guard let last = facts.lastActivity else { return true }
        return now.timeIntervalSince(last) > 14 * 86_400
    }
}

/// Days the ribbon draws, oldest first, as the archive spells them.
enum RepositoryDays {
    static let count = 14

    static func keys(now: Date = Date(), calendar: Calendar = .gregorianLocal) -> [String] {
        (0..<count).reversed().compactMap { back in
            calendar.date(byAdding: .day, value: -back, to: now).map { key($0, calendar: calendar) }
        }
    }

    static func key(_ date: Date, calendar: Calendar = .gregorianLocal) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    static func date(_ key: String, calendar: Calendar = .gregorianLocal) -> Date? {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }
}

extension Calendar {
    static var gregorianLocal: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return calendar
    }
}

/// The order cards keep while the page is open.
///
/// Work changes rank every few seconds, and a card that moves out from under
/// the pointer is worse than one in a slightly stale place. The order is taken
/// once and only new or removed repositories change it.
enum RepositoryOrder {
    static func merge(held: [String], current: [String]) -> [String] {
        let present = Set(current)
        let kept = held.filter(present.contains)
        let known = Set(kept)
        return kept + current.filter { !known.contains($0) }
    }

    /// Where an arrow key lands in a grid, or nil at an edge.
    static func move(from index: Int, by delta: Int, count: Int) -> Int? {
        let next = index + delta
        return (0..<count).contains(next) ? next : nil
    }
}
