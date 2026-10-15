// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import Foundation

enum ChatCommandRules {
    static let names = ["/compact", "/status", "/context", "/usage", "/mcp", "/tools", "/help", "/stop"]
    static func sendMethod(_ text: String) -> String { text.trimmingCharacters(in: .whitespacesAndNewlines) == "/compact" ? "chat.compact" : "chat.send" }
    /// Match the native endpoint's payload limits before offering Steer.
    /// Rust counts Unicode scalar values rather than Swift grapheme clusters.
    static func canSteer(_ text: String, attachments: Bool, acceptsAttachments: Bool) -> Bool {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return (!text.isEmpty || attachments) && (!attachments || acceptsAttachments)
            && !text.hasPrefix("/") && text.unicodeScalars.count <= 1_500
    }
    enum Refusal: Equatable { case attachments, arguments, unsupported, running }
    enum Action: Equatable { case message, complete(String), inspect, stop, compact, refused(Refusal) }
    static func matches(_ draft: String) -> [String] {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.hasPrefix("/"), !text.contains(where: \.isWhitespace) else { return [] }
        return names.filter { $0.hasPrefix(text) }
    }
    static func action(_ draft: String, backend: String?, running: Bool, attachments: Bool, selection: Int = 0) -> Action {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let word = text.split(whereSeparator: \.isWhitespace).first else { return .message }
        guard names.contains(String(word)) else {
            let candidates = matches(text)
            return candidates.isEmpty ? .message : .complete(candidates[min(max(selection, 0), candidates.count - 1)])
        }
        if attachments { return .refused(.attachments) }
        if text != word { return .refused(.arguments) }
        if word == "/compact" {
            guard backend == "claude" || backend == "codex" else { return .refused(.unsupported) }
            return running ? .refused(.running) : .compact
        }
        return word == "/stop" ? .stop : .inspect
    }
}
