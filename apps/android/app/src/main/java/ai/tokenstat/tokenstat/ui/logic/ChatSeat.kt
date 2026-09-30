// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.logic

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
            "Read" -> labeled("Reading", fileName(line))
            "Write" -> labeled("Writing", fileName(line))
            "Edit", "NotebookEdit" -> labeled("Editing", fileName(line))
            "Diff" -> labeled("Comparing", fileName(line))
            "Shell", "Bash" -> labeled("Running", collapsed)
            "Grep", "Search" -> labeled("Searching", collapsed)
            "Glob", "Find" -> {
                val file = fileName(line)
                if (file.isEmpty()) "Looking" else labeled("Looking through", file)
            }
            "WebFetch" -> labeled("Opening", site(collapsed))
            "WebSearch" -> "Searching the web"
            "Task", "Subagent" -> "Asking another agent"
            "TodoWrite" -> "Updating the list"
            else -> {
                // A path with nothing left after the slashes is just work.
                // "Working on" with an empty name reads as a broken sentence.
                val edges = trimEdges(line)
                if (edges.contains('/') || edges.contains('\\')) {
                    val file = fileName(line)
                    if (file.isEmpty()) "Working" else labeled("Working on", file)
                } else if (collapsed.isEmpty()) {
                    "Working"
                } else {
                    labeled("Working on", collapsed)
                }
            }
        }
    }

    /// Waiting wins. A real step is shown as written. Speaking is a reply.
    /// Everything else is thought.
    fun seatLabel(waiting: Boolean, step: String?, speaking: Boolean): String {
        if (waiting) return "Waiting"
        if (step != null && step.isNotBlank()) return step
        if (speaking) return "Replying"
        return "Thinking"
    }

    /// Present while the step runs, past once it has finished.
    /// An unknown name is returned unchanged, once trimmed.
    fun word(verb: String?, running: Boolean): String {
        return when (trimVerb(verb)) {
            "Read" -> if (running) "Reading" else "Read"
            "Write" -> if (running) "Writing" else "Wrote"
            "Edit", "NotebookEdit" -> if (running) "Editing" else "Edited"
            "Diff" -> if (running) "Comparing" else "Compared"
            "Shell", "Bash" -> if (running) "Running" else "Ran"
            "Grep", "Search" -> if (running) "Searching" else "Searched"
            "Glob", "Find" -> if (running) "Looking" else "Looked"
            "WebFetch" -> if (running) "Opening" else "Opened"
            "WebSearch" -> if (running) "Searching the web" else "Searched the web"
            "Task", "Subagent" -> if (running) "Asking another agent" else "Asked another agent"
            "TodoWrite" -> if (running) "Updating the list" else "Updated the list"
            "" -> if (running) "Working" else "Worked"
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
        if (name.isEmpty()) return "Approval"
        return word(name, pending)
    }

    /// What Always allow will store for the rest of this chat.
    /// A command prefix is that prefix. A plain tool is its own name.
    /// A command with no safe prefix is not stored, so the line says so
    /// instead of naming the tool.
    fun allowAlwaysNote(verb: String?, shellPrefix: String?): String? {
        val prefix = trimVerb(shellPrefix)
        if (prefix.isNotEmpty()) {
            return "Always allow remembers $prefix for this chat only."
        }
        if (isShell(verb)) {
            return "Always allow answers this request only. Nothing is saved for later."
        }
        val name = trimVerb(verb)
        if (name.isEmpty()) return null
        return "Always allow remembers $name for this chat only."
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
