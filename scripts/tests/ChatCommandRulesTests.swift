// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
// Compile with ChatCommandRules.swift.
import Foundation
@main struct ChatCommandRulesTests {
    static func main() {
        typealias R = ChatCommandRules
        precondition(R.sendMethod(" /compact ") == "chat.compact")
        precondition(R.sendMethod("please /compact") == "chat.send")
        precondition(R.matches("/").count == 8)
        precondition(R.matches("/sta") == ["/status"])
        precondition(R.action("/sta", backend: "sh", running: true, attachments: false) == .complete("/status"))
        for backend in ["claude", "codex", "cursor", "muse", "opencode", "opencode2", "grok", "agy", "sh"] {
            for name in R.names where name != "/compact" && name != "/stop" {
                precondition(R.action(name, backend: backend, running: true, attachments: false) == .inspect)
            }
            let supported = backend == "claude" || backend == "codex"
            precondition(R.action("/compact", backend: backend, running: false, attachments: false) == (supported ? .compact : .refused(.unsupported)))
        }
        precondition(R.action("/compact", backend: "codex", running: true, attachments: false) == .refused(.running))
        precondition(R.action("/status\nhello", backend: "claude", running: false, attachments: false) == .refused(.arguments))
        precondition(R.action("/status", backend: "claude", running: false, attachments: true) == .refused(.attachments))
        precondition(R.action("/usr/local/file", backend: "sh", running: false, attachments: false) == .message)
        precondition(R.action("please /compact", backend: "codex", running: false, attachments: false) == .message)
        precondition(R.action("/", backend: "codex", running: false, attachments: false, selection: 999) == .complete("/stop"))
        precondition(R.action("/stop", backend: "sh", running: true, attachments: false) == .stop)
        print("Chat commands: backend capabilities, local actions, completion, attachment protection and literal paths passed")
    }
}
