// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import Foundation

/// Older Muse archives keep tool inputs in the result detail instead of the
/// start event. Recover only those documented metadata fields for compact rows.
enum MuseToolPresentation {
    struct Value: Equatable {
        var verb: String
        var target: String
    }

    private static let maximumDetailBytes = 128 * 1024

    static func completed(backend: String?, verb: String, target: String, detail: String?) -> Value {
        guard backend == "muse" else { return Value(verb: verb, target: target) }
        let canonical: String
        switch verb.lowercased() {
        case "bash input", "bash_input": canonical = "Bash"
        case "read skill", "read_skill": canonical = "Read"
        case "write todos", "write_todos": canonical = "TodoWrite"
        default: canonical = verb
        }
        // A start event's real input is authoritative, including whitespace.
        guard target.isEmpty, let detail else { return Value(verb: canonical, target: target) }

        let bytes = Array(detail.utf8.prefix(maximumDetailBytes + 1))
        let bounded = String(decoding: bytes.prefix(maximumDetailBytes), as: UTF8.self)
        let lines = bounded.split(separator: "\n", maxSplits: 2, omittingEmptySubsequences: false)
        let first = String(lines.first ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let object: [String: Any]?
        if bytes.count <= maximumDetailBytes, first.hasPrefix("{") {
            object = (try? JSONSerialization.jsonObject(with: Data(bytes))) as? [String: Any]
        } else {
            object = nil
        }

        let recovered: String?
        switch canonical {
        case "Bash", "Shell":
            if let command = object?["command"] as? String, !command.isEmpty {
                recovered = command
            } else if first.hasPrefix("$ ") {
                recovered = String(first.dropFirst(2))
            } else if lines.count > 1, lines[1].hasPrefix("$ ") {
                // The normalized shell result has one description line before
                // its command. Never scan output for something resembling one.
                recovered = String(lines[1].dropFirst(2))
            } else {
                recovered = nil
            }
        case "Read":
            if let path = object?["path"] as? String {
                recovered = path
            } else if first.hasPrefix("Read text file `"), first.hasSuffix("`.") {
                recovered = String(first.dropFirst("Read text file `".count).dropLast(2))
            } else {
                recovered = capture(#"^<read-skill-result\s+name="([^"]+)"(?:\s|>)"#, in: first)
                    .map(xmlAttribute)
            }
        case "Write":
            recovered = object?["path"] as? String
                ?? capture(#"^wrote [0-9]+ bytes to (.+)$"#, in: first)
        case "WebSearch":
            recovered = object?["query"] as? String
        case "WebFetch":
            recovered = object?["url"] as? String
        case "TodoWrite":
            recovered = capture(#"^([0-9]+ todos \(revision [0-9]+\))$"#, in: first)
        default:
            recovered = nil
        }
        return Value(verb: canonical, target: recovered ?? target)
    }

    private static func capture(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }

    private static func xmlAttribute(_ text: String) -> String {
        text.replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&amp;", with: "&")
    }
}
