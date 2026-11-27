// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

import Foundation

enum ChatDetail: String, CaseIterable, Sendable {
    case minimal
    case compact
    case standard
    case detailed
}

struct ChatStepGroup: Equatable, Sendable {
    struct Activity: Equatable, Sendable, Identifiable {
        let id: String
        let verb: String
        let target: String
        let running: Bool
        var failed = false
    }

    enum Style: Equatable, Sendable {
        case work
        case explored
        case thought
        case step
    }

    var style: Style
    var open: Bool
    var memberIDs: [String]
    var steps = 0
    var files = 0
    var added: UInt64 = 0
    var removed: UInt64 = 0
    var reads = 0
    var searches = 0
    var pages = 0
    var failures = 0
    var running = false
    var liveVerb: String?
    var liveTarget: String?
    var recentActivity: [Activity] = []
    var activityPreview: [Activity] {
        style == .work && running && !open ? recentActivity : []
    }
    var startedAtMs: Int64?
    var endedAtMs: Int64?
    var cost: Double?
    var preview: String?
    var plain = false
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
    private static let readVerbs: Set<String> = ["Read"]
    private static let searchVerbs: Set<String> = ["Grep", "Search", "Glob", "Find", "WebSearch"]
    private static let pageVerbs: Set<String> = ["WebFetch"]

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
        case .minimal:
            folded = minimalFold(items, running: running, isOpen: isOpen)
        case .compact:
            folded = compactFold(items, running: running, isOpen: isOpen)
        }
        return withTurnChanges(folded, raw: items, running: running)
    }


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
            case .user where !item.isSteer:
                close()
                turn += 1
            case let .edit(state) where !state.failed && !state.running:
                if current.files.isEmpty { current = ChatTurnChanges(id: "changes:\(item.id)", files: []) }
                if let index = building[state.path] {
                    current.files[index].added += UInt64(state.added)
                    current.files[index].removed += UInt64(state.removed)
                    current.files[index].patches.append(state.patch)
                } else {
                    building[state.path] = current.files.count
                    current.files.append(.init(path: state.path, added: UInt64(state.added), removed: UInt64(state.removed), patches: [state.patch]))
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
            if case .user = item.kind, !item.isSteer {
                if let finished = changes[turn] { out.append(ChatDisplayItem(id: finished.id, kind: .changes(finished))) }
                turn += 1
            }
            out.append(item)
        }
        if !running, let finished = changes[turn] {
            out.append(ChatDisplayItem(id: finished.id, kind: .changes(finished)))
        }
        return out
    }

    static func owner(of id: String, in folded: [ChatDisplayItem]) -> String? {
        for item in folded {
            if case let .group(group) = item.kind, !group.open,
               group.memberIDs.contains(id) || item.imageRowIDs.contains(id) {
                return item.id
            }
        }
        return nil
    }

    static func groupID(firstMember id: String) -> String { "g:\(id)" }


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


    private static func compactFold(
        _ items: [ChatDisplayItem],
        running: Bool,
        isOpen: (String) -> Bool
    ) -> [ChatDisplayItem] {
        var out: [ChatDisplayItem] = []
        out.reserveCapacity(items.count)
        var run: [ChatDisplayItem] = []

        func line(_ style: ChatStepGroup.Style, _ members: [ChatDisplayItem], running: Bool) {
            var group = make(style, members, running: running)
            group.plain = true
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
                    group.plain = true
                    emit(group, members: [item], into: &out, isOpen: isOpen)
                }
            case let .tool(state):
                flushRun(trailing: false)
                line(.step, [item], running: state.running)
            case let .edit(state):
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


    private static func minimalFold(
        _ items: [ChatDisplayItem],
        running: Bool,
        isOpen: (String) -> Bool
    ) -> [ChatDisplayItem] {
        var out: [ChatDisplayItem] = []
        var starts = items.indices.filter { if case .user = items[$0].kind, !items[$0].isSteer { return true } else { return false } }
        if starts.first != 0 { starts.insert(0, at: 0) }
        for (n, start) in starts.enumerated() where start < items.count {
            let end = n + 1 < starts.count ? starts[n + 1] : items.count
            minimalTurn(items[start..<end], live: running && end == items.count, isOpen: isOpen, into: &out)
        }
        return out
    }

    private static func minimalTurn(
        _ turn: ArraySlice<ChatDisplayItem>,
        live: Bool,
        isOpen: (String) -> Bool,
        into out: inout [ChatDisplayItem]
    ) {
        var members: [ChatDisplayItem] = []
        var usage: [ChatDisplayItem] = []
        var cost = 0.0
        var knownCost = true
        var lastHeader: Int?

        func flush(trailing: Bool) {
            guard !members.isEmpty else { return }
            lastHeader = out.count
            let thoughtsOnly = members.allSatisfy { if case .thinking = $0.kind { return true } else { return false } }
            var group = make(thoughtsOnly ? .thought : .work, members, running: live && trailing)
            if thoughtsOnly, case let .thinking(text) = members[0].kind { group.preview = preview(of: text) }
            if live && trailing, case let .thinking(text) = members.last?.kind {
                group.preview = preview(of: text)
            }
            emit(group, members: members, into: &out, isOpen: isOpen)
            members = []
        }

        for index in turn.indices {
            let item = turn[index]
            switch item.kind {
            case let .usage(_, _, spent):
                cost += spent ?? 0
                knownCost = knownCost && spent != nil && spent?.isFinite == true && (spent ?? -1) >= 0
                usage.append(item)
            case .thinking, .tool, .edit:
                members.append(item)
            default:
                flush(trailing: false)
                out.append(item)
            }
        }
        flush(trailing: true)

        if let lastHeader, knownCost, cost.isFinite, cost > 0, case var .group(group) = out[lastHeader].kind {
            group.cost = cost
            let previous = out[lastHeader]
            out[lastHeader] = ChatDisplayItem(id: previous.id, kind: .group(group), lastSequence: previous.lastSequence,
                imageAttachments: previous.imageAttachments, imageRowIDs: previous.imageRowIDs)
        } else if let first = usage.first {
            var input: UInt64 = 0, output: UInt64 = 0
            for row in usage {
                if case let .usage(nextInput, nextOutput, _) = row.kind {
                    let sumInput = input.addingReportingOverflow(nextInput)
                    let sumOutput = output.addingReportingOverflow(nextOutput)
                    input = sumInput.overflow ? .max : sumInput.partialValue
                    output = sumOutput.overflow ? .max : sumOutput.partialValue
                }
            }
            out.append(ChatDisplayItem(id: first.id,
                kind: .usage(input: input, output: output, cost: knownCost && cost.isFinite ? cost : nil),
                lastSequence: usage.last?.lastSequence))
        }
    }


    private static func emit(
        _ group: ChatStepGroup,
        members: [ChatDisplayItem],
        into out: inout [ChatDisplayItem],
        isOpen: (String) -> Bool
    ) {
        let fresh = groupID(firstMember: members[0].id)
        let id = ChatFoldContinuity.current?.id("group", members: members.map(\.id), fresh: fresh) ?? fresh
        var group = group
        group.open = isOpen(id)
        var header = ChatDisplayItem(id: id, kind: .group(group), lastSequence: members.last?.lastSequence)
        if !group.open {
            var seen = Set<String>()
            header.imageAttachments = members.flatMap(\.imageAttachments).filter { seen.insert($0.id).inserted }
            header.imageRowIDs = members.flatMap(\.imageRowIDs)
        }
        out.append(header)
        guard group.open else { return }
        for member in members {
            var row = member
            row.groupID = id
            if group.plain { row.plainStep = members.count == 1 ? .detail : .line }
            out.append(row)
        }
    }

    private static func make(_ style: ChatStepGroup.Style, _ members: [ChatDisplayItem], running: Bool) -> ChatStepGroup {
        var group = ChatStepGroup(style: style, open: false, memberIDs: members.map(\.id))
        var paths = Set<String>()
        var anyRunning = false

        func activity(_ member: ChatDisplayItem, verb: String, target: String, running: Bool, failed: Bool) {
            guard style == .work else { return }
            let line = String(target.prefix(160))
                .split(omittingEmptySubsequences: false, whereSeparator: { $0.isNewline })
                .first.map(String.init) ?? ""
            group.recentActivity.append(.init(
                id: member.id, verb: verb,
                target: line.trimmingCharacters(in: .whitespaces), running: running, failed: failed
            ))
            if group.recentActivity.count > 3 {
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
                activity(member, verb: state.verb, target: state.target, running: state.running, failed: state.failed)
                if state.failed { group.failures += 1 }
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
                activity(member, verb: "Edit", target: state.path, running: state.running, failed: state.failed)
                if state.failed { group.failures += 1 }
                paths.insert(state.path)
                group.added += UInt64(state.added)
                group.removed += UInt64(state.removed)
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
        group.running = anyRunning || running
        return group
    }

    private static func isExploration(_ verb: String) -> Bool {
        readVerbs.contains(verb) || searchVerbs.contains(verb) || pageVerbs.contains(verb)
    }

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
