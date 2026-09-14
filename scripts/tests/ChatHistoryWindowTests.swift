// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
// Compile with ChatHistoryWindow.swift.
import Foundation

@main
struct ChatHistoryWindowTests {
    static func require(_ condition: Bool, _ message: String) {
        precondition(condition, message)
    }

    static func main() {
        // Empty draws nothing, expanded or not.
        require(ChatHistoryWindow.visible(count: 0, selected: nil, expanded: false) == 0..<0, "empty collapsed")
        require(ChatHistoryWindow.visible(count: 0, selected: nil, expanded: true) == 0..<0, "empty expanded")

        // Five by default, ten when expanded.
        require(ChatHistoryWindow.visible(count: 30, selected: nil, expanded: false) == 0..<5, "collapsed five")
        require(ChatHistoryWindow.visible(count: 30, selected: nil, expanded: true) == 0..<10, "expanded ten")
        require(ChatHistoryWindow.visible(count: 3, selected: nil, expanded: false) == 0..<3, "short list intact")

        // A selection in the first five changes nothing.
        require(ChatHistoryWindow.visible(count: 30, selected: 2, expanded: false) == 0..<5, "shallow selection")

        // A selection past the collapsed few opens the warm ten around it,
        // so the lit row is always drawn.
        require(ChatHistoryWindow.visible(count: 30, selected: 7, expanded: false) == 0..<10, "deep selection opens ten")
        require(ChatHistoryWindow.visible(count: 30, selected: 25, expanded: false) == 20..<30, "far selection windows")
        require(ChatHistoryWindow.visible(count: 30, selected: 29, expanded: false) == 20..<30, "last row clamps")

        // A stale index is not a selection.
        require(ChatHistoryWindow.visible(count: 30, selected: 99, expanded: false) == 0..<5, "stale selection")

        // Looping stays inside the warm ten, never walks the archive.
        require(ChatHistoryWindow.looped(count: 30, current: 9, step: 1) == 0, "wraps to first")
        require(ChatHistoryWindow.looped(count: 30, current: 0, step: -1) == 9, "wraps to tenth")
        require(ChatHistoryWindow.looped(count: 30, current: 4, step: 1) == 5, "steps forward")
        require(ChatHistoryWindow.looped(count: 30, current: 25, step: 1) == 0, "outside re-enters forward")
        require(ChatHistoryWindow.looped(count: 30, current: 25, step: -1) == 9, "outside re-enters backward")
        require(ChatHistoryWindow.looped(count: 4, current: 3, step: 1) == 0, "short list wraps whole")
        require(ChatHistoryWindow.looped(count: 1, current: 0, step: 1) == 0, "single loops to itself")
        require(ChatHistoryWindow.looped(count: 10, current: nil, step: 1) == 0, "no selection starts newest")
        require(ChatHistoryWindow.looped(count: 10, current: nil, step: -1) == 9, "no selection starts oldest")
        require(ChatHistoryWindow.looped(count: 0, current: nil, step: 1) == nil, "empty has nowhere to land")
        require(ChatHistoryWindow.looped(count: 10, current: 4, step: 0) == nil, "only unit steps")
    }
}
