// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import Foundation

/// Only the host's normalized agent-authentication refusals qualify. A shell
/// command failing to sign in to GitHub must not offer the agent's login.
enum ChatAuthenticationFailure {
    static func latestFailureID(in items: [ChatDisplayItem], backend: String) -> String? {
        for item in items.reversed() {
            if case .user = item.kind { break }
            if case let .failed(text) = item.kind, needsSignIn(text, backend: backend) {
                return item.id
            }
        }
        return nil
    }

    static func needsSignIn(_ text: String, backend: String) -> Bool {
        let lower = text.lowercased()
        switch backend {
        case "claude", "claude_code":
            return lower.hasPrefix("claude code is not signed in")
                || lower.hasPrefix("claude code's sign-in on this computer has expired")
        default:
            return false
        }
    }
}
