// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.marks

import org.junit.Assert.assertEquals
import org.junit.Test

class UiSignalsTest {
    @Test
    fun refreshListenerCanUnsubscribeItselfDuringDelivery() {
        var count = 0
        lateinit var unsubscribe: () -> Unit
        unsubscribe = UiSignals.onRefreshing { count++; unsubscribe() }
        val other = UiSignals.onRefreshing { count++ }
        try {
            UiSignals.beganRefreshing()
            UiSignals.beganRefreshing()
            assertEquals(3, count)
        } finally { unsubscribe(); other() }
    }

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
