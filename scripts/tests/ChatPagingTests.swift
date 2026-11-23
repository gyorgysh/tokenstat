// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
// Compile with ChatPaging.swift.
import Foundation

@main enum ChatPagingTests {
    static func main() {
        precondition(ChatPaging.openPageEvents == 3000)
        precondition(ChatPaging.pageEvents == 8000)
        precondition(ChatPaging.previewPageEvents == ChatPaging.openPageEvents)
        // The host has separate ceilings for opening and paging back.
        precondition(ChatPaging.hostPageEventsMax == 4000)
        precondition(ChatPaging.hostHistoryPageEventsMax == 8000)
        precondition(ChatPaging.openPageEvents <= ChatPaging.hostPageEventsMax)
        precondition(ChatPaging.pageEvents <= ChatPaging.hostHistoryPageEventsMax)
        precondition(ChatPaging.hasEarlier(true, cursor: "opening"))
        precondition(ChatPaging.hasEarlier(true, cursor: "older", after: "opening"))
        precondition(!ChatPaging.hasEarlier(true, cursor: "opening", after: "opening"))
        precondition(!ChatPaging.hasEarlier(true, cursor: nil))
        precondition(!ChatPaging.hasEarlier(true, cursor: ""))
        precondition(!ChatPaging.hasEarlier(false, cursor: "older", after: "opening"))
        print("Chat paging: bounded page sizes, matching previews, and only advancing cursors")
    }
}
