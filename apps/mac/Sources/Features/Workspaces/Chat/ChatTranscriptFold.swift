// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

import Foundation

/// How much of an agent's work a transcript shows between a question and
/// its answer.
///
/// One setting rather than a page of switches. Every level keeps the rows a
/// person has to see: what they asked, every reply, an approval the agent is
/// waiting on, a failure, a handoff and an attachment. The levels differ only
/// in how the steps in between are drawn.
enum ChatDetail: String, CaseIterable, Sendable {
    /// One quiet line per step: "Edited vault.rs +6 −2", "Ran cargo test",
    /// "Explored 4 files, 2 searches". No cards and no output until a line
    /// is opened. What most editors show.
    case minimal
    /// One line per stretch of work: "Worked 3m · 14 steps · 2 files".
    case compact
    /// Thinking and runs of reads and searches fold to one line each.
    /// Commands and edits keep their own rows.
    case standard
    /// Every step on its own row, with its output open.
    case detailed
}

/// A folded group standing in for several transcript rows.
struct ChatStepGroup: Equatable, Sendable {
    struct Activity: Equatable, Sendable, Identifiable {
        let id: String
        let verb: String
        let target: String
        let running: Bool
    }

    enum Style: Equatable, Sendable {
        /// Compact: a stretch of tool activity between visible replies.
        case work
        /// Standard: consecutive reads, searches and page fetches.
        case explored
        /// A block of reasoning, in Compact or Standard.
        case thought
        /// Minimal: one command or edit, as a single line.
        case step
    }

    var style: Style
    /// Whether the steps are shown below this line as rows of their own.
    var open: Bool
    /// The rows this line stands for, oldest first. A search hit or a kept
    /// reading place can name one of these, and the group has to be found
    /// and opened for it.
    var memberIDs: [String]
    /// Tool calls and edits. Thinking is not counted as a step.
    var steps = 0
    /// Distinct files edited, and the lines those edits added and removed.
    var files = 0
    var added: UInt32 = 0
    var removed: UInt32 = 0
    var reads = 0
    var searches = 0
    var pages = 0
    /// Still being added to: the conversation is running and nothing has
    /// come after this group yet.
    var running = false
    /// The step running right now, for the collapsed line to name.
    var liveVerb: String?
    var liveTarget: String?
    /// A few recent actions, with running calls kept ahead of finished ones
    /// when choosing what fits. Output stays in the expandable member rows.
    var recentActivity: [Activity] = []
    /// Keep Compact informative while work runs, and return to one line
    /// afterwards. Opening the group already shows these calls in full.
    var activityPreview: [Activity] {
        style == .work && running && !open ? recentActivity : []
    }
    /// The first step's start and the last step's end, when the host
    /// recorded them.
    var startedAtMs: Int64?
    var endedAtMs: Int64?
    /// Reported spend for the turn this group belongs to, in Compact, where
    /// the usage row itself is not drawn.
    var cost: Double?
    /// The first line of a folded thought.
    var preview: String?
    /// Drawn as Minimal draws it: a plain line with no icon or chevron.
    var minimal = false
    /// The one step a single-member group stands for: its tool name, and
    /// the file or command it acted on.
    var verb: String?
    var subject: String?
}

/// Folds coalesced transcript rows into what a detail level shows.
///
/// A second pass after `ChatDisplayItem.coalesce`, so the rows every client
/// already builds stay exactly as they were and Detailed is the identity.
/// An open group is not one tall row: its header comes first and its steps
/// follow as ordinary rows marked with `groupID`. A lazy stack measures them
/// one at a time, and the spinner, live markdown and hover all keep working
/// on the rows they always worked on.
enum ChatTranscriptFold {
    /// Verbs that only look. A run of these reads as one line in Standard.
    private static let readVerbs: Set<String> = ["Read"]
    private static let searchVerbs: Set<String> = ["Grep", "Search", "Glob", "Find", "WebSearch"]
    private static let pageVerbs: Set<String> = ["WebFetch"]

    /// - Parameters:
    ///   - running: whether the conversation's last turn is still going.
    ///   - isOpen: whether a group, by id, is shown with its steps.
    static func fold(
        _ items: [ChatDisplayItem],
        detail: ChatDetail,
        running: Bool,
        isOpen: (String) -> Bool
    ) -> [ChatDisplayItem] {
        let folded: [ChatDisplayItem]
        switch detail {
        case .detailed:
            folded = items
        case .standard:
            folded = standard(items, running: running, isOpen: isOpen)
        case .compact:
            folded = compact(items, running: running, isOpen: isOpen)
        case .minimal:
            folded = minimal(items, running: running, isOpen: isOpen)
        }
        return withTurnChanges(folded, raw: items, running: running)
    }

    // MARK: Files changed

    /// A turn's edits, one row per file, after the turn has finished.
    ///
    /// Read from the raw rows, since a closed group hides its edits from the
    /// folded list. Turns are counted the same way in both lists: user rows
    /// are never folded, so the n-th one starts the same turn in each.
    static func withTurnChanges(_ folded: [ChatDisplayItem], raw: [ChatDisplayItem], running: Bool) -> [ChatDisplayItem] {
        var changes: [Int: ChatTurnChanges] = [:]
        var turn = 0
        var building: [String: Int] = [:]
        var current = ChatTurnChanges(id: "", files: [])
        func close() {
            if !current.files.isEmpty { changes[turn] = current }
            current = ChatTurnChanges(id: "", files: [])
            building = [:]
        }
        for item in raw {
            switch item.kind {
            case .user:
                close()
                turn += 1
            case let .edit(state) where !state.failed && !state.running:
                if current.files.isEmpty { current = ChatTurnChanges(id: "changes:\(item.id)", files: []) }
                if let index = building[state.path] {
                    current.files[index].added += state.added
                    current.files[index].removed += state.removed
                } else {
                    building[state.path] = current.files.count
                    current.files.append(.init(path: state.path, added: state.added, removed: state.removed))
                }
            default:
                continue
            }
        }
        close()
        guard !changes.isEmpty else { return folded }
        var out: [ChatDisplayItem] = []
        out.reserveCapacity(folded.count + changes.count)
        turn = 0
        for item in folded {
            if case .user = item.kind {
                if let finished = changes[turn] { out.append(ChatDisplayItem(id: finished.id, kind: .changes(finished))) }
                turn += 1
            }
            out.append(item)
        }
        // The turn still running gets its card when it ends.
        if !running, let finished = changes[turn] {
            out.append(ChatDisplayItem(id: finished.id, kind: .changes(finished)))
        }
        return out
    }

    /// The group header standing for `id`, when `id` is one of a closed
    /// group's steps. Nil when the row is drawn as itself or is not here.
    static func owner(of id: String, in folded: [ChatDisplayItem]) -> String? {
        for item in folded {
            if case let .group(group) = item.kind, !group.open, group.memberIDs.contains(id) {
                return item.id
            }
        }
        return nil
    }

    /// A group's row id. Named after its first step, so it holds while a
    /// live turn adds steps after it and when an older page lands above.
    static func groupID(firstMember id: String) -> String { "g:\(id)" }

    // MARK: Standard

    private static func standard(
        _ items: [ChatDisplayItem],
        running: Bool,
        isOpen: (String) -> Bool
    ) -> [ChatDisplayItem] {
        var out: [ChatDisplayItem] = []
        out.reserveCapacity(items.count)
        var run: [ChatDisplayItem] = []

        func flushRun(trailing: Bool) {
            defer { run = [] }
            // One read is a row like any other. Folding it would hide the
            // only thing it says behind a line that says less.
            guard run.count >= 2 else {
                out.append(contentsOf: run)
                return
            }
            emit(make(.explored, run, running: running && trailing), members: run, into: &out, isOpen: isOpen)
        }

        for (index, item) in items.enumerated() {
            switch item.kind {
            case let .tool(state) where !state.failed && isExploration(state.verb):
                run.append(item)
            case let .thinking(text):
                flushRun(trailing: false)
                // Reasoning still arriving stays open: watching it is the
                // point. It folds once anything comes after it.
                if running, index == items.count - 1 {
                    out.append(item)
                } else {
                    var group = make(.thought, [item], running: false)
                    group.preview = preview(of: text)
                    emit(group, members: [item], into: &out, isOpen: isOpen)
                }
            default:
                flushRun(trailing: false)
                out.append(item)
            }
        }
        flushRun(trailing: true)
        return out
    }

    // MARK: Minimal

    /// Every step is one line. Runs of reads and searches still read as
    /// one, even a run of one, because "Explored ChatModel.swift" says what
    /// a lone Read row says in less room.
    private static func minimal(
        _ items: [ChatDisplayItem],
        running: Bool,
        isOpen: (String) -> Bool
    ) -> [ChatDisplayItem] {
        var out: [ChatDisplayItem] = []
        out.reserveCapacity(items.count)
        var run: [ChatDisplayItem] = []

        func line(_ style: ChatStepGroup.Style, _ members: [ChatDisplayItem], running: Bool) {
            var group = make(style, members, running: running)
            group.minimal = true
            emit(group, members: members, into: &out, isOpen: isOpen)
        }

        func flushRun(trailing: Bool) {
            defer { run = [] }
            guard !run.isEmpty else { return }
            line(.explored, run, running: running && trailing)
        }

        for (index, item) in items.enumerated() {
            switch item.kind {
            case let .tool(state) where !state.failed && isExploration(state.verb):
                run.append(item)
            case let .thinking(text):
                flushRun(trailing: false)
                if running, index == items.count - 1 {
                    out.append(item)
                } else {
                    var group = make(.thought, [item], running: false)
                    group.preview = preview(of: text)
                    group.minimal = true
                    emit(group, members: [item], into: &out, isOpen: isOpen)
                }
            case let .tool(state) where !state.failed:
                flushRun(trailing: false)
                line(.step, [item], running: state.running)
            case let .edit(state) where !state.failed:
                flushRun(trailing: false)
                line(.step, [item], running: state.running)
            default:
                flushRun(trailing: false)
                out.append(item)
            }
        }
        flushRun(trailing: true)
        return out
    }

    // MARK: Compact

    private static func compact(
        _ items: [ChatDisplayItem],
        running: Bool,
        isOpen: (String) -> Bool
    ) -> [ChatDisplayItem] {
        var out: [ChatDisplayItem] = []
        // A turn runs from one question to the next. Rows before the first
        // question (a window that opens mid-turn) are a turn of their own.
        var starts = items.indices.filter { if case .user = items[$0].kind { return true } else { return false } }
        if starts.first != 0 { starts.insert(0, at: 0) }
        for (n, start) in starts.enumerated() where start < items.count {
            let end = n + 1 < starts.count ? starts[n + 1] : items.count
            compactTurn(items[start..<end], live: running && end == items.count, isOpen: isOpen, into: &out)
        }
        return out
    }

    private static func compactTurn(
        _ turn: ArraySlice<ChatDisplayItem>,
        live: Bool,
        isOpen: (String) -> Bool,
        into out: inout [ChatDisplayItem]
    ) {
        var members: [ChatDisplayItem] = []
        var usage: [ChatDisplayItem] = []
        var cost = 0.0
        var lastHeader: Int?

        func flush(trailing: Bool) {
            guard !members.isEmpty else { return }
            lastHeader = out.count
            let thoughtsOnly = members.allSatisfy { if case .thinking = $0.kind { return true } else { return false } }
            var group = make(thoughtsOnly ? .thought : .work, members, running: live && trailing)
            if thoughtsOnly, case let .thinking(text) = members[0].kind { group.preview = preview(of: text) }
            emit(group, members: members, into: &out, isOpen: isOpen)
            members = []
        }

        for index in turn.indices {
            let item = turn[index]
            switch item.kind {
            case let .usage(_, _, spent):
                cost += spent ?? 0
                usage.append(item)
            case .thinking:
                members.append(item)
            case let .tool(state) where !state.failed:
                members.append(item)
            case let .edit(state) where !state.failed:
                members.append(item)
            default:
                // Replies, questions, failures and handoffs stay in order.
                flush(trailing: false)
                out.append(item)
            }
        }
        flush(trailing: true)

        // The spend rides on the turn's last work line. A turn with no work
        // to fold, or nothing spent because a plan covers it, keeps its usage
        // rows, or its token counts would just vanish.
        if let lastHeader, cost > 0, case var .group(group) = out[lastHeader].kind {
            group.cost = cost
            out[lastHeader] = ChatDisplayItem(id: out[lastHeader].id, kind: .group(group))
        } else {
            out.append(contentsOf: usage)
        }
    }

    // MARK: Building groups

    private static func emit(
        _ group: ChatStepGroup,
        members: [ChatDisplayItem],
        into out: inout [ChatDisplayItem],
        isOpen: (String) -> Bool
    ) {
        let id = groupID(firstMember: members[0].id)
        var group = group
        group.open = isOpen(id)
        out.append(ChatDisplayItem(id: id, kind: .group(group), lastSequence: members.last?.lastSequence))
        guard group.open else { return }
        for member in members {
            var row = member
            row.groupID = id
            out.append(row)
        }
    }

    private static func make(_ style: ChatStepGroup.Style, _ members: [ChatDisplayItem], running: Bool) -> ChatStepGroup {
        var group = ChatStepGroup(style: style, open: false, memberIDs: members.map(\.id))
        var paths = Set<String>()
        var anyRunning = false

        func activity(_ member: ChatDisplayItem, verb: String, target: String, running: Bool) {
            guard style == .work else { return }
            let line = String(target.prefix(160))
                .split(omittingEmptySubsequences: false, whereSeparator: { $0.isNewline })
                .first.map(String.init) ?? ""
            group.recentActivity.append(.init(
                id: member.id, verb: verb,
                target: line.trimmingCharacters(in: .whitespaces), running: running
            ))
            if group.recentActivity.count > 3 {
                // A long-running call may precede several quick completions.
                // Keep it visible rather than implying everything has ended.
                let oldestFinished = group.recentActivity.firstIndex { !$0.running }
                group.recentActivity.remove(at: oldestFinished ?? 0)
            }
        }

        func span(_ start: Int64, _ end: Int64?) {
            if start > 0 { group.startedAtMs = min(group.startedAtMs ?? start, start) }
            if let end, end > 0 { group.endedAtMs = max(group.endedAtMs ?? end, end) }
        }

        for member in members {
            switch member.kind {
            case let .tool(state):
                group.steps += 1
                activity(member, verb: state.verb, target: state.target, running: state.running)
                if readVerbs.contains(state.verb) { group.reads += 1 }
                if searchVerbs.contains(state.verb) { group.searches += 1 }
                if pageVerbs.contains(state.verb) { group.pages += 1 }
                span(state.startedAtMs, state.endedAtMs)
                if state.running {
                    anyRunning = true
                    group.liveVerb = state.verb
                    group.liveTarget = state.target
                }
            case let .edit(state):
                group.steps += 1
                activity(member, verb: "Edit", target: state.path, running: state.running)
                paths.insert(state.path)
                group.added += state.added
                group.removed += state.removed
                span(state.startedAtMs, state.endedAtMs)
                if state.running {
                    anyRunning = true
                    group.liveVerb = "Edit"
                    group.liveTarget = state.path
                }
            default:
                continue
            }
        }
        group.files = paths.count
        if members.count == 1 {
            switch members[0].kind {
            case let .tool(state):
                group.verb = state.verb
                group.subject = state.target
            case let .edit(state):
                group.verb = "Edit"
                group.subject = state.path
            default:
                break
            }
        }
        // A step still running is running whatever came after it. A group
        // with nothing running is live only while it is the turn's last.
        group.running = anyRunning || running
        return group
    }

    private static func isExploration(_ verb: String) -> Bool {
        readVerbs.contains(verb) || searchVerbs.contains(verb) || pageVerbs.contains(verb)
    }

    /// The first line that says something, without its markdown marks.
    static func preview(of text: String) -> String? {
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let plain = line
                .trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "#*_>`- "))
                .trimmingCharacters(in: .whitespaces)
            if !plain.isEmpty { return String(plain.prefix(160)) }
        }
        return nil
    }
}
