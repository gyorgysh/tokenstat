// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.logic

internal enum class MarkdownTableAlignment { Left, Center, Right }
internal data class MarkdownTable(
    val header: List<String>,
    val rows: List<List<String>>,
    val alignment: List<MarkdownTableAlignment>,
    val end: Int,
)

internal object MarkdownTables {
    fun parse(lines: List<String>, start: Int): MarkdownTable? {
        if (start + 1 >= lines.size || '|' !in lines[start]) return null
        val header = cells(lines[start])
        val delimiter = cells(lines[start + 1])
        if (header.isEmpty() || delimiter.size != header.size ||
            delimiter.any { !it.matches(Regex(":?-{3,}:?")) }) return null
        val alignment = delimiter.map {
            when {
                it.startsWith(':') && it.endsWith(':') -> MarkdownTableAlignment.Center
                it.endsWith(':') -> MarkdownTableAlignment.Right
                else -> MarkdownTableAlignment.Left
            }
        }
        var end = start + 2
        val rows = mutableListOf<List<String>>()
        while (end < lines.size && lines[end].isNotBlank() && '|' in lines[end]) {
            val row = cells(lines[end])
            rows.add(List(header.size) { row.getOrElse(it) { "" } })
            end++
        }
        return MarkdownTable(header, rows, alignment, end)
    }

    private fun cells(line: String): List<String> {
        val text = line.trim().removePrefix("|")
        val result = mutableListOf<String>()
        val cell = StringBuilder()
        var index = 0
        while (index < text.length) {
            val char = text[index]
            if (char == '\\' && index + 1 < text.length && text[index + 1] == '|') {
                cell.append('|')
                index += 2
                continue
            }
            if (char == '|') { result.add(cell.toString().trim()); cell.clear() }
            else cell.append(char)
            index++
        }
        if (cell.isNotEmpty() || !text.endsWith('|')) result.add(cell.toString().trim())
        return result
    }
}
