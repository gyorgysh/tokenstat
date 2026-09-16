// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.components

import ai.tokenstat.tokenstat.ui.marks.SLOT_GAUGE_MAX_TILES
import ai.tokenstat.tokenstat.ui.marks.TierKind
import ai.tokenstat.tokenstat.ui.marks.avatarInitials
import ai.tokenstat.tokenstat.ui.marks.countdownFraction
import ai.tokenstat.tokenstat.ui.marks.scheduleFires
import ai.tokenstat.tokenstat.ui.marks.slotGaugeDrawn
import ai.tokenstat.tokenstat.ui.marks.slotGaugeLabel
import ai.tokenstat.tokenstat.ui.marks.tierKind
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/// Pins the shared-component logic to the answers the Apple client's Swift
/// originals produce, so both platforms cannot drift apart silently.
class SharedComponentsTest {

    @Test
    fun timeLimitPresetsMatch() {
        assertEquals(15, selectedTimeLimitPreset("15", false))
        assertEquals(30, selectedTimeLimitPreset("30", false))
        assertEquals(60, selectedTimeLimitPreset("60", false))
        assertEquals(180, selectedTimeLimitPreset("180", false))
        assertEquals(480, selectedTimeLimitPreset("480", false))
    }

    @Test
    fun timeLimitCustomNumberSelectsNone() {
        assertNull(selectedTimeLimitPreset("45", false))
        assertNull(selectedTimeLimitPreset("", false))
        assertNull(selectedTimeLimitPreset("abc", false))
    }

    @Test
    fun timeLimitNoLimitOverridesTheField() {
        assertNull(selectedTimeLimitPreset("30", true))
    }

    @Test
    fun concurrentPresetsMatch() {
        assertEquals(1u, selectedConcurrentPreset("1"))
        assertEquals(2u, selectedConcurrentPreset("2"))
        assertEquals(4u, selectedConcurrentPreset("4"))
        assertEquals(8u, selectedConcurrentPreset("8"))
    }

    @Test
    fun concurrentZeroIsUncapped() {
        assertEquals(true, isConcurrentUncapped("0"))
        assertEquals(true, isConcurrentUncapped(" 0 "))
        assertNull(selectedConcurrentPreset("0"))
    }

    @Test
    fun concurrentCustomNumberSelectsNone() {
        assertNull(selectedConcurrentPreset("3"))
        assertNull(selectedConcurrentPreset(""))
        assertNull(selectedConcurrentPreset("abc"))
        assertEquals(false, isConcurrentUncapped(""))
        assertEquals(false, isConcurrentUncapped("abc"))
    }

    @Test
    fun countdownFractionFollowsTheWait() {
        assertEquals(0.0, countdownFraction(null, 2000L, 1500L), 0.0)
        assertEquals(0.0, countdownFraction(1000L, 2000L, 1000L), 0.0)
        assertEquals(0.5, countdownFraction(1000L, 2000L, 1500L), 1e-9)
        assertEquals(1.0, countdownFraction(1000L, 2000L, 3000L), 0.0)
        assertEquals(1.0, countdownFraction(1000L, 1000L, 1000L), 0.0)
        assertEquals(1.0, countdownFraction(2000L, 1000L, 2500L), 0.0)
    }

    @Test
    fun slotGaugeBoundsTheTiles() {
        assertEquals(4, slotGaugeDrawn(4))
        assertEquals(1, slotGaugeDrawn(0))
        assertEquals(1, slotGaugeDrawn(-3))
        assertEquals(SLOT_GAUGE_MAX_TILES, slotGaugeDrawn(100000))
        assertEquals("No limit on jobs at once", slotGaugeLabel(0, 0, true))
        assertEquals("1 of 4 slots busy", slotGaugeLabel(1, 4, false))
    }

    @Test
    fun saveStateLabelsMatchAppleCopy() {
        assertNull(saveStateLabel(FieldSaveState.Idle))
        assertEquals("Unsaved", saveStateLabel(FieldSaveState.Dirty))
        assertEquals("Saving", saveStateLabel(FieldSaveState.Saving))
        assertEquals("Saved", saveStateLabel(FieldSaveState.Saved))
        assertEquals("Not saved", saveStateLabel(FieldSaveState.Failed))
    }

    @Test
    fun saveBarShowsActionsOnlyWhenUnwritten() {
        assertEquals(false, saveBarShowsActions(FieldSaveState.Idle))
        assertEquals(true, saveBarShowsActions(FieldSaveState.Dirty))
        assertEquals(false, saveBarShowsActions(FieldSaveState.Saving))
        assertEquals(false, saveBarShowsActions(FieldSaveState.Saved))
        assertEquals(true, saveBarShowsActions(FieldSaveState.Failed))
    }

    @Test
    fun tierKindsMatchAppleBadges() {
        assertEquals(TierKind.Crown, tierKind("legend"))
        assertEquals(TierKind.Crown, tierKind("Legend"))
        assertEquals(TierKind.Shield, tierKind("patron"))
        assertEquals(TierKind.Star, tierKind("supporter"))
        assertEquals(TierKind.None, tierKind("free"))
        assertEquals(TierKind.None, tierKind(""))
        assertEquals(TierKind.Seal, tierKind("enterprise"))
    }

    @Test
    fun avatarInitialsMatchApple() {
        // The first letters of the first two words, uppercased, like the
        // Apple `Avatar.initials`: one word gives one letter, blank gives nil.
        assertEquals("GY", avatarInitials("Gyorgy Yosh"))
        assertEquals("G", avatarInitials("gyorgy"))
        assertEquals("GY", avatarInitials("  gyorgy   yosh  "))
        assertNull(avatarInitials(""))
        assertNull(avatarInitials("   "))
        assertNull(avatarInitials(null))
    }

    @Test
    fun scheduleRingFiresLikeApple() {
        for (day in 0 until 7) {
            assertEquals(true, scheduleFires("daily", 0, 0, day))
        }
        for (day in 0 until 7) {
            assertEquals(day < 5, scheduleFires("weekdays", 0, 0, day))
        }
        // Weekly prefers the bitset when it carries days.
        assertEquals(true, scheduleFires("weekly", 0b00011111, 6, 0))
        assertEquals(false, scheduleFires("weekly", 0b00011111, 6, 5))
        // Zero bitset falls back to the single weekday.
        assertEquals(true, scheduleFires("weekly", 0, 2, 2))
        assertEquals(false, scheduleFires("weekly", 0, 2, 3))
        assertEquals(true, scheduleFires("custom", 0b00001010, 0, 1))
        assertEquals(false, scheduleFires("custom", 0b00001010, 0, 2))
        assertEquals(false, scheduleFires("once", 0, 0, 0))
        assertEquals(false, scheduleFires("interval", 0, 0, 0))
    }
}
