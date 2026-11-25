// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
// Compile with HandleRules.swift.
import Foundation

@main struct HandleRulesTests {
    static func main() {
        for (typed, meant) in [
            ("Gyorgy", "gyorgy"), ("  @Gyorgy ", "gyorgy"), ("my name", "my-name"),
            ("https://tokenstat.ai/gyorgy?ref=1", "gyorgy"), ("tokenstat.ai/gyorgy/models", "gyorgy"),
            ("/gyorgy", "gyorgy"), ("   ", ""), (String(repeating: "a", count: 40), String(repeating: "a", count: 32)),
        ] { assert(HandleRules.normalized(typed) == meant, "\(typed) -> \(HandleRules.normalized(typed))") }

        for (handle, reason) in [
            ("abc", "too_short"), (String(repeating: "a", count: 33), "too_long"), ("na_me", "invalid_characters"),
            ("-name", "invalid_characters"), ("name-", "invalid_characters"), ("névjegy", "invalid_characters"),
            ("na--me", "double_dash"), ("123456", "numeric_only"),
        ] { assert(HandleRules.localReason(handle) == reason, handle) }
        for handle in ["gyorgy", "name", "na-me", "4you", String(repeating: "a", count: 32)] {
            assert(HandleRules.localReason(handle) == nil, handle)
        }

        // The one reason that carries a number keeps the server's sentence,
        // and so does a reason this app has never heard of.
        assert(HandleRules.message("cooloff", fallback: "In 3 days.") == "In 3 days.")
        assert(!HandleRules.message("new_reason").isEmpty)
        assert(HandleRules.address(host: "https://tokenstat.ai/", handle: "gyorgy") == "tokenstat.ai/gyorgy")
        assert(HandleRules.address(host: "http://localhost:8400", handle: "gyorgy") == "localhost:8400/gyorgy")
        print("Handle rules: typed names, local refusals, worded reasons and addresses")
    }
}
