// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
// Compile with ChatEvents.swift.
import Foundation

struct ChatApproval: Codable, Sendable { let id: String }

@main struct ChatEventCounterTests {
    static func main() throws {
        func decode(_ number: String) throws -> ChatAgentEvent {
            try JSONDecoder().decode(ChatAgentEvent.self, from: Data("{\"kind\":\"usage\",\"input\":\(number)}".utf8))
        }
        let cases: [(String, UInt64?)] = [
            ("18446744073709551615", UInt64.max),
            ("18446744073709551616", nil), ("1e100", nil), ("-1", nil),
            ("12.75", 12), ("{\"command\":\"ls\"}", nil),
        ]
        for (source, expected) in cases {
            let event = try decode(source)
            assert(event.input == expected)
        }
        print("Chat counters: oversized values rejected without trapping, valid counters preserved")
    }
}
