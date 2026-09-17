// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.chrome

import ai.tokenstat.tokenstat.ui.marks.UiSignals
import kotlinx.coroutines.test.runTest
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Test

/// The refresh debounce matches `ClientRefresh.swift`: the logo pulses on
/// every pull, the fetch runs at most once per five-second window per
/// screen, and the window is scoped to the signed-in account.
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
            // A pull inside the window is not ignored silently: the logo
            // still acknowledges it, like the iPhone wordmark.
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
        // The first pull after an account switch is never swallowed by the
        // outgoing account's timestamp.
        TsRefresh.run("tsrefresh-scope", "origin|bob") { runs++ }
        TsRefresh.run("tsrefresh-scope", null) { runs++ }
        assertEquals(3, runs)
        // But the same scope inside the window still skips.
        TsRefresh.run("tsrefresh-scope", "origin|alice") { runs++ }
        assertEquals(3, runs)
    }
}
