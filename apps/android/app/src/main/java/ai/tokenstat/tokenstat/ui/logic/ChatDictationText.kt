// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.logic

class ChatDictationText(
    val original: String,
) {
    var spoken: String = ""
        private set

    val expected: String get() = if (spoken.isEmpty()) original else join(original, spoken)

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

class ChatDictationTranscript {
    var finished: String = ""
        private set
    var volatile: String = ""
        private set

    val text: String get() = ChatDictationText.join(finished, volatile)

    fun finish(words: String) {
        finished = ChatDictationText.join(finished, words.trim())
        volatile = ""
    }

    fun hear(words: String) {
        volatile = words.trim()
    }
}

fun dictationLevel(rmsDb: Float): Float = ((rmsDb + 2f) / 12f).coerceIn(0f, 1f)
