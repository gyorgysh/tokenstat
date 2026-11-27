// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.ssh

object SnippetRun {
    fun runBytes(command: String): ByteArray =
        (command + "\r").toByteArray(Charsets.UTF_8)

    fun placeholders(command: String): List<String> {
        val found = mutableListOf<String>()
        var rest = command
        while (true) {
            val open = rest.indexOf("{{")
            if (open < 0) break
            val close = rest.indexOf("}}", open + 2)
            if (close < 0) break
            val name = rest.substring(open + 2, close).trim()
            if (name.isNotEmpty() && name !in found) found.add(name)
            rest = rest.substring(close + 2)
        }
        return found
    }

    fun fill(command: String, values: Map<String, String>): String {
        var out = command
        for ((name, value) in values) {
            out = Regex("\\{\\{\\s*${Regex.escape(name)}\\s*\\}\\}").replace(out) { value }
        }
        return out
    }
}
