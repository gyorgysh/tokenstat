// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.screen

import android.view.KeyEvent
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class ScreenShortcutTest {
    @Test fun hardwareShortcutsPreserveThePhysicalKey() {
        assertEquals(ScreenKey.code('a'), screenShortcutCode(KeyEvent.KEYCODE_A, ScreenFlag.CONTROL))
        assertEquals(ScreenKey.code('c'), screenShortcutCode(KeyEvent.KEYCODE_C, ScreenFlag.COMMAND))
        assertEquals(ScreenKey.code('z'), screenShortcutCode(KeyEvent.KEYCODE_Z, ScreenFlag.CONTROL or ScreenFlag.SHIFT))
        assertNull(screenShortcutCode(KeyEvent.KEYCODE_A, ScreenFlag.SHIFT))
        assertNull(screenShortcutCode(KeyEvent.KEYCODE_ENTER, ScreenFlag.CONTROL))
    }
}
