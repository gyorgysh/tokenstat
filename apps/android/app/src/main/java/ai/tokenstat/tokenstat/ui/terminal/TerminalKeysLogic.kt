// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.terminal

import ai.tokenstat.tokenstat.ui.localization.L10n

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

    fun arrow(direction: Char, shift: Boolean = false, control: Boolean = false): ByteArray {
        require(direction in 'A'..'D')
        val modifier = 1 + (if (shift) 1 else 0) + (if (control) 4 else 0)
        return (if (modifier == 1) "\u001B[$direction" else "\u001B[1;$modifier$direction").toByteArray(Charsets.UTF_8)
    }

    /// What a screen reader says for a glyph face. "Right arrow", not
    /// "greater than".
    fun spoken(label: String): String = when (label) {
        "⇥" -> L10n.text("android.terminalkeyslogic.tab.90ddf196")
        "⇧⇥" -> L10n.text("android.terminalkeyslogic.shift_tab.f3fa2578")
        "↑" -> L10n.text("android.terminalkeyslogic.up_arrow.9d2e0b44")
        "↓" -> L10n.text("android.terminalkeyslogic.down_arrow.2d612154")
        "←" -> L10n.text("android.terminalkeyslogic.left_arrow.fe87c896")
        "→" -> L10n.text("android.terminalkeyslogic.right_arrow.0611d428")
        "/" -> L10n.text("android.terminalkeyslogic.slash.9c92721e")
        "-" -> L10n.text("android.terminalkeyslogic.dash.8c3ea2ea")
        "|" -> L10n.text("android.terminalkeyslogic.pipe.3725dbfe")
        "~" -> L10n.text("android.terminalkeyslogic.tilde.66042131")
        else -> label
    }

    /// A basename is a label. Never hand a working directory or command to a
    /// persistence boundary; this stays on the header line only.
    fun basename(path: String): String =
        path.trimEnd('/').substringAfterLast('/').ifBlank { path }

    /// CSS pixels for a measured view size, which is what the xterm page
    /// sizes its terminal box to. One CSS pixel is one dp at the page's
    /// default text zoom, so this is the view pixels over the density,
    /// floored. Zero means unmeasured: the page keeps its last good box
    /// rather than fitting against nothing.
    fun cssPx(viewPx: Int, density: Float): Int =
        if (viewPx <= 0 || density <= 0f) 0 else (viewPx / density).toInt().coerceAtLeast(1)
}
