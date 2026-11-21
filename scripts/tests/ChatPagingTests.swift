// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
// Compile with ChatPaging.swift.
import Foundation

@main enum ChatPagingTests {
    static func main() {
        precondition(ChatPaging.openPageEvents == 1500)
        precondition(ChatPaging.pageEvents == 1200)
        precondition(ChatPaging.previewPageEvents == ChatPaging.openPageEvents)
        // The host clamps every request to its own ceiling, so a client page
        // above that would silently arrive short. The mirror below has to
        // move with PAGE_EVENTS_MAX in tokenstat-host/src/chat.rs.
        precondition(ChatPaging.hostPageEventsMax == 2000)
        precondition(ChatPaging.openPageEvents <= ChatPaging.hostPageEventsMax)
        precondition(ChatPaging.pageEvents <= ChatPaging.hostPageEventsMax)
        precondition(ChatPaging.pageEvents <= ChatPaging.openPageEvents)
        precondition(ChatPaging.hasEarlier(true, cursor: "opening"))
        precondition(ChatPaging.hasEarlier(true, cursor: "older", after: "opening"))
        precondition(!ChatPaging.hasEarlier(true, cursor: "opening", after: "opening"))
        precondition(!ChatPaging.hasEarlier(true, cursor: nil))
        precondition(!ChatPaging.hasEarlier(true, cursor: ""))
        precondition(!ChatPaging.hasEarlier(false, cursor: "older", after: "opening"))
        print("Chat paging: bounded page sizes, matching previews, and only advancing cursors")
    }
}
