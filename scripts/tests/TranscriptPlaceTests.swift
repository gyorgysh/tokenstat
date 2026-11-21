// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
// Compile with TranscriptAnchor.swift ChatRowContinuity.swift ChatImageGrouping.swift ChatDisplayItem.swift ChatTranscriptFold.swift ChatQuestion.swift MuseToolPresentation.swift.
import SwiftUI

// What a transcript holds on to while rows arrive above the reader: the row
// to put back, the unit point that puts it back, and the ids that must not
// change when a page brings the start of something already on screen.

#if !TOKENSTAT_TEST
enum L10n { static func text(_ key: String, _ arguments: String...) -> String { key } }
#endif

struct ChatAttachment: Hashable, Sendable {
    var id: String
    var name: String
    var mediaType: String?
    var size: UInt64? = 1
    var toolCallId: String? = nil
}
struct ChatApproval: Hashable, Sendable { var id: String; var decision: String? }

@main
struct TranscriptPlaceTests {
    static func require(_ condition: Bool, _ message: String) {
        precondition(condition, message)
    }

    static func text(_ id: String, first: UInt64, last: UInt64) -> ChatDisplayItem {
        ChatDisplayItem(id: id, kind: .assistant("a", backend: nil), lastSequence: last, firstSequence: first)
    }

    static func tool(_ id: String, call: String) -> ChatDisplayItem {
        ChatDisplayItem(id: id, kind: .tool(ChatToolState(
            callId: call, verb: "Ran", target: "t", running: false, failed: false,
            detail: nil, startedAtMs: 0, endedAtMs: nil, snippet: []
        )))
    }

    static func image(_ id: String) -> ChatDisplayItem {
        ChatDisplayItem(id: id, kind: .attachment(ChatAttachment(id: "file-\(id)", name: "\(id).png", mediaType: "image/png")))
    }

    static func main() {
        anchors()
        streamedBlocks()
        toolCalls()
        groupsAndGalleries()
        print("Transcript place: anchors, unit points, carried block, tool, group and gallery ids passed")
    }

    static func anchors() {
        let viewport: CGFloat = 600
        // Inside a reply taller than the window: that reply is the anchor,
        // not the next row screens below it.
        let frames: [String: CGRect] = [
            "above": CGRect(x: 0, y: -900, width: 10, height: 400),
            "long": CGRect(x: 0, y: -94, width: 10, height: 1440),
            "next": CGRect(x: 0, y: 1358, width: 10, height: 80),
        ]
        let anchor = TranscriptAnchor.pick(frames, viewportHeight: viewport)
        require(anchor?.id == "long", "The row covering the top edge holds the place")
        require(TranscriptAnchor.candidates(frames, viewportHeight: viewport).map(\.id) == ["long"],
                "Rows off screen are not candidates")

        // The unit point puts the row's top back exactly, outside 0...1 too.
        for (top, height) in [(CGFloat(-94), CGFloat(1440)), (50, 100), (-30, 120), (580, 900), (0, 2000)] {
            let row = TranscriptAnchor(id: "r", top: top, height: height)
            let t = row.unitPoint(in: viewport).y
            require(abs(t * (viewport - height) - top) < 0.001, "Unit point for top \(top) height \(height)")
        }
        require(TranscriptAnchor(id: "r", top: -94, height: 1440).unitPoint(in: viewport).y > 0,
                "A tall row starting above the viewport needs no clamp")

        // A row exactly as tall as the viewport cannot be moved by a unit
        // point, so the next row holds the place.
        let exact: [String: CGRect] = [
            "exact": CGRect(x: 0, y: -10, width: 10, height: 600),
            "below": CGRect(x: 0, y: 590, width: 10, height: 40),
        ]
        require(TranscriptAnchor.pick(exact, viewportHeight: viewport)?.id == "below", "Exact-height rows are skipped")
        require(TranscriptAnchor.pick([:], viewportHeight: viewport) == nil, "No rows, no anchor")
        require(TranscriptAnchor.pick(frames, viewportHeight: 0) == nil, "No viewport, no anchor")
    }

    static func streamedBlocks() {
        // The first page held the end of a reply. The page before it brings
        // the reply's start, and the block is now named after an earlier
        // delta. It keeps the name it had on screen.
        let shown = [text("text-s100", first: 100, last: 150), tool("tool-s151", call: "c1")]
        let paged = [ChatDisplayItem(id: "user-s20", kind: .user("q")),
                     text("text-s40", first: 40, last: 150), tool("tool-s151", call: "c1")]
        let carried = ChatRowContinuity.carrying(paged, from: shown)
        require(carried.rows.map(\.id) == ["user-s20", "text-s100", "tool-s151"], "A paged block keeps its id")
        require(carried.rows[1].firstSequence == 40, "The carried block still knows where it starts")
        require(carried.extendedAtStart == ["text-s100"], "The block grew at its start")

        // And again on the next page, from the carried id.
        let again = ChatRowContinuity.carrying(
            [text("text-s10", first: 10, last: 150), tool("tool-s151", call: "c1")], from: carried.rows)
        require(again.rows.first?.id == "text-s100", "A block keeps its id across several pages")
        require(again.extendedAtStart == ["text-s100"], "Growth is reported for an already carried id")

        // Streaming grows the end of a block. Nothing is renamed or extended.
        let live = ChatRowContinuity.carrying([text("text-s100", first: 100, last: 160)],
                                              from: [text("text-s100", first: 100, last: 150)])
        require(live.rows.first?.id == "text-s100" && live.extendedAtStart.isEmpty, "Streaming changes nothing")

        // A different block is never renamed onto an old one.
        let unrelated = ChatRowContinuity.carrying([text("text-s10", first: 10, last: 90), text("text-s100", first: 100, last: 150)],
                                                   from: [text("text-s100", first: 100, last: 150)])
        require(unrelated.rows.map(\.id) == ["text-s10", "text-s100"], "Separate blocks keep their own ids")

        // Thinking and text are separate kinds of block.
        let mixed = ChatRowContinuity.carrying(
            [ChatDisplayItem(id: "think-s40", kind: .thinking("t"), lastSequence: 150, firstSequence: 40)],
            from: [text("text-s100", first: 100, last: 150)])
        require(mixed.rows.first?.id == "think-s40", "A thinking block is not carried onto a text id")
    }

    static func toolCalls() {
        // A call cut by the page boundary showed as its end alone, named
        // after the end. With its start it is named after the start.
        let carried = ChatRowContinuity.carrying([tool("tool-s90", call: "c7")], from: [tool("tool-s95", call: "c7")])
        require(carried.rows.first?.id == "tool-s95", "A tool row keeps its id when its start arrives")
        require(carried.extendedAtStart.isEmpty, "A tool carry is not text growth")

        // Another use of the same call id is a new row while the old one is
        // still there.
        let reused = ChatRowContinuity.carrying([tool("tool-s20", call: "c7"), tool("tool-s95", call: "c7")],
                                                from: [tool("tool-s95", call: "c7")])
        require(reused.rows.map(\.id) == ["tool-s20", "tool-s95"], "A reused call id stays a separate row")
    }

    static func groupsAndGalleries() {
        let memory = ChatFoldContinuity()
        require(memory.id("group", members: ["a", "b"], fresh: "g:a") == "g:a", "A new group uses its first member")
        memory.finish()
        // A page puts an earlier step in front of the same group.
        require(memory.id("group", members: ["z", "a", "b"], fresh: "g:z") == "g:a", "A group keeps its id")
        // A second group cannot take the id already given out.
        require(memory.id("group", members: ["b"], fresh: "g:b") == "g:b", "An id is given out once per fold")
        memory.finish()
        // Galleries and groups do not share member names.
        require(memory.id("gallery", members: ["a"], fresh: "a") == "a", "Gallery memory is separate")
        memory.reset()
        require(memory.id("group", members: ["z", "a"], fresh: "g:z") == "g:z", "Reset forgets the old conversation")

        // A gallery is named after its first image. One more image in front
        // of it keeps the name while the memory is in force.
        let gallery = ChatFoldContinuity()
        let first = ChatFoldContinuity.$current.withValue(gallery) { ChatImageGrouping.prepare([image("img2"), image("img3")]) }
        gallery.finish()
        require(first.count == 1 && first[0].id == "img2", "Consecutive images make one gallery")
        let paged = ChatFoldContinuity.$current.withValue(gallery) {
            ChatImageGrouping.prepare([image("img1"), image("img2"), image("img3")])
        }
        require(paged.count == 1 && paged[0].id == "img2", "A gallery keeps its id when an image arrives in front")
        require(ChatImageGrouping.prepare([image("img1"), image("img2")]).first?.id == "img1",
                "Without a memory the gallery is named as before")
    }
}
