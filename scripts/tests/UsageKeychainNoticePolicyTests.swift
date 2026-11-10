// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
// Compile with UsageKeychainNoticePolicy.swift.
import Foundation
@main struct UsageKeychainNoticePolicyTests {
    static func main() {
        var policy = UsageKeychainNoticePolicy(saved: "")
        precondition(policy.offer(affected: ["codex"]) == nil)
        precondition(policy.offer(affected: ["claude_code", "muse"]) == "claude_code")
        policy.dismiss(affected: ["claude_code", "muse", "codex"])
        let reopened = UsageKeychainNoticePolicy(saved: policy.saved)
        precondition(reopened.offer(affected: ["claude_code", "muse"]) == nil,
                     "Later, cancellation and refresh must not produce another notice")
        precondition(!reopened.dismissed.contains("codex"))
        let partial = UsageKeychainNoticePolicy(saved: "claude_code")
        precondition(partial.offer(affected: ["claude_code", "muse"]) == "muse")
        precondition(partial.offer(affected: ["cursor"]) == "cursor")
        policy.dismiss(affected: ["cursor"])
        precondition(UsageKeychainNoticePolicy(saved: policy.saved).offer(affected: ["cursor"]) == nil)
        precondition(partial.offer(affected: []) == nil)
        print("Keychain notice: provider scope, persisted dismissal and later providers passed")
    }
}
