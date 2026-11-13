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
                // Host closing_fence: ticks may share the line with the next
                // sentence (` ```Yes,...`), so trailing text stays as prose.
                // Probe the raw line (leading space/tab only) so a full trim
                // cannot eat spaces that belong to the glued sentence.
                if let trailing = Self.closingFenceTrailing(in: line) {
                    let body = block.dropFirst().joined(separator: "\n")
                    let value = body.utf8.count < blockMaxBytes
                        ? try? JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any] : nil
                    let question = value?["question"] as? String
                    let valid = isPlan
                        ? value?["steps"] is [Any]
                        : question?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                    // A model writing one block after another often glues the
                    // next opening fence to this closing one on a single line.
                    let next = trailing.trimmingCharacters(in: .whitespaces)
                    let nextInfo = next.hasPrefix("```") ? next.dropFirst(3).trimmingCharacters(in: .whitespaces) : ""
                    let opensNext = nextInfo == fence || nextInfo == planFence
                    if !valid {
                        kept.append(contentsOf: block)
                        kept.append(opensNext ? String(line.dropLast(trailing.count)) : line)
                    } else if !trailing.isEmpty, !opensNext {
                        kept.append(trailing)
                    }
                    block = []
                    inside = false
                    if opensNext {
                        inside = true
                        isPlan = nextInfo == planFence
                        block = [next]
                        bodyBytes = 0
                    }
                } else {
                    block.append(line)
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

    /// Prose after a closing run of backticks, or an empty string when the
    /// line is only the fence. `nil` when the line does not close a fence.
    private static func closingFenceTrailing(in line: String) -> String? {
        var index = line.startIndex
        while index < line.endIndex, line[index] == " " || line[index] == "\t" {
            index = line.index(after: index)
        }
        var ticks = 0
        var cursor = index
        while cursor < line.endIndex, line[cursor] == "`" {
            ticks += 1
            cursor = line.index(after: cursor)
        }
        guard ticks >= 3 else { return nil }
        // Host glued_opening: "``````tokenstat-plan" closes on three ticks
        // and opens the next block with the rest.
        let afterThree = line.index(index, offsetBy: 3)
        let afterRun = line[cursor...].drop { $0 == " " || $0 == "\t" }
        if ticks >= 6, afterRun.first?.isASCII == true, afterRun.first?.isLetter == true {
            var glued = line[afterThree...]
            if glued.last == "\r" { glued = glued.dropLast() }
            return String(glued)
        }
        var trailing = line[cursor...]
        if trailing.last == "\r" { trailing = trailing.dropLast() }
        while trailing.first == " " || trailing.first == "\t" {
            trailing = trailing.dropFirst()
        }
        return String(trailing)
    }
}
