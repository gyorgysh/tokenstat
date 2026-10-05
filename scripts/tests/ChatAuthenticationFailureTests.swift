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
        let cursorRaw = "Error: Authentication required. Please run 'agent login' first, or set CURSOR_API_KEY environment variable."
        let cursorNormalized = "Cursor is not signed in on this machine. Open a terminal and run cursor-agent login."
        for backend in ["cursor", "cursor_agent"] {
            precondition(ChatAuthenticationFailure.needsSignIn(cursorRaw, backend: backend),
                         "Existing Cursor failures must offer recovery after upgrading")
            precondition(ChatAuthenticationFailure.needsSignIn(cursorNormalized, backend: backend))
            precondition(ChatAuthenticationFailure.needsSignIn(
                "Error: Authentication required. Run 'cursor-agent login', pass --api-key/--auth-token, or set CURSOR_API_KEY/CURSOR_AUTH_TOKEN.", backend: backend))
            precondition(ChatAuthenticationFailure.needsSignIn(
                "  Authentication required. Please run 'cursor agent login' first, or set CURSOR_API_KEY environment variable.\n", backend: backend))
            for unrelated in [
                "GitHub is not signed in. Run gh auth login.",
                "Error: Authentication required. Please run 'gh auth login' first.",
                "Error: Authentication required. Run 'agent login' first.",
                "Error: Authentication required. Set CURSOR_API_KEY environment variable.",
                "The command output mentions \(cursorRaw)",
                "Claude Code is not signed in on this computer.",
            ] {
                precondition(!ChatAuthenticationFailure.needsSignIn(unrelated, backend: backend),
                             "Only Cursor's own login refusal qualifies: \(unrelated)")
            }
        }
        for backend in ["claude", "codex", "muse", "cursor "] {
            precondition(!ChatAuthenticationFailure.needsSignIn(cursorRaw, backend: backend))
            precondition(!ChatAuthenticationFailure.needsSignIn(cursorNormalized, backend: backend))
        }
        let museNormalized = "Muse is not signed in on this machine. Open a terminal and run muse login."
        precondition(ChatAuthenticationFailure.needsSignIn(museNormalized, backend: "muse"))
        for backend in ["claude", "codex", "cursor"] {
            precondition(!ChatAuthenticationFailure.needsSignIn(museNormalized, backend: backend))
        }
        precondition(!ChatAuthenticationFailure.needsSignIn("Run muse login to use the CLI.", backend: "muse"))
        precondition(!ChatAuthenticationFailure.needsSignIn("The tool output says \(museNormalized)", backend: "muse"))
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
        let cursorFailed = ChatDisplayItem(id: "cursor-failed", kind: .failed(cursorRaw))
        let cursorRecovery = ChatAuthenticationFailure.latestRecovery(in: [prompt, file, cursorFailed], backend: "cursor")!
        precondition(cursorRecovery.failureID == "cursor-failed" && cursorRecovery.text == "hello")
        precondition(cursorRecovery.attachments.map(\.id) == ["input"])
        precondition(ChatAuthenticationFailure.latestRecovery(in: [prompt, file, cursorFailed], backend: "claude") == nil)
        precondition(ChatAuthenticationFailure.latestRecovery(in: [cursorFailed], backend: "cursor") == nil)
        let cursorReply = ChatDisplayItem(id: "cursor-reply", kind: .assistant(cursorRaw, backend: "cursor"))
        precondition(ChatAuthenticationFailure.latestRecovery(in: [prompt, cursorReply], backend: "cursor") == nil,
                     "Quoted CLI text in assistant prose is not a failed turn")
        let tool = ChatDisplayItem(id: "tool-login-error", kind: .tool(ChatToolState(
            callId: "call", verb: "Shell", target: "agent login", running: false, failed: true,
            detail: cursorRaw, startedAtMs: 0, endedAtMs: 1, snippet: [cursorRaw])))
        precondition(ChatAuthenticationFailure.latestRecovery(in: [prompt, tool], backend: "cursor") == nil,
                     "A nested tool's login error must not retry the whole prompt")
        precondition(ChatAuthenticationFailure.latestRecovery(in: [prompt, cursorFailed, prompt, reply], backend: "cursor") == nil,
                     "A successful later turn retires the previous Cursor recovery")
        let unrelatedFailure = ChatDisplayItem(id: "other-failure", kind: .failed("Network disconnected."))
        precondition(ChatAuthenticationFailure.latestRecovery(in: [prompt, cursorFailed, prompt, unrelatedFailure], backend: "cursor") == nil,
                     "A newer failed turn must not revive an earlier Cursor login refusal")
        let museFailed = ChatDisplayItem(id: "muse-failed", kind: .failed(museNormalized))
        let museRecovery = ChatAuthenticationFailure.latestRecovery(in: [prompt, file, museFailed], backend: "muse")!
        precondition(museRecovery.text == "hello" && museRecovery.attachments.map(\.id) == ["input"])
        precondition(ChatAuthenticationFailure.latestRecovery(in: [prompt, museFailed, prompt, reply], backend: "muse") == nil)
        let museChallenge = "Open this page to sign in:\nhttps://auth.meta.com/device?user_code=TEST-CODE\nconfirm this code matches:\nTEST-CODE\n\nPress Enter to open it in your browser:"
        let museLauncherChallenge = museChallenge.replacingOccurrences(of: "confirm this code matches:", with: "Confirm this code matches:")
        for text in [museChallenge, museChallenge.replacingOccurrences(of: "\n", with: ""),
                     museLauncherChallenge, museLauncherChallenge.replacingOccurrences(of: "\n", with: "")] {
            let legacy = ChatDisplayItem(id: "muse-legacy", kind: .assistant(text, backend: "muse"), lastSequence: 12)
            let presented = ChatAuthenticationFailure.presented([prompt, file, legacy])
            precondition(presented.last?.kind == .failed(museNormalized),
                         "Old Muse startup challenges must not expose device URLs or codes")
            precondition(presented.last?.id == legacy.id && presented.last?.lastSequence == 12)
            let recovery = ChatAuthenticationFailure.latestRecovery(in: [prompt, file, legacy], backend: "muse")!
            precondition(recovery.failureID == legacy.id && recovery.text == "hello" && recovery.attachments.map(\.id) == ["input"])
            precondition(ChatAuthenticationFailure.latestRecovery(in: [prompt, legacy], backend: "cursor") == nil)
            precondition(ChatAuthenticationFailure.latestRecovery(in: [prompt, legacy, prompt, reply], backend: "muse") == nil)
        }
        for unrelated in [
            ChatDisplayItem(id: "other-backend", kind: .assistant(museChallenge, backend: "claude")),
            ChatDisplayItem(id: "quoted-challenge", kind: .assistant("For example:\n" + museChallenge, backend: "muse")),
            ChatDisplayItem(id: "wrong-host", kind: .assistant(museChallenge.replacingOccurrences(of: "auth.meta.com/", with: "auth.meta.com.example.invalid/"), backend: "muse")),
            ChatDisplayItem(id: "incomplete-challenge", kind: .assistant("Open this page to sign in:\nhttps://auth.meta.com/device", backend: "muse")),
            ChatDisplayItem(id: "tool-challenge", kind: .tool(ChatToolState(
                callId: "muse-tool", verb: "Shell", target: "muse login", running: false, failed: true,
                detail: museChallenge, startedAtMs: 0, endedAtMs: 1, snippet: [museChallenge]))),
        ] {
            precondition(ChatAuthenticationFailure.presented([prompt, unrelated]).last == unrelated)
            precondition(ChatAuthenticationFailure.latestRecovery(in: [prompt, unrelated], backend: "muse") == nil)
        }
        print("ChatAuthenticationFailureTests passed")
    }
}
