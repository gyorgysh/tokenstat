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
                     start: Int64 = 0, end: Int64? = nil) -> ChatDisplayItem {
        .init(id: id, kind: .tool(ChatToolState(
            callId: id, verb: verb, target: "t-\(id)", running: running, failed: failed,
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
        compactLiveTurn()
        standardFoldsReadsAndThinking()
        standardKeepsALoneReadAndBreaksRuns()
        standardLeavesStreamingThoughtOpen()
        openGroupsListTheirStepsAsRows()
        groupIDsHoldWhileATurnGrows()
        ownerFindsClosedMembersOnly()
        countsMatchTheirMembers()
        previewDropsMarkdownMarks()
        print("ChatTranscriptFoldTests passed")
    }

    static func detailedIsTheIdentity() {
        let rows = [user("u1"), think("k1"), tool("t1", "Read"), tool("t2", "Read"), say("a1"), usage("x1", 0.1)]
        require(fold(rows, .detailed) == rows, "Detailed changes nothing")
    }

    static func compactFoldsWorkBetweenQuestionAndAnswer() {
        let rows = [
            user("u1"), think("k1"), say("a0"), tool("t1", "Bash"), edit("e1", "a.swift"), say("a1"), usage("x1", 0.25),
            user("u2"), tool("t2", "Read"), say("a2"),
        ]
        let out = fold(rows, .compact)
        require(ids(out) == ["u1", "g:k1", "a1", "u2", "g:t2", "a2"], "Compact is question, work line, answer: \(ids(out))")
        let first = group(out, "g:k1")
        require(first?.style == .work, "a work line")
        require(first?.memberIDs == ["k1", "a0", "t1", "e1"], "in-between prose folds with the work")
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

    static func standardFoldsReadsAndThinking() {
        let rows = [user("u1"), think("k1"), tool("t1", "Read"), tool("t2", "Grep"), tool("t3", "WebFetch"),
                    tool("t4", "Bash"), edit("e1", "a"), say("a1"), usage("x1", 0.1)]
        let out = fold(rows, .standard)
        require(ids(out) == ["u1", "g:k1", "g:t1", "t4", "e1", "a1", "x1"], "Standard folds thought and reads: \(ids(out))")
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
}
