// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
// Compile with ChatImageGrouping.swift ChatDisplayItem.swift ChatTranscriptFold.swift ChatQuestion.swift MuseToolPresentation.swift.
import Foundation
struct ChatAttachment: Hashable, Sendable {
    var id: String
    var name: String
    var mediaType: String?
    var size: UInt64? = 1
    var toolCallId: String? = nil
}
struct ChatApproval: Hashable, Sendable { var id: String; var decision: String? }

@main struct ChatImageGroupingTests {
    static func image(_ id: String, call: String? = nil, backend: String? = nil) -> ChatDisplayItem {
        .init(id: "attachment-\(id)", kind: .attachment(.init(id: id, name: "\(id).png", mediaType: "image/png", toolCallId: call)), sourceBackend: backend)
    }
    static func tool(_ id: String, call: String? = nil, backend: String? = nil) -> ChatDisplayItem {
        .init(id: id, kind: .tool(.init(callId: call ?? id, verb: "Read", target: "image.png", running: false,
            failed: false, startedAtMs: 1, snippet: [])), sourceBackend: backend)
    }
    static func main() {
        let raw: [ChatDisplayItem] = [
            .init(id: "user", kind: .user("Review the images")), tool("read"), image("a", call: "read"),
            tool("other"), image("b", call: "read"), .init(id: "usage", kind: .usage(input: 1, output: 1, cost: 0.1)),
            .init(id: "answer", kind: .assistant("Results", backend: "claude")), image("c"), image("d"),
            .init(id: "file", kind: .attachment(.init(id: "pdf", name: "report.pdf", mediaType: "application/pdf"))),
            image("e"), .init(id: "next", kind: .user("Next turn")), image("f", call: "read"),
        ]
        let prepared = ChatImageGrouping.prepare(raw)
        precondition(raw.count == 13 && raw.allSatisfy(\.imageAttachments.isEmpty), "Grouping cannot mutate cached/searchable source rows")
        precondition(prepared.first(where: { $0.id == "read" })?.imageAttachments.map(\.id) == ["a", "b"], "Only explicit tool provenance moves images onto their tool")
        precondition(prepared.first(where: { $0.id == "attachment-c" })?.imageAttachments.map(\.id) == ["c", "d"])
        precondition(prepared.contains(where: { $0.id == "attachment-e" }) && prepared.contains(where: { $0.id == "attachment-f" }),
                     "A non-image file or a new user turn bounds galleries and attribution")
        precondition(ChatImageGrouping.rowID(for: "attachment-d", in: prepared) == "attachment-c")
        precondition(ChatImageGrouping.rowID(for: "attachment-b", in: prepared) == "read")
        precondition(ChatImageGrouping.rowID(for: "missing", in: prepared) == "missing")
        for detail in ChatDetail.allCases {
            for open in [false, true] {
                let folded = ChatTranscriptFold.fold(prepared, detail: detail, running: false) { _ in open }
                let images = folded.flatMap(\.imageAttachments).map(\.id)
                precondition(images.sorted() == ["a", "b", "c", "d", "e", "f"], "Every image must appear once at every detail level, including collapsed groups")
                let destination = ChatImageGrouping.rowID(for: "attachment-b", in: folded)
                precondition(folded.contains(where: { $0.id == destination }), "An old attachment anchor must still resolve to a drawn row")
                if !open, detail != .detailed {
                    precondition(ChatTranscriptFold.owner(of: "attachment-b", in: folded) != nil,
                                 "Search/reveal must be able to open a group hiding the owning tool")
                }
            }
        }
        let noGuess = ChatImageGrouping.prepare([tool("read"), image("unknown"), image("missing", call: "absent")])
        precondition(noGuess[0].imageAttachments.isEmpty && noGuess.count == 3, "Proximity is never tool-image provenance")
        let repeated = ChatImageGrouping.prepare([tool("old", call: "same"), tool("new", call: "same"), image("output", call: "same")])
        precondition(repeated[0].imageAttachments.isEmpty && repeated[1].imageAttachments.map(\.id) == ["output"])
        let backends = ChatImageGrouping.prepare([tool("claude", call: "same", backend: "claude"),
            tool("codex", call: "same", backend: "codex"), image("claude-image", call: "same", backend: "claude"),
            image("unknown-image", call: "same", backend: "cursor"), image("ordinary-a", backend: "claude"), image("ordinary-b", backend: "codex")])
        precondition(backends[0].imageAttachments.map(\.id) == ["claude-image"] && backends[1].imageAttachments.isEmpty,
                     "A reused call id from another backend cannot take ownership of an image")
        precondition(backends.contains(where: { $0.id == "attachment-unknown-image" })
                     && backends.contains(where: { $0.id == "attachment-ordinary-a" })
                     && backends.contains(where: { $0.id == "attachment-ordinary-b" }), "Backend scope bounds standalone galleries too")
        print("Image galleries: grouping boundaries, exact tool provenance, bounded-turn matching, all folds and stable attachment anchors passed")
    }
}
