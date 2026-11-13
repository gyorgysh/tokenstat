// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.automations

/// One piece of a run transcript: prose, or a tool call with the snippet
/// lines the host wrote under it. Port of TranscriptView.swift `Block`.
internal sealed interface RunTranscriptBlock {
    data class Text(val body: String) : RunTranscriptBlock
    data class Tool(val verb: String, val arg: String, val snippet: List<String>, val time: String?) : RunTranscriptBlock
}

/// Splits a run transcript into tool rows and prose. The host already
/// flattened NDJSON into paragraphs, so this only reads their first lines.
/// Port of TranscriptView.swift `parse`.
internal object RunTranscriptParser {
    /// Verbs the host writes as the first token of a tool paragraph.
    private val verbs = setOf(
        "Read", "Write", "Edit", "Shell", "Grep", "Glob", "Find", "Search",
        "Bash", "Task", "Subagent", "NotebookEdit", "WebFetch", "WebSearch",
        "TodoWrite",
    )

    fun parse(raw: String): List<RunTranscriptBlock> {
        if (raw.isEmpty()) return emptyList()
        val out = mutableListOf<RunTranscriptBlock>()
        for (para in raw.split("\n\n")) {
            val trimmed = para.trim('\n', '\r')
            if (trimmed.isEmpty()) continue
            val lines = trimmed.split("\n")
            val tool = toolLine(lines.first())
            if (tool == null) {
                out.add(RunTranscriptBlock.Text(trimmed))
                continue
            }
            val snippet = mutableListOf<String>()
            val rest = mutableListOf<String>()
            var inSnippet = true
            for (line in lines.drop(1)) {
                if (inSnippet && isSnippetLine(line)) {
                    snippet.add(line)
                } else {
                    inSnippet = false
                    rest.add(line)
                }
            }
            out.add(RunTranscriptBlock.Tool(tool.second, tool.third, snippet, tool.first))
            if (rest.isNotEmpty()) out.add(RunTranscriptBlock.Text(rest.joinToString("\n")))
        }
        return out
    }

    private fun toolLine(line: String): Triple<String?, String, String>? {
        var rest = line
        var time: String? = null
        clockPrefix(rest)?.let { (clock, after) ->
            time = clock
            rest = after
        }
        val space = rest.indexOf(' ')
        val verb = if (space < 0) rest else rest.substring(0, space)
        if (verb !in verbs) return null
        val arg = if (space < 0) "" else rest.substring(space + 1)
        // A sentence that happens to start with "Read" stays prose.
        if (arg.contains(". ") || arg.contains("? ")) return null
        return Triple(time, verb, arg)
    }

    /// `17:29:15 Bash ls` from the host. Optional. Prose never starts this way.
    private fun clockPrefix(line: String): Pair<String, String>? {
        if (line.length < 8) return null
        val shape = line[0].isDigit() && line[1].isDigit() && line[2] == ':' &&
            line[3].isDigit() && line[4].isDigit() && line[5] == ':' &&
            line[6].isDigit() && line[7].isDigit()
        if (!shape) return null
        val start = if (line.length > 8 && line[8] == ' ') 9 else 8
        return line.substring(0, 8) to line.substring(start)
    }

    private fun isSnippetLine(line: String): Boolean =
        line.startsWith("+ ") || line.startsWith("- ") || line.startsWith("| ") ||
            line.startsWith("+ …") || line.startsWith("- …") || line.startsWith("| …")
}
