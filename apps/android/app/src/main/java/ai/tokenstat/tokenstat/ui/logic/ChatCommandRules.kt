// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.logic

internal object ChatCommandRules {
    val names = listOf("/compact", "/status", "/context", "/usage", "/mcp", "/tools", "/goal", "/plan", "/subagents", "/help", "/stop")
    fun sendMethod(text: String) = if (text.trim() == "/compact") "chat.compact" else "chat.send"
    // Match Rust's Unicode scalar limit rather than UTF-16 code units.
    fun canSteer(draft: String, attachments: Boolean, acceptsAttachments: Boolean): Boolean {
        val text = draft.trim()
        return (text.isNotEmpty() || attachments) && (!attachments || acceptsAttachments) &&
            !text.startsWith("/") && text.codePointCount(0, text.length) <= 1_500
    }
    enum class Kind { MESSAGE, COMPLETE, INSPECT, STOP, COMPACT, ATTACHMENTS, ARGUMENTS, UNSUPPORTED, RUNNING }
    data class Action(val kind: Kind, val completion: String? = null)
    fun matches(draft: String): List<String> {
        val text = draft.trim()
        return if (text.startsWith("/") && text.none(Char::isWhitespace)) names.filter { it.startsWith(text) } else emptyList()
    }
    fun action(draft: String, backend: String?, running: Boolean, attachments: Boolean, selection: Int = 0): Action {
        val text = draft.trim()
        val word = text.split(Regex("\\s+"), limit = 2).first()
        if (word !in names) {
            val choices = matches(text)
            return if (choices.isEmpty()) Action(Kind.MESSAGE) else Action(Kind.COMPLETE, choices[selection.coerceIn(0, choices.lastIndex)])
        }
        if (attachments) return Action(Kind.ATTACHMENTS)
        if (word != text) return Action(Kind.ARGUMENTS)
        if (word == "/compact") return Action(when {
            backend !in listOf("claude", "codex") -> Kind.UNSUPPORTED
            running -> Kind.RUNNING
            else -> Kind.COMPACT
        })
        return Action(if (word == "/stop") Kind.STOP else Kind.INSPECT)
    }
}
