// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

import Foundation

/// A question the agent asked in its reply, and the person's answer once
/// there is one. The host finds the block and records it; see the host's
/// `chat_question` for the format and for how an answer reaches the agent.
struct ChatQuestion: Equatable, Sendable {
    let id: String
    let question: String
    let options: [String]
    let multiple: Bool
    /// What the agent goes with if nobody answers.
    let defaultAnswer: String?
    /// The agent stopped for this rather than carrying on with its default.
    let blocking: Bool
    var answer: String?
    /// `note` rode the running turn, `queued` waits for it to end, `sent`
    /// started a turn.
    var delivery: String?

    var isAnswered: Bool { answer != nil }
}

extension ChatDisplayItem {
    /// The question this row asks, so a row can tell whether its answer is
    /// still on the way.
    var questionID: String? {
        if case let .question(question) = kind { return question.id }
        return nil
    }
}

/// Answer from `chat.answerQuestion`.
struct ChatQuestionDelivery: Decodable, Sendable {
    let delivery: String
}

/// The question blocks inside reply text, which the card shows instead.
enum ChatQuestionText {
    static let fence = "tokenstat-question"
    // Match the host scanner. Rejected blocks must remain readable as text.
    private static let blockMaxBytes = 64 * 1024

    /// The reply without its question blocks. A block still streaming is cut
    /// from its opening line, so half a JSON object never flashes on screen.
    static func stripping(_ text: String, streaming: Bool = true) -> String {
        guard text.contains(fence) else { return text }
        var kept: [String] = []
        var inside = false
        var block: [String] = []
        // Character splitting treats CRLF as one character, missing its LF.
        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            // The host reads the info string trimmed, so "``` tokenstat-question"
            // is a question there too and must not show as raw JSON here.
            if !inside, trimmed.hasPrefix("```"),
               trimmed.dropFirst(3).trimmingCharacters(in: .whitespaces) == fence {
                inside = true
                block = [line]
                continue
            }
            if inside {
                block.append(line)
                if trimmed == "```" {
                    let body = block.dropFirst().dropLast().joined(separator: "\n")
                    let value = body.utf8.count < blockMaxBytes
                        ? try? JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any] : nil
                    let question = value?["question"] as? String
                    if question?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
                        kept.append(contentsOf: block)
                    }
                    block = []
                    inside = false
                }
                continue
            }
            kept.append(line)
        }
        if !streaming { kept.append(contentsOf: block) }
        return kept.joined(separator: "\n")
            .replacingOccurrences(of: "\n\n\n", with: "\n\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
