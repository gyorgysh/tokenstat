// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
// Compile with ChatQuestion.swift ChatDisplayItem.swift ChatTranscriptFold.swift using swiftc -parse-as-library, then run.
import Foundation

// Two models from Bridge/Models.swift, cut to what a row needs.
struct ChatAttachment: Hashable { var id: String }
struct ChatApproval: Hashable { var id: String }

@main
struct ChatQuestionTests {
    static func require(_ condition: Bool, _ message: String) {
        precondition(condition, message)
    }

    static func main() {
        let fence = "```tokenstat-question"
        let block = "\(fence)\n{\"question\":\"Which database?\",\"options\":[\"A\",\"B\"]}\n```"

        require(ChatQuestionText.stripping("Plain reply.") == "Plain reply.", "text without a block is untouched")
        require(ChatQuestionText.stripping("Before:\n\(block)\nGoing with A.") == "Before:\nGoing with A.",
                "a finished block leaves the prose on either side")
        require(ChatQuestionText.stripping("Before:\n\(fence)\n{\"question\":\"Wh") == "Before:",
                "a block still streaming is cut from its opening line")
        require(ChatQuestionText.stripping("\(block)") == "", "a reply that is only a question has no prose")
        require(ChatQuestionText.stripping(block.replacingOccurrences(of: "\n", with: "\r\n")) == "",
                "CRLF fences match the host scanner")
        for padding in [String(repeating: "x", count: 64 * 1024), String(repeating: "é", count: 32 * 1024)] {
            let oversized = "\(fence)\n{\"question\":\"Q\",\"extra\":\"\(padding)\"}\n```"
            require(ChatQuestionText.stripping(oversized) == oversized, "host-rejected blocks stay readable, bounded by UTF-8 bytes")
        }
        let prefix = #"{"question":"Q","extra":""#
        let suffix = #""}"#
        for extra in [0, 1] {
            let body = prefix + String(repeating: "x", count: 64 * 1024 - 1 - prefix.utf8.count - suffix.utf8.count + extra) + suffix
            let edge = "\(fence)\n\(body)\n```"
            require(ChatQuestionText.stripping(edge) == (extra == 0 ? "" : edge), "the body limit includes its closing newline")
        }
        require(ChatQuestionText.stripping("Run:\n```sh\nls\n```") == "Run:\n```sh\nls\n```",
                "ordinary code blocks stay")
        require(ChatQuestionText.stripping("  \(fence)\n{\"question\":\"Pick?\"}\n  ```\nafter") == "after", "indented fences count")
        for body in ["{}", "broken JSON", "{\"question\":42}", "{\"question\":\" \"}"] {
            let invalid = "\(fence)\n\(body)\n```"
            require(ChatQuestionText.stripping(invalid) == invalid, "a malformed question stays readable")
        }
        let unfinished = "\(fence)\n{\"question\":\"Wh"
        require(ChatQuestionText.stripping(unfinished, streaming: false) == unfinished, "an interrupted reply stays readable")

        let question = ChatQuestion(id: "q1", question: "Q", options: [], multiple: false,
                                    defaultAnswer: nil, blocking: true)
        require(!question.isAnswered, "a new question is open")
        let row = ChatDisplayItem(id: "question-q1", kind: .question(question))
        require(row.questionID == "q1", "a question row names its question")
        require(ChatDisplayItem(id: "u", kind: .user("hi")).questionID == nil, "other rows name none")
        print("ChatQuestionTests passed")
    }
}
