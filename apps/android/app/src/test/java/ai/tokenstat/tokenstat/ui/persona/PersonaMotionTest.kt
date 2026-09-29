// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.persona

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class PersonaMotionTest {
    @Test fun everyPlushShapeRemainsBoundedThroughRollsAndTransitions() {
        for (seed in listOf(0UL, 1UL, 3UL, 5UL, 7UL, 997UL, ULong.MAX_VALUE)) {
            val traits = PersonaTraits(seed)
            val motion = PersonaMotion(seed, traits.lumps, traits.firmness.toDouble())
            var time = 0.0
            for (mood in PersonaMood.entries) {
                repeat(3600) {
                    time += 1.0 / 60
                    motion.advance(time, mood)
                    assertTrue(motion.roll.isFinite() && motion.yaw.isFinite())
                    assertTrue(motion.x.all { it.isFinite() && it in 0.02..0.98 })
                    assertTrue(motion.y.all { it.isFinite() && it in 0.02..0.95 })
                    assertTrue(motion.x.max() - motion.x.min() > 0.1)
                    assertTrue(motion.y.max() - motion.y.min() > 0.1)
                }
            }
        }
    }

    @Test fun everyMoodPairPreservesPositionOnTransition() {
        for (seed in listOf(0UL, 1UL, 3UL, 5UL, 7UL, 997UL, ULong.MAX_VALUE)) {
            val traits = PersonaTraits(seed)
            val motion = PersonaMotion(seed, traits.lumps, traits.firmness.toDouble())
            var time = 0.0
            for (from in PersonaMood.entries) for (to in PersonaMood.entries) {
                repeat(45) { time += 1.0 / 60; motion.advance(time, from) }
                val beforeX = motion.x.copyOf(); val beforeY = motion.y.copyOf()
                motion.advance(time, to)
                assertArrayEquals(beforeX, motion.x, 0.0)
                assertArrayEquals(beforeY, motion.y, 0.0)
                repeat(45) {
                    val lastX = motion.x.copyOf(); val lastY = motion.y.copyOf()
                    time += 1.0 / 60
                    motion.advance(time, to)
                    assertTrue(motion.x.indices.all { kotlin.math.abs(motion.x[it] - lastX[it]) < 0.3 })
                    assertTrue(motion.y.indices.all { kotlin.math.abs(motion.y[it] - lastY[it]) < 0.3 })
                }
            }
        }
    }

    @Test fun suspendDoesNotCatchUpAndReducedMotionStaysStill() {
        val traits = PersonaTraits(42UL)
        val motion = PersonaMotion(42UL, traits.lumps, traits.firmness.toDouble())
        repeat(120) { motion.advance(it / 60.0, PersonaMood.Bouncing) }
        val frozenX = motion.x.copyOf(); val frozenY = motion.y.copyOf()
        motion.suspendClock()
        motion.advance(3600.0, PersonaMood.Bouncing)
        assertArrayEquals(frozenX, motion.x, 0.0)
        assertArrayEquals(frozenY, motion.y, 0.0)
        motion.advance(3601.0, PersonaMood.Idle, moving = false)
        val settled = motion.x.copyOf()
        motion.advance(3602.0, PersonaMood.Idle, moving = false)
        assertArrayEquals(settled, motion.x, 0.0)
        assertEquals(0.0, motion.roll, 0.0)
        assertEquals(0.0, motion.yaw, 0.0)
        assertEquals(motion.mood, motion.previousMood)
        assertTrue(motion.moodAge >= 0.4)
    }
}
