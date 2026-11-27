// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

import Foundation

struct ChatQuestion: Equatable, Sendable {
    let id: String
    let question: String
    let options: [String]
    let multiple: Bool
    let defaultAnswer: String?
    let blocking: Bool
    var answer: String?
    var delivery: String?

    var isAnswered: Bool { answer != nil }
}

extension ChatDisplayItem {
    var questionID: String? {
        if case let .question(question) = kind { return question.id }
        return nil
    }
}

struct ChatQuestionDelivery: Decodable, Sendable {
    let delivery: String
}

enum ChatQuestionText {
    static let fence = "tokenstat-question"
    static let planFence = "tokenstat-plan"
    private static let blockMaxBytes = 64 * 1024

    static func stripping(_ text: String, streaming: Bool = true) -> String {
        guard text.contains(fence) || text.contains(planFence) else { return text }
        var kept: [String] = []
        var inside = false
        var isPlan = false
        var block: [String] = []
        var bodyBytes = 0
        let lines = text.components(separatedBy: "\n")
        for (index, line) in lines.enumerated() {
            if !inside, let opening = Self.opening(in: line) {
                if !opening.prefix.isEmpty { kept.append(opening.prefix) }
                inside = true
                isPlan = opening.isPlan
                block = [opening.fenceLine]
                bodyBytes = 0
                if let sameLine = opening.sameLineBody {
                    if let closed = Self.closeBodyLine(sameLine, block: &block, isPlan: isPlan, kept: &kept) {
                        inside = closed.inside
                        isPlan = closed.isPlan
                        bodyBytes = 0
                    } else {
                        block.append(sameLine)
                        bodyBytes = sameLine.utf8.count
                    }
                }
                continue
            }
            if inside {
                if let closed = Self.closeBodyLine(line, block: &block, isPlan: isPlan, kept: &kept) {
                    inside = closed.inside
                    isPlan = closed.isPlan
                    bodyBytes = 0
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

    private static func opening(in line: String) -> (prefix: String, fenceLine: String, sameLineBody: String?, isPlan: Bool)? {
        var start = line.startIndex
        while start < line.endIndex, let range = line.range(of: "```", range: start..<line.endIndex) {
            let afterTicks = line[range.upperBound...]
            let headerEnd = afterTicks.firstIndex(of: "\n") ?? afterTicks.endIndex
            let header = String(afterTicks[..<headerEnd]).trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
            if let matched = Self.fenceBody(in: header) {
                let prefix = String(line[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
                let fenceLine = "```" + matched.language
                return (prefix, fenceLine, matched.body, matched.isPlan)
            }
            start = range.upperBound
        }
        return nil
    }

    private static func fenceBody(in header: String) -> (language: String, body: String?, isPlan: Bool)? {
        let trimmed = header.trimmingCharacters(in: .whitespaces)
        for (name, isPlan) in [(planFence, true), (fence, false)] {
            if trimmed == name { return (name, nil, isPlan) }
            guard trimmed.hasPrefix(name) else { continue }
            let rest = trimmed.dropFirst(name.count)
            guard rest.first?.isWhitespace == true else { continue }
            let body = rest.drop(while: { $0.isWhitespace })
            guard body.first == "{" else { continue }
            return (name, String(body), isPlan)
        }
        return nil
    }

    private static func closeBodyLine(
        _ line: String,
        block: inout [String],
        isPlan: Bool,
        kept: inout [String]
    ) -> (inside: Bool, isPlan: Bool)? {
        guard let closed = Self.closingFence(in: line) else { return nil }
        if !closed.bodyPrefix.isEmpty { block.append(closed.bodyPrefix) }
        let body = block.dropFirst().joined(separator: "\n")
        let value = body.utf8.count < blockMaxBytes
            ? try? JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any] : nil
        let question = value?["question"] as? String
        let valid = isPlan
            ? value?["steps"] is [Any]
            : question?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        let next = closed.trailing.trimmingCharacters(in: .whitespaces)
        let nextInfo = Self.fenceBody(in: next.hasPrefix("```") ? String(next.dropFirst(3)) : "")
        let reopen = Self.opening(in: closed.trailing)
        let opensNext = nextInfo != nil || reopen != nil
        if !valid {
            kept.append(contentsOf: block)
            if closed.bodyPrefix.isEmpty {
                kept.append(opensNext ? String(line.dropLast(closed.trailing.count)) : line)
            } else if !opensNext, !closed.trailing.isEmpty {
                kept.append(closed.trailing)
            }
            if opensNext, let reopen, !reopen.prefix.isEmpty {
                kept.append(reopen.prefix)
            }
        } else if let reopen {
            if !reopen.prefix.isEmpty { kept.append(reopen.prefix) }
        } else if !closed.trailing.isEmpty {
            kept.append(closed.trailing)
        }
        block = []
        if let reopen {
            block = [reopen.fenceLine]
            if let same = reopen.sameLineBody {
                if let closed = Self.closeBodyLine(same, block: &block, isPlan: reopen.isPlan, kept: &kept) {
                    return closed
                }
                block.append(same)
            }
            return (true, reopen.isPlan)
        }
        if let nextInfo {
            block = ["```" + nextInfo.language]
            return (true, nextInfo.isPlan)
        }
        return (false, isPlan)
    }

    private static func closingFence(in line: String) -> (bodyPrefix: String, trailing: String)? {
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
        if ticks >= 3 {
            let afterThree = line.index(index, offsetBy: 3)
            let afterRun = line[cursor...].drop { $0 == " " || $0 == "\t" }
            if ticks >= 6, afterRun.first?.isASCII == true, afterRun.first?.isLetter == true {
                var glued = line[afterThree...]
                if glued.last == "\r" { glued = glued.dropLast() }
                return ("", String(glued))
            }
            var trailing = line[cursor...]
            if trailing.last == "\r" { trailing = trailing.dropLast() }
            while trailing.first == " " || trailing.first == "\t" {
                trailing = trailing.dropFirst()
            }
            return ("", String(trailing))
        }
        return trailingClose(in: line)
    }

    private static func trailingClose(in line: String) -> (bodyPrefix: String, trailing: String)? {
        var start = line.startIndex
        while start < line.endIndex, let range = line.range(of: "```", range: start..<line.endIndex) {
            let before = String(line[..<range.lowerBound])
            if before.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                start = range.upperBound
                continue
            }
            var cursor = range.lowerBound
            var ticks = 0
            while cursor < line.endIndex, line[cursor] == "`" {
                ticks += 1
                cursor = line.index(after: cursor)
            }
            let afterThree = line.index(range.lowerBound, offsetBy: 3, limitedBy: line.endIndex) ?? line.endIndex
            let afterRun = line[cursor...].drop { $0 == " " || $0 == "\t" }
            if ticks >= 6, afterRun.first?.isASCII == true, afterRun.first?.isLetter == true {
                var glued = line[afterThree...]
                if glued.last == "\r" { glued = glued.dropLast() }
                return (before, String(glued))
            }
            var trailing = line[cursor...]
            if trailing.last == "\r" { trailing = trailing.dropLast() }
            while trailing.first == " " || trailing.first == "\t" {
                trailing = trailing.dropFirst()
            }
            return (before, String(trailing))
        }
        return nil
    }
}
