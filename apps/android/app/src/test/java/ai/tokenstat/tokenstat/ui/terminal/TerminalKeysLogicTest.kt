// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.terminal

import org.junit.Assert.assertArrayEquals
import org.junit.Test

class TerminalKeysLogicTest {
    @Test fun arrowsRetainArmedModifiers() {
        fun bytes(value: String) = value.toByteArray(Charsets.UTF_8)
        assertArrayEquals(bytes("\u001B[D"), TerminalKeysLogic.arrow('D'))
        assertArrayEquals(bytes("\u001B[1;2D"), TerminalKeysLogic.arrow('D', shift = true))
        assertArrayEquals(bytes("\u001B[1;2C"), TerminalKeysLogic.arrow('C', shift = true))
        assertArrayEquals(bytes("\u001B[1;5A"), TerminalKeysLogic.arrow('A', control = true))
        assertArrayEquals(bytes("\u001B[1;6B"), TerminalKeysLogic.arrow('B', shift = true, control = true))
    }
}
