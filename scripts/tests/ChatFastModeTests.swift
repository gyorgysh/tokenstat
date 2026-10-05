// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
// Compile with ChatFastMode.swift.
import Foundation

@main
struct ChatFastModeTests {
    static func main() {
        // Old host catalog: no control, even on a model whose name is Opus.
        precondition(!ChatFastMode.available(model: "opus", models: nil))
        // Codex advertises provider-controlled availability, including Default.
        precondition(ChatFastMode.available(model: nil, models: []))
        let opus = ["opus", "claude-opus-5-5", "claude-opus-5", "claude-opus-4-8"]
        for name in ["opus", "opus[1m]", "claude-opus-5-5", "claude-opus-5-5[1m]", "claude-opus-4-8-20260525", "claude-opus-4-8-20260525[1m]"] {
            precondition(ChatFastMode.available(model: name, models: opus))
        }
        for name in [nil, "sonnet", "haiku", "claude-opus-4-7", "claude-opus-5-9", "claude-opus-5-9[1m]", "claude-opus-4-7-20260416[1m]", "opus[bogus]"] as [String?] {
            precondition(!ChatFastMode.available(model: name, models: opus))
        }
        print("Chat fast mode: old-host compatibility, Default, aliases, snapshots, and unsupported models passed.")
    }
}
