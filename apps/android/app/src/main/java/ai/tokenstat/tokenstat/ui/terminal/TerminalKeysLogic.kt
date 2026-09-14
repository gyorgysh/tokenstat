// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.terminal

/// Pure key-bar rules shared by the agent and SSH terminals, ported from
/// Apple `ClientTerminalKeys` (`TerminalControlCode.fold` and `spoken`).
/// Kept free of Android imports so unit tests pin the same answers.
object TerminalKeysLogic {
    /// Fold a printable byte under Ctrl the way a keyboard does.
    /// Shift+Tab is CSI Z, not a shifted tab byte.
    fun controlCode(byte: Int): Int? = when (byte) {
        in 0x61..0x7A -> byte - 0x60
        in 0x41..0x5A -> byte - 0x40
        in 0x5B..0x5F -> byte - 0x40
        0x20 -> 0
        else -> null
    }

    val backTab: ByteArray = byteArrayOf(0x1B, 0x5B, 0x5A)

    /// What a screen reader says for a glyph face. "Right arrow", not
    /// "greater than".
    fun spoken(label: String): String = when (label) {
        "⇥" -> "Tab"
        "⇧⇥" -> "Shift Tab"
        "↑" -> "Up arrow"
        "↓" -> "Down arrow"
        "←" -> "Left arrow"
        "→" -> "Right arrow"
        "/" -> "Slash"
        "-" -> "Dash"
        "|" -> "Pipe"
        "~" -> "Tilde"
        else -> label
    }

    /// A basename is a label. Never hand a working directory or command to a
    /// persistence boundary; this stays on the header line only.
    fun basename(path: String): String =
        path.trimEnd('/').substringAfterLast('/').ifBlank { path }
}
