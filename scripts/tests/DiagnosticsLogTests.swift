// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
// Compile with DiagnosticsLog.swift.
import AppKit

@main struct DiagnosticsLogTests {
    @MainActor static func main() {
        for role: NSAccessibility.Role in [.button, .popUpButton, .menuItem, .link, .textArea] {
            let element = NSAccessibilityElement()
            element.setAccessibilityRole(role)
            element.setAccessibilityLabel("Private chat title and note contents")
            assert(DiagnosticsLog.describe(element) == "role=\(role.rawValue)",
                   "Control labels must not be copied into diagnostic logs")
        }
        assert(DiagnosticsLog.describe(nil) == "role=none")
        let exception = NSException(name: .genericException,
                                    reason: "Private document contents", userInfo: nil)
        assert(DiagnosticsLog.exceptionSummary(exception) == "exception NSGenericException",
               "Exception reasons must not expose document contents")
        let host = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, host) }
        var before: mach_port_urefs_t = 0
        assert(mach_port_get_refs(mach_task_self_, host, mach_port_right_t(MACH_PORT_RIGHT_SEND), &before) == KERN_SUCCESS)
        for _ in 0..<100 { _ = DiagnosticsLog.systemMemory() }
        var after: mach_port_urefs_t = 0
        assert(mach_port_get_refs(mach_task_self_, host, mach_port_right_t(MACH_PORT_RIGHT_SEND), &after) == KERN_SUCCESS)
        assert(after == before, "Repeated memory sampling must release its Mach port rights")
        print("Diagnostic content privacy and Mach port lifetime checks passed")
    }
}
