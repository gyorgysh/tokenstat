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
        let file = ChatDisplayItem(id: "input-file", kind: .attachment(ChatAttachment(id: "input")))
        let reply = ChatDisplayItem(id: "normal-reply", kind: .assistant("Your files are ready.", backend: "claude"))
        let returned = ChatDisplayItem(id: "output-file", kind: .attachment(ChatAttachment(id: "output")))
        let refusal = ChatDisplayItem(id: "raw-refusal", kind: .assistant("Not logged in · Please run /login", backend: "claude"))
        let zero = ChatDisplayItem(id: "empty-usage", kind: .usage(input: 0, output: 0, cost: nil))
        let turn = [prompt, file, reply, returned, refusal, refused, zero]
        let recovery = ChatAuthenticationFailure.latestRecovery(in: turn, backend: "claude")!
        precondition(recovery.text == "hello" && recovery.failureID == "refused")
        precondition(recovery.attachments.map(\.id) == ["input"], "Only original user files belong to the retry")
        precondition(ChatAuthenticationFailure.presented(turn).map(\.id) == ["prompt", "input-file", "normal-reply", "output-file", "refused"],
                     "Keep normal prose and files while removing contradictory instructions and zero counters")
        precondition(ChatAuthenticationFailure.presented([prompt, refusal, zero]).map(\.id) == ["prompt", "raw-refusal", "empty-usage"],
                     "Refusal-like text alone must not hide normal chat output")
        let usage = ChatDisplayItem(id: "real-usage", kind: .usage(input: 3, output: 0, cost: nil))
        precondition(ChatAuthenticationFailure.presented(turn + [usage]).last?.id == "real-usage")
        precondition(ChatAuthenticationFailure.latestRecovery(in: turn + [prompt], backend: "claude") == nil)
        precondition(ChatAuthenticationFailure.latestRecovery(in: [refused], backend: "claude") == nil,
                     "Without the original prompt a partial page must not offer a guessed retry")
        print("ChatAuthenticationFailureTests passed")
    }
}
