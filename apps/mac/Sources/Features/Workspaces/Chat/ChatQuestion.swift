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
    /// A plan the agent wrote for the activity panel. The host reads it there,
    /// so the reply drops it the same way.
    static let planFence = "tokenstat-plan"
    // Match the host scanner. Rejected blocks must remain readable as text.
    private static let blockMaxBytes = 64 * 1024

    /// The reply without its question blocks. A block still streaming is cut
    /// from its opening line, so half a JSON object never flashes on screen.
    static func stripping(_ text: String, streaming: Bool = true) -> String {
        guard text.contains(fence) || text.contains(planFence) else { return text }
        var kept: [String] = []
        var inside = false
        var isPlan = false
        var block: [String] = []
        var bodyBytes = 0
        // Character splitting treats CRLF as one character, missing its LF.
        let lines = text.components(separatedBy: "\n")
        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            // The host reads the info string trimmed, so "``` tokenstat-question"
            // is a question there too and must not show as raw JSON here.
            let info = trimmed.hasPrefix("```") ? trimmed.dropFirst(3).trimmingCharacters(in: .whitespaces) : ""
            if !inside, info == fence || info == planFence {
                inside = true
                isPlan = info == planFence
                block = [line]
                bodyBytes = 0
                continue
            }
            if inside {
                block.append(line)
                if trimmed == "```" {
                    let body = block.dropFirst().dropLast().joined(separator: "\n")
                    let value = body.utf8.count < blockMaxBytes
                        ? try? JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any] : nil
                    let question = value?["question"] as? String
                    let valid = isPlan
                        ? value?["steps"] is [Any]
                        : question?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                    if !valid {
                        kept.append(contentsOf: block)
                    }
                    block = []
                    inside = false
                } else {
                    bodyBytes += line.utf8.count + (index < lines.count - 1 ? 1 : 0)
                    if bodyBytes > blockMaxBytes {
                        kept.append(contentsOf: block)
                        block = []
                        inside = false
                    }
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
