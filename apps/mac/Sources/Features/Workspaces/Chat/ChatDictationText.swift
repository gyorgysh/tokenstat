// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

import Foundation

struct ChatDictationText: Equatable {
    let original: String
    private(set) var spoken = ""

    init(draft: String) {
        original = draft
    }

    var expected: String { spoken.isEmpty ? original : Self.join(original, spoken) }

    mutating func apply(_ transcript: String, to current: String) -> String? {
        guard current == expected else { return nil }
        spoken = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        return expected
    }

    static func join(_ draft: String, _ words: String) -> String {
        guard !words.isEmpty else { return draft }
        guard let last = draft.last else { return words }
        return last.isWhitespace ? draft + words : draft + " " + words
    }
}

struct ChatDictationTranscript: Equatable {
    private(set) var finished = ""
    private(set) var volatile = ""

    var text: String { ChatDictationText.join(finished, volatile) }

    mutating func finish(_ words: String) {
        finished = ChatDictationText.join(finished, Self.clean(words))
        volatile = ""
    }

    mutating func hear(_ words: String) {
        volatile = Self.clean(words)
    }

    mutating func hearRunning(_ words: String) {
        let next = Self.clean(words)
        if Self.startsOver(from: volatile, to: next) {
            finished = ChatDictationText.join(finished, volatile)
        }
        volatile = next
    }

    static func startsOver(from old: String, to new: String) -> Bool {
        guard !old.isEmpty, !new.isEmpty, new.count < old.count else { return false }
        if new.count * 2 < old.count { return true }
        return firstWord(old) != firstWord(new)
    }

    private static func firstWord(_ text: String) -> String {
        let word = text.split(whereSeparator: { $0.isWhitespace }).first.map(String.init) ?? ""
        return word.lowercased().trimmingCharacters(in: .punctuationCharacters)
    }

    private static func clean(_ words: String) -> String {
        words.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
