// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.home

import org.junit.Assert.assertEquals
import org.junit.Test

class HomeSectionsTest {
    @Test
    fun machineStatesMatchApple() {
        assertEquals("Awake", machineState(true))
        assertEquals("Asleep", machineState(false))
        assertEquals("Status unknown", machineState(null))
    }
}
