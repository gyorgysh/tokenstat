// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.marks

import org.junit.Assert.assertEquals
import org.junit.Test

/// The refresh dip signal: every subscribed logo hears one refresh exactly
/// once, and an unsubscribed logo hears nothing, so a recomposed wordmark
/// cannot stack listeners and dip twice.
class UiSignalsTest {
    @Test
    fun refreshFansOutOnceThenUnsubscribes() {
        var first = 0
        var second = 0
        val dropFirst = UiSignals.onRefreshing { first++ }
        val dropSecond = UiSignals.onRefreshing { second++ }
        UiSignals.beganRefreshing()
        assertEquals(1, first)
        assertEquals(1, second)
        dropFirst()
        dropSecond()
        UiSignals.beganRefreshing()
        assertEquals(1, first)
        assertEquals(1, second)
    }
}
