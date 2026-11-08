// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
// Compile with ClientChatControlsSwipe.swift using swiftc -parse-as-library, then run.
import Foundation

@main
struct ChatControlsSwipeTests {
    static func main() {
        let hide = ChatControlsSwipeIntent(upward: true)
        precondition(hide.acceptsStart(CGPoint(x: 0, y: 0), direction: CGPoint(x: 0, y: -100)))
        precondition(!hide.acceptsStart(CGPoint(x: 0, y: 0), direction: CGPoint(x: 100, y: -20)))
        precondition(!hide.completes(CGPoint(x: 0, y: -28)))
        precondition(hide.completes(CGPoint(x: 0, y: -29)))
        precondition(!hide.completes(CGPoint(x: 80, y: -40)))
        precondition(!hide.completes(CGPoint(x: 0, y: 80)))
        let restore = ChatControlsSwipeIntent(upward: false, maximumStartY: 56)
        precondition(restore.acceptsStart(CGPoint(x: 200, y: 56), direction: CGPoint(x: 5, y: 80)))
        precondition(!restore.acceptsStart(CGPoint(x: 200, y: 57), direction: CGPoint(x: 0, y: 80)))
        precondition(!restore.acceptsStart(CGPoint(x: 200, y: -1), direction: CGPoint(x: 0, y: 80)))
        precondition(!restore.acceptsStart(CGPoint(x: 200, y: 10), direction: CGPoint(x: 80, y: 5)))
        precondition(!restore.acceptsStart(CGPoint(x: 200, y: 10), direction: CGPoint(x: 0, y: -80)))
        precondition(restore.completes(CGPoint(x: 5, y: 200)), "A top-edge swipe can finish below the start region")
        let back = ChatBackSwipeIntent()
        let still = CGPoint(x: 0, y: 0)
        precondition(back.accepts(CGPoint(x: 100, y: 10)))
        precondition(!back.accepts(CGPoint(x: -100, y: 10)))
        precondition(!back.accepts(CGPoint(x: 10, y: 100)))
        precondition(back.completes(CGPoint(x: 100, y: 10), velocity: still))
        precondition(!back.completes(CGPoint(x: 100, y: 10), velocity: CGPoint(x: -300, y: 0)), "Reversing toward the edge cancels navigation")
        precondition(back.completes(CGPoint(x: 100, y: 10), velocity: CGPoint(x: -20, y: 0)), "Finger-lift noise must not cancel a completed swipe")
        precondition(!back.completes(CGPoint(x: 20, y: 0), velocity: CGPoint(x: 1000, y: 0)), "A tiny edge drag must not leave the chat")
        precondition(!back.completes(CGPoint(x: 40, y: 0), velocity: still))
        precondition(back.completes(CGPoint(x: 40, y: 0), velocity: CGPoint(x: 600, y: 0)))
        precondition(!back.completes(CGPoint(x: 100, y: 120), velocity: still))
        let rtlBack = ChatBackSwipeIntent(rightToLeft: true)
        precondition(rtlBack.accepts(CGPoint(x: -100, y: 10)))
        precondition(!rtlBack.accepts(CGPoint(x: 100, y: 10)))
        precondition(rtlBack.completes(CGPoint(x: -100, y: 10), velocity: still))
        precondition(!rtlBack.completes(CGPoint(x: -100, y: 10), velocity: CGPoint(x: 300, y: 0)), "RTL back swipes support reversal too")
        precondition(rtlBack.completes(CGPoint(x: -40, y: 0), velocity: CGPoint(x: -600, y: 0)))
        print("Chat controls swipe intent tests passed")
    }
}
