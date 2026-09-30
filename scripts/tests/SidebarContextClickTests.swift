// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
// Compile with SidebarContextClick.swift.
import AppKit

@main enum SidebarContextClickTests {
    static func main() {
        func event(_ type: NSEvent.EventType, flags: NSEvent.ModifierFlags = []) -> NSEvent? {
            NSEvent.mouseEvent(with: type, location: .zero, modifierFlags: flags,
                timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 0)
        }
        precondition(SidebarContextClick.accepts(event(.rightMouseDown)))
        precondition(SidebarContextClick.accepts(event(.leftMouseDown, flags: .control)))
        precondition(SidebarContextClick.accepts(event(.leftMouseDown, flags: [.control, .shift])))
        precondition(!SidebarContextClick.accepts(event(.leftMouseDown)))
        precondition(!SidebarContextClick.accepts(event(.leftMouseDown, flags: .shift)))
        precondition(!SidebarContextClick.accepts(event(.mouseMoved, flags: .control)))
        precondition(!SidebarContextClick.accepts(nil))
        print("Sidebar context click: secondary click and Control-click preserve ordinary row selection")
    }
}
