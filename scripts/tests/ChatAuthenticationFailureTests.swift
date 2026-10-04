// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
// Compile with ChatAuthenticationFailure.swift, ChatDisplayItem.swift,
// ChatTranscriptFold.swift, ChatQuestion.swift and L10n.swift using swiftc.
import Foundation

struct ChatAttachment: Hashable { var id: String }
struct ChatApproval: Hashable { var id: String; var decision: String? }

@main
struct ChatAuthenticationFailureTests {
    static func main() {
        precondition(ChatAuthenticationFailure.needsSignIn(
            "Claude Code is not signed in on this computer. Open a terminal, run claude, and use /login.", backend: "claude"))
        precondition(ChatAuthenticationFailure.needsSignIn(
            "Claude Code's sign-in on this computer has expired. Open a terminal, run claude, and use /login.", backend: "claude_code"))
        precondition(!ChatAuthenticationFailure.needsSignIn(
            "GitHub is not signed in. Run gh auth login.", backend: "claude"))
        precondition(!ChatAuthenticationFailure.needsSignIn(
            "The command output mentions Claude Code is not signed in", backend: "claude"))
        precondition(!ChatAuthenticationFailure.needsSignIn(
            "Claude Code is not signed in on this computer.", backend: "codex"))
        let refused = ChatDisplayItem(id: "refused", kind: .failed("Claude Code is not signed in on this computer."))
        let prompt = ChatDisplayItem(id: "prompt", kind: .user("hello"))
        precondition(ChatAuthenticationFailure.latestFailureID(in: [prompt, refused], backend: "claude") == "refused")
        precondition(ChatAuthenticationFailure.latestFailureID(in: [refused, prompt], backend: "claude") == nil,
                     "A new turn must not inherit an earlier turn's login failure")
        precondition(ChatAuthenticationFailure.latestFailureID(in: [prompt, refused], backend: "codex") == nil,
                     "Another agent's failure must not start this agent's login")
        print("ChatAuthenticationFailureTests passed")
    }
}
