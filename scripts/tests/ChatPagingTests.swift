// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
// Compile with ChatPaging.swift.
import Foundation

@main enum ChatPagingTests {
    static func main() {
        precondition(ChatPaging.openPageEvents == 1500)
        precondition(ChatPaging.pageEvents == 1200)
        precondition(ChatPaging.previewPageEvents == 500)
        // The host clamps every request to its own ceiling, so a client page
        // above that would silently arrive short. The mirror below has to
        // move with PAGE_EVENTS_MAX in tokenstat-host/src/chat.rs.
        precondition(ChatPaging.hostPageEventsMax == 2000)
        precondition(ChatPaging.openPageEvents <= ChatPaging.hostPageEventsMax)
        precondition(ChatPaging.pageEvents <= ChatPaging.hostPageEventsMax)
        // Previews keep only the newest tail, so they stay small while the
        // transcript pages grow.
        precondition(ChatPaging.previewPageEvents < ChatPaging.pageEvents)
        precondition(ChatPaging.pageEvents <= ChatPaging.openPageEvents)
        print("Chat paging: tripled transcript pages under the host ceiling, previews stay small")
    }
}
