// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

#if os(macOS)
import AppKit

enum SidebarContextClick {
    static func accepts(_ event: NSEvent?) -> Bool {
        guard let event else { return false }
        return event.type == .rightMouseDown
            || (event.type == .leftMouseDown && event.modifierFlags.contains(.control))
    }
}
#endif
