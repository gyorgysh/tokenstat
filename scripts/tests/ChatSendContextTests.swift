// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
// Compile with ChatSendContext.swift.
import Foundation

@main struct ChatSendContextTests {
    static func main() {
        assert(ChatSendContext.afterOwnEdit(7, previous: 7, updated: 8) == 8)
        assert(ChatSendContext.afterOwnEdit(6, previous: 7, updated: 8) == 6)
        assert(ChatSendContext.afterOwnEdit(7, previous: 7, updated: 9) == 7)
        assert(ChatSendContext.afterOwnEdit(8, previous: 7, updated: 8) == 8)
        assert(ChatSendContext.afterOwnEdit(nil, previous: 7, updated: 8) == nil)
        assert(ChatSendContext.afterOwnEdit(7, previous: 7, updated: nil) == 7)
        assert(ChatSendContext.afterOwnEdit(UInt64.max, previous: UInt64.max, updated: 0) == UInt64.max)
        print("Send context: own acknowledged setup edits advance; unrelated work still requires review")
    }
}
