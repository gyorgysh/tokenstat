// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.logic

/// Where dictated words land in the draft. Port of ChatDictationText.swift.
///
/// Speech recognition revises its whole guess as the person keeps talking,
/// so each reading replaces the previous one rather than being appended to
/// it. The words go after whatever was already typed, with one space between.
///
/// If the draft no longer ends with what dictation last wrote, the person has
/// typed or edited in the meantime. Writing over that would throw their edit
/// away, so `apply` answers null and dictation stops instead.
class ChatDictationText(
    /// The draft as it was when dictation started.
    val original: String,
) {
    /// The latest reading, as it stands in the draft.
    var spoken: String = ""
        private set

    /// What dictation expects the draft to hold right now.
    val expected: String get() = if (spoken.isEmpty()) original else join(original, spoken)

    /// The new draft for this reading, or null when the draft was edited by
    /// hand since the last one.
    fun apply(transcript: String, current: String): String? {
        if (current != expected) return null
        spoken = transcript.trim()
        return expected
    }

    companion object {
        fun join(draft: String, words: String): String {
            if (words.isEmpty()) return draft
            val last = draft.lastOrNull() ?: return words
            return if (last.isWhitespace()) draft + words else "$draft $words"
        }
    }
}

/// Everything said since dictation started, as one running text. Port of
/// `ChatDictationTranscript`.
///
/// Finished stretches are kept and new ones go after them. Only the part
/// still being heard is replaced as the recognizer changes its mind about it.
/// Android's recognizer ends a stretch at every pause and is started again,
/// so each final result is one finished stretch.
class ChatDictationTranscript {
    var finished: String = ""
        private set
    var volatile: String = ""
        private set

    val text: String get() = ChatDictationText.join(finished, volatile)

    /// A stretch the recognizer will not revise any more.
    fun finish(words: String) {
        finished = ChatDictationText.join(finished, words.trim())
        volatile = ""
    }

    /// The recognizer's current guess at what is being said now.
    fun hear(words: String) {
        volatile = words.trim()
    }
}

/// Sound level to a bar height between 0 and 1. The recognizer reports
/// roughly -2 dB in a quiet room and 10 dB for clear speech.
fun dictationLevel(rmsDb: Float): Float = ((rmsDb + 2f) / 12f).coerceIn(0f, 1f)
