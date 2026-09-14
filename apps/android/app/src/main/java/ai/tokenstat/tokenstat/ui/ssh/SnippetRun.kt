// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.ssh

/// Saved-command rules for the SSH live session, ported from Apple
/// `SSHSnippet` (`bytesToRun`, `placeholders`).
///
/// A snippet with placeholders goes through the fill-in sheet, where the
/// filled command is on screen before it is sent. Everything else runs on
/// the press: a snippet is a command somebody saved in order to run it.
/// Values are asked for every time and never stored.
///
/// Kept free of Android imports so unit tests pin the same answers.
object SnippetRun {
    /// The bytes that type the command, with Return to run it.
    fun runBytes(command: String): ByteArray =
        (command + "\r").toByteArray(Charsets.UTF_8)

    /// `{{name}}` occurrences, in the order they appear.
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

    /// Fill every `{{name}}` from values. Unknown names stay on screen
    /// rather than vanishing silently.
    fun fill(command: String, values: Map<String, String>): String {
        var out = command
        for ((name, value) in values) {
            // Literal replacement: a value holding `$` must not read as a group.
            out = Regex("\\{\\{\\s*${Regex.escape(name)}\\s*\\}\\}").replace(out) { value }
        }
        return out
    }
}
