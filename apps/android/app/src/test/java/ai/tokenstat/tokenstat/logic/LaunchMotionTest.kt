// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.logic

import ai.tokenstat.tokenstat.ui.logic.SplashHold
import ai.tokenstat.tokenstat.ui.logic.TabBarVisibility
import ai.tokenstat.tokenstat.ui.marks.LogoMotion
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class LaunchMotionTest {
    @Test
    fun splashHoldsForItsMinimum() {
        assertEquals(560L, SplashHold.minimumMs)
        assertEquals(280L, SplashHold.exitMs)
        assertTrue(SplashHold.hold(0))
        assertTrue(SplashHold.hold(559))
        assertFalse(SplashHold.hold(560))
        assertFalse(SplashHold.hold(5_000))
    }

    @Test
    fun tabBarMinimizesAfterTravelAndRestoresAtTop() {
        val slop = 10f
        val threshold = 100f
        fun next(minimized: Boolean, travel: Float, delta: Float, atTop: Boolean = false) =
            TabBarVisibility.next(minimized, travel, delta, slop, threshold, atTop)
        assertEquals(TabBarVisibility.Step(false, 20f), next(false, 0f, 20f))
        assertEquals(TabBarVisibility.Step(false, 90f), next(false, 70f, 20f))
        assertEquals(TabBarVisibility.Step(true, 110f), next(false, 90f, 20f))
        assertTrue(next(true, 110f, 20f).minimized)
        assertEquals(TabBarVisibility.Step(true, 0f), next(true, 110f, -20f, atTop = false))
        assertEquals(TabBarVisibility.Step(false, 0f), next(true, 110f, -20f, atTop = true))
        assertEquals(TabBarVisibility.Step(false, 0f), next(false, 90f, -20f))
    }

    @Test
    fun tabBarHoldsInsideTheSlop() {
        val slop = 10f
        val threshold = 100f
        fun next(minimized: Boolean, travel: Float, delta: Float) =
            TabBarVisibility.next(minimized, travel, delta, slop, threshold, false)
        assertEquals(TabBarVisibility.Step(false, 0f), next(false, 0f, 5f))
        assertEquals(TabBarVisibility.Step(false, 70f), next(false, 70f, -5f))
        assertEquals(TabBarVisibility.Step(true, 110f), next(true, 110f, 5f))
        assertEquals(TabBarVisibility.Step(true, 110f), next(true, 110f, -5f))
        assertEquals(TabBarVisibility.Step(false, 0f), next(false, 0f, slop))
        assertEquals(TabBarVisibility.Step(true, 110f), next(true, 110f, -slop))
    }

    @Test
    fun logoTimingsMatchApple() {
        assertEquals(620, LogoMotion.loopMs)
        assertEquals(140, LogoMotion.loopStaggerMs)
        assertEquals(1200, LogoMotion.oneShotMs)
        assertEquals(150L, LogoMotion.oneShotStaggerMs)
        assertEquals(260, LogoMotion.dipMs)
        assertEquals(70, LogoMotion.dipStaggerMs)
        assertEquals(0.35f, LogoMotion.dipScale, 0f)
        assertEquals(300L, LogoMotion.dipHoldMs)
    }
}
