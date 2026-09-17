// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.heatmap

import ai.tokenstat.tokenstat.ui.theme.DarkColors
import ai.tokenstat.tokenstat.ui.theme.LightColors
import androidx.compose.ui.graphics.Color
import java.text.NumberFormat
import java.time.LocalDate
import java.util.Locale
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.add
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class HeatmapTest {
    @Test
    fun shortDateDropsThisYear() {
        val today = LocalDate.of(2026, 9, 16)
        assertEquals("11 August", shortDate("2026-08-11", today))
        assertEquals("11 August 2025", shortDate("2025-08-11", today))
        assertEquals("not a date", shortDate("not a date", today))
    }

    @Test
    fun spokenDateKeepsTheYear() {
        assertEquals("11 August 2026", spokenDate("2026-08-11"))
        assertEquals("2026-13-99", spokenDate("2026-13-99"))
    }

    @Test
    fun freshnessMatchesApplePhrasing() {
        val now = 1_700_000_000_000L
        assertEquals(
            "updated 1 hour ago" to false,
            calendarFreshness(now - 3_600_000, null, now),
        )
        assertEquals(
            "stale, last updated 2 days ago" to true,
            calendarFreshness(now - 2 * 86_400_000, "stale", now),
        )
        assertNull(calendarFreshness(null, null, now))
        assertNull(calendarFreshness(0, null, now))
    }

    @Test
    fun heatRampMatchesIosStops() {
        // `Theme.heat`, stop for stop from Sources/Design/Theme.swift, so a
        // busy week on the phone is the same colour as on the site.
        assertEquals(
            listOf(
                Color(0xFFECEAF2),
                Color(0xFFD6C9FF),
                Color(0xFFA98CFF),
                Color(0xFF7C4DFF),
                Color(0xFFC026D3),
            ),
            LightColors.heat,
        )
        assertEquals(
            listOf(
                Color(0xFF191627),
                Color(0xFF3B2A6B),
                Color(0xFF5F3FB8),
                Color(0xFF8B5CF6),
                Color(0xFFE879F9),
            ),
            DarkColors.heat,
        )
    }

    @Test
    fun phoneHeatOverridesOnlyTheQuietStep() {
        // `PhoneHeatmap.heatPalette`: only step zero changes, because the
        // shared quiet step all but vanishes on a white card at arm's length.
        val light = phoneHeat(LightColors)
        assertEquals(Color(0xFFDEDAEA), light[0])
        assertEquals(LightColors.heat.drop(1), light.drop(1))
        val dark = phoneHeat(DarkColors)
        assertEquals(Color(0xFF221E36), dark[0])
        assertEquals(DarkColors.heat.drop(1), dark.drop(1))
    }

    @Test
    fun dayDetailParamsUseTheAccountGrid() {
        // `Bridge.dayDetail(date:scope: "account")`: the grid the day was
        // tapped out of is the account's.
        val params = dayDetailParams("2026-08-11")
        assertEquals("2026-08-11", params["date"]?.jsonPrimitive?.content)
        assertEquals(53, params["weeks"]?.jsonPrimitive?.int)
        assertEquals("account", params["scope"]?.jsonPrimitive?.content)
    }

    @Test
    fun groupedCountGroupsLikeSwiftFormatted() {
        assertEquals("0", groupedCount(0))
        assertEquals("532", groupedCount(532))
        val expected = NumberFormat.getIntegerInstance(Locale.getDefault()).format(1_214_203)
        assertEquals(expected, groupedCount(1_214_203))
    }

    @Test
    fun totalsLineKeepsEventsPlainAndGroupsTokens() {
        val grouped = NumberFormat.getIntegerInstance(Locale.getDefault()).format(1_214_203)
        assertEquals("12 events, $grouped tokens", dayTotalsLine(12, 1_214_203))
        assertEquals("0 events, 0 tokens", dayTotalsLine(0, 0))
    }

    @Test
    fun fallbackQuartilesMatchCoreRanks() {
        // Nearest-rank, rank for rank with `Scale::from_days`: the ceiling
        // of n*q, one-indexed into the ascending values.
        val scale = heatFallbackScale((1L..8L).toList())
        assertTrue(scale is HeatFallbackScale.Quartiles)
        assertEquals(listOf(2L, 4L, 6L), (scale as HeatFallbackScale.Quartiles).breaks)
        assertEquals(listOf(1, 1, 2, 2, 3, 3, 4, 4), (1L..8L).map { fallbackLevel(it, scale) })
        assertEquals(0, fallbackLevel(0, scale))
    }

    @Test
    fun fallbackOutlierCannotFlattenTheGrid() {
        // The reported shape: $0.29 to $510 days with one $960 outlier. An
        // outlier sets the ceiling under value/max and the whole grid lands
        // on one shade; quartile breaks spread all four.
        val values = listOf(290_000L, 5_000_000L, 50_000_000L, 120_000_000L, 200_000_000L, 350_000_000L, 510_000_000L, 960_000_000L)
        val scale = heatFallbackScale(values)
        assertTrue(scale is HeatFallbackScale.Quartiles)
        assertEquals(
            listOf(5_000_000L, 120_000_000L, 350_000_000L),
            (scale as HeatFallbackScale.Quartiles).breaks,
        )
        val levels = values.map { fallbackLevel(it, scale) }
        assertEquals(listOf(1, 1, 2, 2, 3, 3, 4, 4), levels)
        assertEquals(setOf(1, 2, 3, 4), levels.toSet())
        assertEquals(4, fallbackLevel(960_000_000L, scale))
        // Quiet days stay quiet and never move the breaks.
        val withQuiet = heatFallbackScale(values + listOf(0L, 0L, 0L))
        assertEquals(scale, withQuiet)
        assertEquals(0, fallbackLevel(0, scale))
    }

    @Test
    fun fallbackUnderFourActiveDaysShadesByMaxRatio() {
        // Fewer than four active days have no quartiles to take: the shade
        // is the value's share of the largest day.
        val scale = heatFallbackScale(listOf(10L, 20L, 30L))
        assertEquals(HeatFallbackScale.MaxRatio(30L), scale)
        assertEquals(2, fallbackLevel(10, scale))
        assertEquals(3, fallbackLevel(20, scale))
        assertEquals(4, fallbackLevel(30, scale))
        assertEquals(0, fallbackLevel(0, scale))
        val lone = heatFallbackScale(listOf(0L, 50L, 0L))
        assertEquals(HeatFallbackScale.MaxRatio(50L), lone)
        assertEquals(4, fallbackLevel(50, lone))
    }

    @Test
    fun fallbackEmptyGridIsQuiet() {
        assertEquals(HeatFallbackScale.Empty, heatFallbackScale(emptyList()))
        assertEquals(HeatFallbackScale.Empty, heatFallbackScale(listOf(0L, 0L)))
        assertEquals(0, fallbackLevel(0, HeatFallbackScale.Empty))
    }

    @Test
    fun dayPartRowsSkipsAnythingThatIsNotARow() {
        assertTrue(dayPartRows(null).isEmpty())
        assertTrue(dayPartRows(buildJsonObject {}).isEmpty())
        val detail = buildJsonObject {
            put(
                "rows",
                buildJsonArray {
                    add(buildJsonObject { put("model", "m1") })
                    add(JsonPrimitive("junk"))
                    add(buildJsonObject { put("model", "m2") })
                },
            )
        }
        assertEquals(listOf("m1", "m2"), dayPartRows(detail).map { it["model"]?.jsonPrimitive?.content })
    }
}
