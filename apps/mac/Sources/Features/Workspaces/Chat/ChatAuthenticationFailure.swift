// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import Foundation

/// Only normalized agent refusals qualify; a tool's GitHub login error does not.
enum ChatAuthenticationFailure {
    struct Recovery {
        let failureID: String
        let text: String
        let attachments: [ChatAttachment]
    }

    static func latestRecovery(in items: [ChatDisplayItem], backend: String) -> Recovery? {
        guard let start = items.lastIndex(where: { if case .user = $0.kind { return true }; return false }),
              case let .user(text) = items[start].kind,
              let failure = items[(start + 1)...].last(where: {
                  if case let .failed(text) = $0.kind { return needsSignIn(text, backend: backend) }; return false
              }) else { return nil }
        // User attachments immediately follow the prompt. Agent-returned files
        // later in the turn must never become input to a retry.
        var attachments: [ChatAttachment] = []
        for item in items[(start + 1)...] {
            guard case let .attachment(file) = item.kind else { break }
            attachments.append(file)
        }
        return Recovery(failureID: failure.id, text: text, attachments: attachments)
    }

    static func latestFailureID(in items: [ChatDisplayItem], backend: String) -> String? {
        latestRecovery(in: items, backend: backend)?.failureID
    }

    static func needsSignIn(_ text: String, backend: String) -> Bool {
        guard ["claude", "claude_code"].contains(backend) else { return false }
        let lower = text.lowercased()
        return lower.hasPrefix("claude code is not signed in")
            || lower.hasPrefix("claude code's sign-in on this computer has expired")
    }

    /// Hide duplicate CLI refusal prose and empty counters only in turns with
    /// a normalized auth failure. The persisted transcript remains intact.
    static func presented(_ items: [ChatDisplayItem]) -> [ChatDisplayItem] {
        var output: [ChatDisplayItem] = []
        var turn: [ChatDisplayItem] = []
        func flush() {
            let refused = turn.contains { if case let .failed(text) = $0.kind {
                return needsSignIn(text, backend: "claude")
            }; return false }
            output += turn.filter { item in
                guard refused else { return true }
                switch item.kind {
                case let .assistant(text, backend):
                    let refusal = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                    return !([nil, "claude", "claude_code"].contains(backend)
                        && ["not logged in · please run /login", "not logged in. please run /login", "not logged in · please run /login."].contains(refusal))
                case let .usage(input, output, cost): return input != 0 || output != 0 || (cost ?? 0) != 0
                default: return true
                }
            }
            turn = []
        }
        for item in items {
            if case .user = item.kind { flush() }
            turn.append(item)
        }
        flush()
        return output
    }
}
