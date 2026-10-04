// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
// Compile with ChatDisplayItem.swift ChatTranscriptFold.swift ChatQuestion.swift using swiftc -parse-as-library, then run.
import Foundation

// Two models from Bridge/Models.swift, cut to what a row needs.
struct ChatAttachment: Hashable { var id: String }
struct ChatApproval: Hashable { var id: String; var decision: String? }

@main
struct ChatTranscriptFoldTests {
    static func require(_ condition: Bool, _ message: String) {
        precondition(condition, message)
    }

    // MARK: Rows

    static func user(_ id: String) -> ChatDisplayItem { .init(id: id, kind: .user("q")) }
    static func say(_ id: String) -> ChatDisplayItem { .init(id: id, kind: .assistant("a", backend: nil)) }
    static func think(_ id: String, _ text: String = "## Plan\nread it") -> ChatDisplayItem { .init(id: id, kind: .thinking(text)) }
    static func usage(_ id: String, _ cost: Double) -> ChatDisplayItem { .init(id: id, kind: .usage(input: 1, output: 1, cost: cost)) }
    static func failed(_ id: String) -> ChatDisplayItem { .init(id: id, kind: .failed("broke")) }
    static func approval(_ id: String) -> ChatDisplayItem { .init(id: id, kind: .approval(ChatApproval(id: id, decision: nil))) }
    static func handoff(_ id: String) -> ChatDisplayItem { .init(id: id, kind: .handoff(to: "codex", brief: "b")) }

    static func tool(_ id: String, _ verb: String, running: Bool = false, failed: Bool = false,
                     start: Int64 = 0, end: Int64? = nil, target: String? = nil) -> ChatDisplayItem {
        .init(id: id, kind: .tool(ChatToolState(
            callId: id, verb: verb, target: target ?? "t-\(id)", running: running, failed: failed,
            detail: nil, startedAtMs: start, endedAtMs: end, snippet: []
        )))
    }

    static func edit(_ id: String, _ path: String, added: UInt32 = 0, removed: UInt32 = 0,
                     running: Bool = false, failed: Bool = false) -> ChatDisplayItem {
        .init(id: id, kind: .edit(ChatEditState(
            path: path, added: added, removed: removed, patch: "", revision: 1,
            running: running, failed: failed, startedAtMs: 0, endedAtMs: nil
        )))
    }

    static func ids(_ rows: [ChatDisplayItem]) -> [String] { rows.map(\.id) }

    static func group(_ rows: [ChatDisplayItem], _ id: String) -> ChatStepGroup? {
        for row in rows where row.id == id {
            if case let .group(group) = row.kind { return group }
        }
        return nil
    }

    static let closed: (String) -> Bool = { _ in false }
    static let allOpen: (String) -> Bool = { _ in true }

    static func fold(_ rows: [ChatDisplayItem], _ detail: ChatDetail, running: Bool = false,
                     isOpen: (String) -> Bool = closed) -> [ChatDisplayItem] {
        ChatTranscriptFold.fold(rows, detail: detail, running: running, isOpen: isOpen)
    }

    // MARK: Tests

    static func main() {
        detailedIsTheIdentity()
        compactFoldsWorkBetweenQuestionAndAnswer()
        compactNeverFoldsWhatAPersonMustSee()
        compactKeepsUsageWhenThereIsNoWork()
        compactKeepsEveryReplyVisible()
        compactLiveTurn()
        compactActivitySurvivesBetweenCalls()
        compactActivityKeepsRunningCallsVisible()
        compactActivityIsBoundedAndDoesNotHideFailures()
        standardFoldsReadsAndThinking()
        standardKeepsALoneReadAndBreaksRuns()
        standardLeavesStreamingThoughtOpen()
        openGroupsListTheirStepsAsRows()
        groupIDsHoldWhileATurnGrows()
        ownerFindsClosedMembersOnly()
        countsMatchTheirMembers()
        previewDropsMarkdownMarks()
        minimalMakesEveryStepOneLine()
        minimalKeepsRunningStepsAndOpensToTheRow()
        turnChangesSumPerFileAndWaitForTheTurn()
        print("ChatTranscriptFoldTests passed")
    }

    static func detailedIsTheIdentity() {
        let rows = [user("u1"), think("k1"), tool("t1", "Read"), tool("t2", "Read"), say("a1"), usage("x1", 0.1)]
        require(fold(rows, .detailed) == rows, "Detailed changes nothing")
        let edited = rows + [edit("e1", "a.swift", added: 1)]
        require(ids(fold(edited, .detailed)) == ids(edited) + ["changes:e1"], "apart from what the turn changed")
    }

    static func compactFoldsWorkBetweenQuestionAndAnswer() {
        let rows = [
            user("u1"), think("k1"), say("a0"), tool("t1", "Bash"), edit("e1", "a.swift"), say("a1"), usage("x1", 0.25),
            user("u2"), tool("t2", "Read"), say("a2"),
        ]
        let out = fold(rows, .compact)
        require(ids(out) == ["u1", "g:k1", "a0", "g:t1", "a1", "changes:e1", "u2", "g:t2", "a2"], "Compact keeps replies between work groups: \(ids(out))")
        require(group(out, "g:k1")?.style == .thought, "reasoning alone is a thought line")
        let first = group(out, "g:t1")
        require(first?.style == .work, "a work line")
        require(first?.memberIDs == ["t1", "e1"], "only tool activity folds with the work")
        require(first?.steps == 2, "thinking and prose are not steps")
        require(first?.cost == 0.25, "the turn's spend rides on its work line")
        require(group(out, "g:t2")?.cost == nil, "no usage, no figure")
    }

    static func compactNeverFoldsWhatAPersonMustSee() {
        let rows = [
            user("u1"), tool("t1", "Bash"), approval("p1"), tool("t2", "Bash"),
            tool("t3", "Bash", failed: true), edit("e1", "a", failed: true), handoff("h1"),
            .init(id: "f1", kind: .attachment(ChatAttachment(id: "f1"))), failed("x1"),
        ]
        for detail in ChatDetail.allCases {
            let out = fold(rows, detail)
            for must in ["u1", "p1", "t3", "e1", "h1", "f1", "x1"] {
                require(out.contains { $0.id == must }, "\(detail) shows \(must)")
                require(ChatTranscriptFold.owner(of: must, in: out) == nil, "\(detail) never folds \(must)")
            }
        }
        let out = fold(rows, .compact)
        require(ids(out) == ["u1", "g:t1", "p1", "g:t2", "t3", "e1", "h1", "f1", "x1"],
                "an approval splits the work where it happened: \(ids(out))")
    }

    static func compactKeepsUsageWhenThereIsNoWork() {
        let out = fold([user("u1"), say("a1"), usage("x1", 0.5)], .compact)
        require(ids(out) == ["u1", "a1", "x1"], "nothing to fold keeps the usage row: \(ids(out))")
        let plan = fold([user("u1"), tool("t1", "Read"), say("a1"), usage("x1", 0)], .compact)
        require(ids(plan) == ["u1", "g:t1", "a1", "x1"], "nothing spent keeps the token counts: \(ids(plan))")
    }

    static func compactKeepsEveryReplyVisible() {
        let rows = [user("u1"), say("a0"), tool("t1", "Read"), say("a1"),
                    tool("t2", "Bash", running: true), say("a2")]
        for running in [false, true] {
            let out = fold(rows, .compact, running: running)
            require(ids(out) == ["u1", "a0", "g:t1", "a1", "g:t2", "a2"], "all replies remain in order")
            for id in ["a0", "a1", "a2"] {
                require(ChatTranscriptFold.owner(of: id, in: out) == nil, "a reply is never owned by a folded group")
            }
        }
    }

    static func compactLiveTurn() {
        let rows = [user("u1"), think("k1"), tool("t1", "Read", running: true)]
        let out = fold(rows, .compact, running: true)
        let live = group(out, "g:k1")
        require(live?.running == true, "the trailing work line of a live turn is running")
        require(live?.liveVerb == "Read" && live?.liveTarget == "t-t1", "it names the running step")

        let streaming = fold(rows + [say("a1")], .compact, running: true)
        require(ids(streaming) == ["u1", "g:k1", "a1"], "streaming prose stays visible")
        require(group(streaming, "g:k1")?.running == true, "a still-running step keeps the line running")

        let settled = fold([user("u1"), think("k1"), tool("t1", "Read"), say("a1")], .compact, running: true)
        require(group(settled, "g:k1")?.running == false, "work before the answer is not running once its steps end")
    }

    static func compactActivitySurvivesBetweenCalls() {
        let rows = [user("u1"), think("k1"), tool("r1", "Read"), tool("w1", "Write"),
                    edit("e1", "src/App.swift"), tool("d1", "Diff", running: true)]
        let active = group(fold(rows, .compact, running: true), "g:k1")!
        require(active.activityPreview.map(\.id) == ["w1", "e1", "d1"], "the latest actions remain visible in order")
        require(active.activityPreview.map(\.verb) == ["Write", "Edit", "Diff"], "writes, native edits and comparisons name their action")
        require(active.activityPreview.map(\.running) == [false, false, true], "only the active comparison uses present tense")
        require(active.activityPreview[1].target == "src/App.swift", "the edit identifies its file")

        let between = Array(rows.dropLast()) + [tool("d1", "Diff")]
        let waiting = group(fold(between, .compact, running: true), "g:k1")!
        require(waiting.liveVerb == nil, "no tool is still running between calls")
        require(waiting.activityPreview.map(\.id) == ["w1", "e1", "d1"], "finished actions still show while the agent continues")
        require(waiting.activityPreview.allSatisfy { !$0.running }, "finished calls never claim to be running")
        require(group(fold(between, .compact), "g:k1")!.activityPreview.isEmpty, "a finished turn returns to a compact header")
        require(group(fold(between + [say("a1")], .compact, running: true), "g:k1")!.activityPreview.isEmpty,
                "a reply closes the preceding work preview")
        let open = fold(rows, .compact, running: true, isOpen: allOpen)
        require(group(open, "g:k1")!.activityPreview.isEmpty, "opening full steps removes the duplicate preview")
        require(open.contains { $0.id == "d1" && $0.groupID == "g:k1" }, "the active call is available as its full row")
    }

    static func compactActivityKeepsRunningCallsVisible() {
        let rows = [user("u1"), tool("slow", "Shell", running: true),
                    tool("r1", "Read"), tool("r2", "Read"), tool("r3", "Read"), tool("r4", "Read")]
        let preview = group(fold(rows, .compact, running: true), "g:slow")!.activityPreview
        require(preview.map(\.id) == ["slow", "r3", "r4"], "recent completions cannot push the running call out of view")
        require(preview.first?.running == true, "the retained older call still says it is running")
        let concurrent = [user("u1")] + (1...5).map { tool("t\($0)", "Shell", running: true) }
        require(group(fold(concurrent, .compact, running: true), "g:t1")!.activityPreview.map(\.id) == ["t3", "t4", "t5"],
                "many active calls show the newest three without growing the preview")
    }

    static func compactActivityIsBoundedAndDoesNotHideFailures() {
        let long = tool("long", "CustomTool", target: String(repeating: "x", count: 10_000) + "\nsecond line")
        let rows = [user("u1"), long, tool("bad", "Write", failed: true), edit("e1", "a.swift"), tool("blank", "")]
        let out = fold(rows, .compact, running: true)
        let first = group(out, "g:long")!
        require(first.recentActivity.first?.verb == "CustomTool", "an unknown tool keeps its real name")
        require(first.recentActivity.first?.target.count == 160, "long commands cannot produce a document-sized preview")
        require(out.contains { $0.id == "bad" }, "a failed call keeps its visible error row")
        let last = group(out, "g:e1")!
        require(last.activityPreview.map(\.id) == ["e1", "blank"], "a failure divides the work history")
        require(last.activityPreview.last?.verb == "", "unnamed calls retain the generic work fallback")
        let multiline = group(fold([tool("line", "Shell", target: "  swift test  \nmore code")], .compact, running: true), "g:line")!
        require(multiline.activityPreview.first?.target == "swift test", "only the first command line is shown")
        let blank = group(fold([tool("line", "Shell", target: "\nmore code")], .compact, running: true), "g:line")!
        require(blank.activityPreview.first?.target == "", "a blank first line stays blank")

        let exploration = group(fold([tool("r1", "Read"), tool("r2", "Read")], .standard, running: true), "g:r1")!
        require(exploration.activityPreview.isEmpty, "Standard exploration stays a single header")
        let thought = group(fold([user("u1"), think("k1")], .compact, running: true), "g:k1")!
        require(thought.activityPreview.isEmpty, "reasoning alone does not invent tool activity")
    }

    static func standardFoldsReadsAndThinking() {
        let rows = [user("u1"), think("k1"), tool("t1", "Read"), tool("t2", "Grep"), tool("t3", "WebFetch"),
                    tool("t4", "Bash"), edit("e1", "a"), say("a1"), usage("x1", 0.1)]
        let out = fold(rows, .standard)
        require(ids(out) == ["u1", "g:k1", "g:t1", "t4", "e1", "a1", "x1", "changes:e1"], "Standard folds thought and reads: \(ids(out))")
        require(group(out, "g:k1")?.style == .thought, "thinking is a thought line")
        let explored = group(out, "g:t1")
        require(explored?.style == .explored, "reads are an explored line")
        require(explored?.reads == 1 && explored?.searches == 1 && explored?.pages == 1, "explored counts by kind")
    }

    static func standardKeepsALoneReadAndBreaksRuns() {
        let rows = [user("u1"), tool("t1", "Read"), tool("t2", "Bash"), tool("t3", "Read"), tool("t4", "Glob"),
                    tool("t5", "Read", failed: true), tool("t6", "Read")]
        let out = fold(rows, .standard)
        require(ids(out) == ["u1", "t1", "t2", "g:t3", "t5", "t6"], "lone reads stay rows, others break runs: \(ids(out))")
    }

    static func standardLeavesStreamingThoughtOpen() {
        let rows = [user("u1"), think("k1")]
        require(ids(fold(rows, .standard, running: true)) == ["u1", "k1"], "reasoning still arriving stays open")
        require(ids(fold(rows, .standard, running: false)) == ["u1", "g:k1"], "and folds once the turn is over")
    }

    static func openGroupsListTheirStepsAsRows() {
        let rows = [user("u1"), think("k1"), tool("t1", "Bash"), say("a1")]
        let out = fold(rows, .compact, isOpen: { $0 == "g:k1" })
        require(ids(out) == ["u1", "g:k1", "k1", "t1", "a1"], "an open group lists its steps after it: \(ids(out))")
        require(group(out, "g:k1")?.open == true, "the header knows it is open")
        require(out[2].groupID == "g:k1" && out[3].groupID == "g:k1", "steps name their group")
        require(out[0].groupID == nil && out[4].groupID == nil, "top-level rows name none")
        require(ChatTranscriptFold.owner(of: "t1", in: out) == nil, "a step of an open group is drawn as itself")
        let all = fold(rows, .compact, isOpen: allOpen)
        require(ids(all) == ids(out), "open-all opens the same group")
    }

    static func groupIDsHoldWhileATurnGrows() {
        var rows = [user("u1"), think("k1"), tool("t1", "Bash", running: true)]
        let before = ids(fold(rows, .compact, running: true))
        rows.append(tool("t2", "Bash", running: true))
        let after = ids(fold(rows, .compact, running: true))
        require(before == after && after == ["u1", "g:k1"], "a growing turn keeps its line")

        let paged = [user("u0"), say("a0")] + rows
        require(ids(fold(paged, .compact, running: true)).suffix(2) == ["u1", "g:k1"], "an older page above changes nothing")
    }

    static func ownerFindsClosedMembersOnly() {
        let rows = [user("u1"), tool("t1", "Read"), tool("t2", "Read"), think("k1"), say("a1")]
        let standard = fold(rows, .standard)
        require(ChatTranscriptFold.owner(of: "t2", in: standard) == "g:t1", "a read in an explored line")
        require(ChatTranscriptFold.owner(of: "k1", in: standard) == "g:k1", "a folded thought")
        require(ChatTranscriptFold.owner(of: "a1", in: standard) == nil, "a top-level row has no owner")
        require(ChatTranscriptFold.owner(of: "missing", in: standard) == nil, "an unknown row has no owner")
        require(ChatTranscriptFold.owner(of: "t2", in: fold(rows, .compact)) == "g:t1", "a step in a work line")
    }

    static func countsMatchTheirMembers() {
        let rows = [user("u1"),
                    tool("t1", "Bash", start: 1_000, end: 4_000),
                    edit("e1", "a.swift", added: 3, removed: 1),
                    edit("e2", "a.swift", added: 2, removed: 0),
                    edit("e3", "b.swift", added: 1, removed: 4),
                    tool("t2", "Bash", start: 5_000, end: 9_000),
                    say("a1")]
        let work = group(fold(rows, .compact), "g:t1")
        require(work?.steps == 5, "five steps")
        require(work?.files == 2, "two distinct files")
        require(work?.added == 6 && work?.removed == 5, "line totals add up")
        require(work?.startedAtMs == 1_000 && work?.endedAtMs == 9_000, "the span covers every step")
    }

    static func previewDropsMarkdownMarks() {
        require(ChatTranscriptFold.preview(of: "\n\n## **Plan** it\nmore") == "Plan** it", "leading marks go")
        require(ChatTranscriptFold.preview(of: "  \n- check the tests") == "check the tests", "bullets go")
        require(ChatTranscriptFold.preview(of: "\n  \n") == nil, "nothing to say is nil")
    }

    static func minimalMakesEveryStepOneLine() {
        let rows = [user("u1"), think("k1"), tool("t1", "Read"), tool("t2", "Grep"), tool("t3", "Bash", target: "cargo test"),
                    edit("e1", "src/a.swift", added: 6, removed: 2), tool("t4", "Read", target: "/w/sync.js"), say("a1"),
                    tool("t5", "Bash", failed: true)]
        let out = fold(rows, .minimal)
        require(ids(out) == ["u1", "g:k1", "g:t1", "g:t3", "g:e1", "g:t4", "a1", "t5", "changes:e1"],
                "Minimal is a line per step: \(ids(out))")
        for id in ["g:k1", "g:t1", "g:t3", "g:e1", "g:t4"] {
            require(group(out, id)?.minimal == true, "\(id) is drawn as a plain line")
        }
        let explored = group(out, "g:t1")!
        require(explored.style == .explored && explored.reads == 1 && explored.searches == 1, "reads and searches still read as one")
        let ran = group(out, "g:t3")!
        require(ran.style == .step && ran.verb == "Bash" && ran.subject == "cargo test", "a command is its own line")
        let edited = group(out, "g:e1")!
        require(edited.style == .step && edited.verb == "Edit" && edited.subject == "src/a.swift", "an edit names its file")
        require(edited.added == 6 && edited.removed == 2, "and the lines it changed")
        let lone = group(out, "g:t4")!
        require(lone.style == .explored && lone.subject == "/w/sync.js", "a lone read folds too, naming its file")
        require(ChatTranscriptFold.owner(of: "t5", in: out) == nil, "a failed step is never folded")
    }

    static func minimalKeepsRunningStepsAndOpensToTheRow() {
        let rows = [user("u1"), tool("t1", "Bash", running: true)]
        let out = fold(rows, .minimal, running: true)
        require(group(out, "g:t1")?.running == true, "a running command spins on its line")
        let done = fold([user("u1"), tool("t1", "Bash"), say("a1")], .minimal, running: true)
        require(group(done, "g:t1")?.running == false, "a finished one does not, even mid-turn")
        let open = fold([user("u1"), edit("e1", "a.swift", added: 1)], .minimal, isOpen: { $0 == "g:e1" })
        require(ids(open) == ["u1", "g:e1", "e1", "changes:e1"], "opening a line shows the full row below it: \(ids(open))")
        require(open[2].groupID == "g:e1", "and the row names its line")
        let reading = fold([user("u1"), think("k1")], .minimal, running: true)
        require(ids(reading) == ["u1", "k1"], "reasoning still arriving stays open")
    }

    static func turnChangesSumPerFileAndWaitForTheTurn() {
        let rows = [user("u1"), edit("e1", "/w/a.swift", added: 3, removed: 1), edit("e2", "/w/a.swift", added: 2),
                    edit("e3", "/w/b.swift", added: 1, removed: 4), edit("ef", "/w/c.swift", failed: true), say("a1"),
                    user("u2"), edit("e4", "/w/c.swift", added: 1), edit("er", "/w/d.swift", running: true), say("a2")]
        let live = fold(rows, .compact, running: true)
        require(ids(live).filter { $0.hasPrefix("changes:") } == ["changes:e1"], "the live turn has no card yet: \(ids(live))")
        require(ids(live).firstIndex(of: "changes:e1")! == ids(live).firstIndex(of: "u2")! - 1, "a card closes its turn")
        guard case let .changes(first)? = live.first(where: { $0.id == "changes:e1" })?.kind else {
            return require(false, "the first turn's card")
        }
        require(first.files.map(\.path) == ["/w/a.swift", "/w/b.swift"], "one row per file, first touched first, failures left out")
        require(first.files[0].added == 5 && first.files[0].removed == 1, "a file edited twice shows both")
        require(first.added == 6 && first.removed == 5, "the card totals its files")
        let finished = fold(rows, .compact, running: false)
        guard case let .changes(second)? = finished.last?.kind else { return require(false, "the last turn's card") }
        require(second.files.map(\.path) == ["/w/c.swift"], "a running edit is not a change yet")
        require(ids(fold([user("u1"), say("a1")], .minimal)) == ["u1", "a1"], "no edits, no card")
    }
}
