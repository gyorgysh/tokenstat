// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

import Foundation

/// Where dictated words land in the draft.
///
/// Speech recognition revises its whole guess as the person keeps talking,
/// so each reading replaces the previous one rather than being appended to
/// it. The words go after whatever was already typed, with one space between.
///
/// If the draft no longer ends with what dictation last wrote, the person has
/// typed or edited in the meantime. Writing over that would throw their edit
/// away, so `apply` answers nil and dictation stops instead.
struct ChatDictationText: Equatable {
    /// The draft as it was when dictation started.
    let original: String
    /// The latest reading, as it stands in the draft.
    private(set) var spoken = ""

    init(draft: String) {
        original = draft
    }

    /// What dictation expects the draft to hold right now.
    var expected: String { spoken.isEmpty ? original : Self.join(original, spoken) }

    /// The new draft for this reading, or nil when the draft was edited by
    /// hand since the last one.
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

/// Everything said since dictation started, as one running text.
///
/// Finished sentences are kept and new ones go after them. Only the part
/// still being heard (volatile) is replaced as the recognizer changes its
/// mind about it.
struct ChatDictationTranscript: Equatable {
    private(set) var finished = ""
    private(set) var volatile = ""

    var text: String { ChatDictationText.join(finished, volatile) }

    /// A stretch the recognizer will not revise any more.
    mutating func finish(_ words: String) {
        finished = ChatDictationText.join(finished, Self.clean(words))
        volatile = ""
    }

    /// The recognizer's current guess at what is being said now.
    mutating func hear(_ words: String) {
        volatile = Self.clean(words)
    }

    /// For the older recognizer, which reports one running guess and starts
    /// it over after a pause. A guess that no longer continues the last one
    /// is a new sentence, so the last one is kept instead of replaced.
    mutating func hearRunning(_ words: String) {
        let next = Self.clean(words)
        if Self.startsOver(from: volatile, to: next) {
            finished = ChatDictationText.join(finished, volatile)
        }
        volatile = next
    }

    /// A revision of the same sentence keeps roughly its length and its
    /// opening. A new sentence after a pause comes back short and starts
    /// somewhere else.
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
