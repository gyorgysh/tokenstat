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
        print("Chat controls swipe intent tests passed")
    }
}
