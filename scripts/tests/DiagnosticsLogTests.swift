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
        print("Diagnostic content privacy checks passed")
    }
}
