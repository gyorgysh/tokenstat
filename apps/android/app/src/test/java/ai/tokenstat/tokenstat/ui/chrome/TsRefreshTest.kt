// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.chrome

import ai.tokenstat.tokenstat.ui.marks.UiSignals
import kotlinx.coroutines.test.runTest
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Test

class TsRefreshTest {
    @After
    fun restoreClock() {
        TsRefresh.clock = System::currentTimeMillis
        TsRefresh.resetForTest()
    }

    @Test
    fun firstPullRunsAndSecondPullSkips() = runTest {
        var now = 1_000_000L
        TsRefresh.clock = { now }
        var runs = 0
        var pulses = 0
        val drop = UiSignals.onRefreshing { pulses++ }
        try {
            TsRefresh.run("tsrefresh-first") { runs++ }
            TsRefresh.run("tsrefresh-first") { runs++ }
            assertEquals(1, runs)
            assertEquals(2, pulses)
        } finally {
            drop()
        }
    }

    @Test
    fun windowExpiryRunsAgain() = runTest {
        var now = 2_000_000L
        TsRefresh.clock = { now }
        var runs = 0
        TsRefresh.run("tsrefresh-expiry") { runs++ }
        now += 5_000L
        TsRefresh.run("tsrefresh-expiry") { runs++ }
        assertEquals(2, runs)
    }

    @Test
    fun scopesRefreshIndependently() = runTest {
        var now = 3_000_000L
        TsRefresh.clock = { now }
        var runs = 0
        TsRefresh.run("tsrefresh-scope", "origin|alice") { runs++ }
        TsRefresh.run("tsrefresh-scope", "origin|bob") { runs++ }
        TsRefresh.run("tsrefresh-scope", null) { runs++ }
        assertEquals(3, runs)
        TsRefresh.run("tsrefresh-scope", "origin|alice") { runs++ }
        assertEquals(3, runs)
    }
}
