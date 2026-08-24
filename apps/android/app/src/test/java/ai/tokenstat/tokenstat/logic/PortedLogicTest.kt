// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.logic

import ai.tokenstat.tokenstat.ui.logic.HomeGreeting
import ai.tokenstat.tokenstat.ui.logic.TunnelCopy
import ai.tokenstat.tokenstat.ui.logic.compactTokens
import ai.tokenstat.tokenstat.ui.logic.money
import org.junit.Assert.assertEquals
import org.junit.Test

/// Pins the ported pure logic to the same answers the Apple client's Swift
/// originals produce, so both platforms cannot drift apart silently.
class PortedLogicTest {

    // HomeGreeting.phrase — expected values computed from Greeting.swift's
    // pool and dayOfYear % pool.count rule.
    @Test
    fun greetingMorning() {
        assertEquals("Good morning", HomeGreeting.phrase(hour = 8, hasHistory = false, dayOfYear = 0))
    }

    @Test
    fun greetingAfternoonEveningAndNight() {
        // Day-of-year multiples of five land on the time-of-day slot itself.
        assertEquals("Good afternoon", HomeGreeting.phrase(13, false, 5))
        assertEquals("Good evening", HomeGreeting.phrase(18, false, 5))
        assertEquals("Hello", HomeGreeting.phrase(3, false, 5))
        assertEquals("Hello", HomeGreeting.phrase(23, false, 5))
    }

    @Test
    fun greetingPoolIsStablePerDay() {
        // dayOfYear 3 lands on index 3: Welcome back / Welcome slot.
        assertEquals("Welcome", HomeGreeting.phrase(8, hasHistory = false, dayOfYear = 3))
        assertEquals("Welcome back", HomeGreeting.phrase(8, hasHistory = true, dayOfYear = 3))
        // Index 4 is Back at it only with history; otherwise it repeats the
        // time-of-day phrase. Fixed length means the flip changes only this
        // returning slot.
        assertEquals("Good morning", HomeGreeting.phrase(8, hasHistory = false, dayOfYear = 4))
        assertEquals("Back at it", HomeGreeting.phrase(8, hasHistory = true, dayOfYear = 4))
    }

    @Test
    fun firstNameTakesFirstWord() {
        assertEquals("Gyorgy", HomeGreeting.firstName("Gyorgy"))
        assertEquals("Ada", HomeGreeting.firstName("Ada Lovelace"))
        assertEquals("", HomeGreeting.firstName("   "))
    }

    @Test
    fun greetingLineComposes() {
        assertEquals(
            "Good morning, Ada",
            HomeGreeting.line(name = "Ada Lovelace", hasHistory = true, hour = 8, dayOfYear = 0),
        )
    }

    // compactTokens — mirrors the Apple client's K/M/B compaction beside model
    // names.
    @Test
    fun tokenCountsCompact() {
        assertEquals("0", compactTokens(0))
        // Non-positive counts render as zero, exactly like the Swift original.
        assertEquals("0", compactTokens(null))
        assertEquals("0", compactTokens(-5))
        assertEquals("999", compactTokens(999))
        assertEquals("1.0K", compactTokens(1_000))
        assertEquals("1.6K", compactTokens(1_600))
        assertEquals("1.6M", compactTokens(1_600_000))
        assertEquals("2.0B", compactTokens(2_000_000_000))
    }

    @Test
    fun moneyFormatsMicros() {
        // Micros divide by one million before formatting; the currency symbol
        // and placement are the device locale's business.
        val formatted = money(1_500_000L)
        assert(formatted.contains("1.50") || formatted.contains("1,50")) { formatted }
    }

    // TunnelCopy — a mid-reconnect tunnel reads as waiting, not gone.
    @Test
    fun tunnelAbsentDetection() {
        assertEquals(true, TunnelCopy.isAbsent("no_such_peer for abc"))
        assertEquals(false, TunnelCopy.isAbsent("workspace not found"))
    }

    @Test
    fun tunnelWaitingCopyNamesTheHost() {
        assertEquals("Waiting for the computer to come back on the tunnel.", TunnelCopy.waiting(null))
        assertEquals("Waiting for Mac Studio to come back on the tunnel.", TunnelCopy.waiting(" Mac Studio "))
    }
}
