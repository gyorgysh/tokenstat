// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.logic

import ai.tokenstat.tokenstat.ui.localization.L10n

/// Words for the live seat, a tool row, and a permission chip.
///
/// The same sentences are used on every client. The seat names the whole
/// step in one line. A row keeps the path or the command beside a shorter
/// word: present while the step runs, past once it has finished. A name
/// this list does not know stays as the tool wrote it. The permission
/// chip uses that same word. The Always allow line names the rule that
/// is stored, which is a command prefix or a tool name, never the chip.
object ChatSeat {
    const val DETAIL_CAP = 32
    const val SCAN_CAP = 4096

    fun phrase(verb: String?, target: String?): String {
        val name = trimVerb(verb)
        val line = firstLine(scan(target))
        val collapsed = collapse(line)
        return when (name) {
            "Read" -> labeled(L10n.text("android.chatseat.reading.463816d0"), fileName(line))
            "Write" -> labeled(L10n.text("android.chatseat.writing.a8bfae3e"), fileName(line))
            "Edit", "NotebookEdit" -> labeled(L10n.text("android.chatseat.editing.fab4539d"), fileName(line))
            "Diff" -> labeled(L10n.text("android.chatseat.comparing.1fa1aad0"), fileName(line))
            "Shell", "Bash" -> labeled(L10n.text("common.running"), collapsed)
            "Grep", "Search" -> labeled(L10n.text("android.chatseat.searching.03bd6fca"), collapsed)
            "Glob", "Find" -> {
                val file = fileName(line)
                if (file.isEmpty()) L10n.text("android.chatseat.looking.afa37c88") else labeled(L10n.text("android.chatseat.looking_through.6c8d5b7b"), file)
            }
            "WebFetch" -> labeled(L10n.text("android.chatseat.opening.f4b13e93"), site(collapsed))
            "WebSearch" -> L10n.text("android.chatseat.searching_the_web.87d2f338")
            "Task", "Subagent" -> L10n.text("android.chatseat.asking_another_agent.fde5ee73")
            "TodoWrite" -> L10n.text("android.chatseat.updating_the_list.ca724dcc")
            else -> {
                // A path with nothing left after the slashes is just work.
                // "Working on" with an empty name reads as a broken sentence.
                val edges = trimEdges(line)
                if (edges.contains('/') || edges.contains('\\')) {
                    val file = fileName(line)
                    if (file.isEmpty()) L10n.text("common.working") else labeled(L10n.text("android.chatseat.working_on.006abaf3"), file)
                } else if (collapsed.isEmpty()) {
                    L10n.text("common.working")
                } else {
                    labeled(L10n.text("android.chatseat.working_on.006abaf3"), collapsed)
                }
            }
        }
    }

    /// Waiting wins. A real step is shown as written. Speaking is a reply.
    /// Everything else is thought.
    fun seatLabel(waiting: Boolean, step: String?, speaking: Boolean): String {
        if (waiting) return L10n.text("common.waiting")
        if (step != null && step.isNotBlank()) return step
        if (speaking) return L10n.text("android.chatseat.replying.b2663dd7")
        return L10n.text("android.chatseat.thinking.a20d12c5")
    }

    /// Present while the step runs, past once it has finished.
    /// An unknown name is returned unchanged, once trimmed.
    fun word(verb: String?, running: Boolean): String {
        return when (trimVerb(verb)) {
            "Read" -> if (running) L10n.text("android.chatseat.reading.463816d0") else L10n.text("android.chatseat.read.9b9a8d05")
            "Write" -> if (running) L10n.text("android.chatseat.writing.a8bfae3e") else L10n.text("android.chatseat.wrote.42717062")
            "Edit", "NotebookEdit" -> if (running) L10n.text("android.chatseat.editing.fab4539d") else L10n.text("android.chatseat.edited.7117f080")
            "Diff" -> if (running) L10n.text("android.chatseat.comparing.1fa1aad0") else L10n.text("android.chatseat.compared.17c858fc")
            "Shell", "Bash" -> if (running) L10n.text("common.running") else L10n.text("android.chatseat.ran.b6a7c95e")
            "Grep", "Search" -> if (running) L10n.text("android.chatseat.searching.03bd6fca") else L10n.text("android.chatseat.searched.9fc7f116")
            "Glob", "Find" -> if (running) L10n.text("android.chatseat.looking.afa37c88") else L10n.text("android.chatseat.looked.07558310")
            "WebFetch" -> if (running) L10n.text("android.chatseat.opening.f4b13e93") else L10n.text("android.chatseat.opened.b19fb8d1")
            "WebSearch" -> if (running) L10n.text("android.chatseat.searching_the_web.87d2f338") else L10n.text("android.chatseat.searched_the_web.7d2580ce")
            "Task", "Subagent" -> if (running) L10n.text("android.chatseat.asking_another_agent.fde5ee73") else L10n.text("android.chatseat.asked_another_agent.629f8e22")
            "TodoWrite" -> if (running) L10n.text("android.chatseat.updating_the_list.ca724dcc") else L10n.text("android.chatseat.updated_the_list.de8e6fab")
            "" -> if (running) L10n.text("common.working") else L10n.text("android.chatseat.worked.e7f93aad")
            else -> trimVerb(verb)
        }
    }

    /// The running word already says what is happening, so a Running chip
    /// beside it would repeat the same news.
    fun speaks(verb: String?): Boolean {
        val name = trimVerb(verb)
        return word(name, true) != name
    }

    /// The chip on a permission card. Pending is present tense, a decision
    /// is past tense, and a blank name stays Approval.
    fun approvalWord(verb: String?, pending: Boolean): String {
        val name = trimVerb(verb)
        if (name.isEmpty()) return L10n.text("android.chatseat.approval.147fb813")
        return word(name, pending)
    }

    /// What Always allow will store for the rest of this chat.
    /// A command prefix is that prefix. A plain tool is its own name.
    /// A command with no safe prefix is not stored, so the line says so
    /// instead of naming the tool.
    fun allowAlwaysNote(verb: String?, shellPrefix: String?): String? {
        val prefix = trimVerb(shellPrefix)
        if (prefix.isNotEmpty()) {
            return L10n.text("android.chatseat.always_allow_remembers_0_for_this_chat_onl.394a9e6d", "${prefix}")
        }
        if (isShell(verb)) {
            return L10n.text("android.chatseat.always_allow_answers_this_request_only_not.a067a2b7")
        }
        val name = trimVerb(verb)
        if (name.isEmpty()) return null
        return L10n.text("android.chatseat.always_allow_remembers_0_for_this_chat_onl.394a9e6d", "${name}")
    }

    /// Same rule as the host: a shell tool is never remembered by its name.
    fun isShell(verb: String?): Boolean {
        val name = trimVerb(verb).lowercase()
        if (name.contains("bash") || name.contains("shell") ||
            name.contains("command") || name.contains("terminal")
        ) {
            return true
        }
        val token = StringBuilder()
        fun shellToken(value: String) = value == "sh" || value == "zsh" || value == "exec" || value == "run"
        for (character in name) {
            if (character.code < 128 && character.isLetterOrDigit()) {
                token.append(character)
            } else if (shellToken(token.toString())) {
                return true
            } else {
                token.clear()
            }
        }
        return shellToken(token.toString())
    }

    private fun trimVerb(verb: String?): String = verb?.trim() ?: ""

    private fun scan(target: String?): String {
        if (target.isNullOrEmpty()) return ""
        return if (target.length <= SCAN_CAP) target else target.substring(0, SCAN_CAP)
    }

    private fun firstLine(text: String): String {
        val cut = text.indexOfAny(charArrayOf('\n', '\r'))
        return if (cut < 0) text else text.substring(0, cut)
    }

    private fun trimEdges(text: String): String {
        var start = 0
        var end = text.length
        while (start < end && (text[start] == ' ' || text[start] == '\t')) start++
        while (end > start && (text[end - 1] == ' ' || text[end - 1] == '\t')) end--
        return text.substring(start, end)
    }

    private fun collapse(line: String): String {
        val trimmed = trimEdges(line)
        val out = StringBuilder(trimmed.length)
        var pending = false
        for (character in trimmed) {
            if (character == ' ' || character == '\t') {
                pending = true
                continue
            }
            if (pending && out.isNotEmpty()) out.append(' ')
            pending = false
            out.append(character)
        }
        return out.toString()
    }

    private fun fileName(line: String): String {
        var name = trimEdges(line)
        while (name.isNotEmpty() && (name.last() == '/' || name.last() == '\\')) {
            name = name.dropLast(1)
        }
        if (name.isEmpty()) return ""
        val slash = name.lastIndexOf('/')
        val back = name.lastIndexOf('\\')
        val cut = maxOf(slash, back)
        if (cut < 0) return name
        return name.substring(cut + 1)
    }

    private fun clip(detail: String): String {
        if (detail.length <= DETAIL_CAP) return detail
        return detail.substring(0, DETAIL_CAP - 1) + "…"
    }

    private fun labeled(gerund: String, detail: String): String {
        if (detail.isEmpty()) return gerund
        return "$gerund ${clip(detail)}"
    }

    private fun site(collapsed: String): String {
        if (collapsed.isEmpty()) return ""
        var host = collapsed
        val scheme = host.indexOf("://")
        if (scheme >= 0) host = host.substring(scheme + 3)
        val cut = host.indexOfAny(charArrayOf('/', '?', '#'))
        if (cut >= 0) host = host.substring(0, cut)
        val at = host.lastIndexOf('@')
        if (at >= 0) host = host.substring(at + 1)
        host = stripPort(host)
        if (host.isEmpty()) return clip(collapsed)
        return clip(host)
    }

    private fun stripPort(host: String): String {
        if (host.startsWith('[')) {
            val close = host.indexOf(']')
            if (close < 0) return host
            val suffix = host.substring(close + 1)
            if (suffix.startsWith(':') && isAsciiDigits(suffix.substring(1))) {
                return host.substring(0, close + 1)
            }
            return host
        }
        val colon = host.lastIndexOf(':')
        if (colon < 0) return host
        if (isAsciiDigits(host.substring(colon + 1))) return host.substring(0, colon)
        return host
    }

    private fun isAsciiDigits(text: String): Boolean {
        if (text.isEmpty()) return false
        for (character in text) {
            if (character < '0' || character > '9') return false
        }
        return true
    }
}
