// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import Foundation

enum ChatAuthenticationFailure {
    struct Recovery {
        let failureID: String
        let text: String
        let attachments: [ChatAttachment]
    }

    static func latestRecovery(in items: [ChatDisplayItem], backend: String) -> Recovery? {
        guard let start = items.lastIndex(where: { if case .user = $0.kind { return true }; return false }) else { return nil }
        let turn = presented(Array(items[start...]))
        guard case let .user(text) = turn[0].kind,
              let failure = turn.dropFirst().last(where: {
                  if case let .failed(text) = $0.kind { return needsSignIn(text, backend: backend) }; return false
              }) else { return nil }
        var attachments: [ChatAttachment] = []
        for item in turn.dropFirst() {
            guard case let .attachment(file) = item.kind else { break }
            attachments.append(file)
        }
        return Recovery(failureID: failure.id, text: text, attachments: attachments)
    }

    static func latestFailureID(in items: [ChatDisplayItem], backend: String) -> String? {
        latestRecovery(in: items, backend: backend)?.failureID
    }

    static func needsSignIn(_ text: String, backend: String) -> Bool {
        switch backend {
        case "claude", "claude_code": return isClaudeSignInRefusal(text)
        case "cursor", "cursor_agent": return isCursorSignInRefusal(text)
        case "muse": return text.lowercased().hasPrefix("muse is not signed in on this machine.")
        default: return false
        }
    }

    static func isClaudeSignInRefusal(_ text: String) -> Bool {
        let lower = text.lowercased()
        return lower.hasPrefix("claude code is not signed in")
            || lower.hasPrefix("claude code's sign-in on this computer has expired")
    }

    private static func isCursorSignInRefusal(_ text: String) -> Bool {
        var lower = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if lower.hasPrefix("cursor is not signed in on this machine.") { return true }
        if lower.hasPrefix("error:") {
            lower = String(lower.dropFirst("error:".count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return lower.hasPrefix("authentication required.")
            && lower.contains("cursor_api_key")
            && ["'agent login'", "'cursor-agent login'", "'cursor agent login'"].contains(where: lower.contains)
    }

    private static let museSignInRefusal = "Muse is not signed in on this machine. Open a terminal and run muse login."

    private static func isLegacyMuseChallenge(_ text: String, backend: String?) -> Bool {
        guard backend == "muse" else { return false }
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let heading = "Open this page to sign in:"
        let confirmations = ["confirm this code matches:", "Confirm this code matches:"]
        guard text.hasPrefix(heading),
              text.hasSuffix("Press Enter to open it in your browser:"),
              let confirm = confirmations.compactMap({ text.range(of: $0) }).first else { return false }
        let urlText = text[text.index(text.startIndex, offsetBy: heading.count)..<confirm.lowerBound]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URLComponents(string: urlText) else { return false }
        return url.scheme == "https" && url.host == "auth.meta.com"
    }

    static func presented(_ items: [ChatDisplayItem]) -> [ChatDisplayItem] {
        var output: [ChatDisplayItem] = []
        var turn: [ChatDisplayItem] = []
        func flush() {
            turn = turn.map { item in
                guard case let .assistant(text, backend) = item.kind,
                      isLegacyMuseChallenge(text, backend: backend) else { return item }
                return ChatDisplayItem(id: item.id, kind: .failed(museSignInRefusal),
                                       lastSequence: item.lastSequence, groupID: item.groupID,
                                       plainStep: item.plainStep)
            }
            let refused = turn.contains { if case let .failed(text) = $0.kind {
                return isClaudeSignInRefusal(text)
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
