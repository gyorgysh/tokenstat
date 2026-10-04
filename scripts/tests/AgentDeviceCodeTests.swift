// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
// Compile with AgentDeviceCode.swift.
import Foundation

@main struct AgentDeviceCodeTests {
    static func main() {
        // The screen Codex draws for `codex login --device-auth`.
        let screen = """
        Welcome to Codex [v0.160.0]
        OpenAI's command-line coding agent

        Follow these steps to sign in with ChatGPT using device code authorization:

        1. Open this link in your browser and sign in to your account
           https://auth.openai.com/codex/device

        2. Enter this one-time code (expires in 15 minutes)
           DSJZ-RD351

        Continue only if you started this login in Codex. If a website or another person gave you this code, cancel.
        """
        let found = AgentDeviceCode.parse(screen)
        assert(found?.url.absoluteString == "https://auth.openai.com/codex/device")
        assert(found?.code == "DSJZ-RD351")

        // Still drawing: the link is there, the code is not yet.
        let partial = screen.components(separatedBy: "2. Enter")[0]
        assert(AgentDeviceCode.parse(partial) == nil, "A half-drawn screen must not produce a code")

        // A code before the link is not the one the page asks for.
        assert(AgentDeviceCode.parse("ABCD-12345\nhttps://example.invalid/device\n") == nil)

        // Only https links are opened.
        assert(AgentDeviceCode.parse("http://example.invalid/device\nABCD-12345") == nil)
        assert(AgentDeviceCode.parse("") == nil)
        print("AgentDeviceCodeTests passed")
    }
}
