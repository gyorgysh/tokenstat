// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ecosystem

import java.time.LocalDate
import org.junit.Assert.*
import org.junit.Test
import kotlinx.serialization.json.*

class UsageSnapshotTest {
    @Test fun selectedQuotaWindowsNeverSubstituteAnotherPeriod() {
        val provider = QuotaProvider("codex", 1, listOf(QuotaWindow("5-hour", 15.0, 100),
            QuotaWindow("weekly", 48.0, 500, "general"), QuotaWindow("weekly", 95.0, null, "current model")))
        assertEquals(listOf(15.0), QuotaWindowSelection.FIVE_HOUR.windows(provider, 50).map { it.percent })
        assertEquals(listOf(48.0), QuotaWindowSelection.WEEKLY.windows(provider, 50).map { it.percent })
        assertEquals(listOf(15.0, 48.0), QuotaWindowSelection.BOTH.windows(provider, 50).map { it.percent })
        assertTrue(QuotaWindowSelection.FIVE_HOUR.windows(provider, 101).single().expired(101))
        assertEquals(48.0, QuotaWindowSelection.WEEKLY.windows(provider, 501).single().percent, 0.0)
        assertTrue(QuotaWindowSelection.WEEKLY.windows(provider, 501).single().expired(501))
        assertEquals("7d · current model", provider.windows.last().compactLabel)
        assertTrue(QuotaWindowSelection.WEEKLY.windows(provider.copy(windows = listOf(QuotaWindow("billing cycle", 50.0))), 50).isEmpty())
        assertEquals(QuotaWindowSelection.FIVE_HOUR, QuotaWindow("Gemini models · 5-hour", 5.0).kind)
        assertEquals(QuotaWindowSelection.HIGHEST, QuotaWindowSelection.fromKey("obsolete"))
    }
    private val owner = "a".repeat(64)
    private val today = LocalDate.of(2026, 10, 6)
    private fun days() = (6 downTo 0).map { UsageDay(today.minusDays(it.toLong()).toString(), 1_000_000, false) }
    @Test fun weeklyTotalsRequireSevenExactDays() {
        val snapshot = UsageSnapshot(owner, days = days())
        assertEquals(7_000_000L, snapshot.value(true, today))
        assertEquals(1_000_000L, snapshot.value(false, today))
        assertNull(snapshot.copy(days = days().drop(1)).value(true, today))
        assertNull(snapshot.copy(days = days().mapIndexed { i, day -> day.copy(locked = i == 3) }).value(true, today))
        assertNull(snapshot.value(false, today.plusDays(1)))
        assertEquals(Long.MAX_VALUE, snapshot.copy(days = days().map { it.copy(value = Long.MAX_VALUE) }).value(true, today))
    }
    @Test fun calendarUsesActualWireKeysAndCacheAge() {
        val calendar = buildJsonObject {
            put("scope", "account"); put("fetchedAtMs", 1234L); put("noticeCode", "stale")
            put("rows", JsonArray(listOf(JsonArray(days().map { day -> buildJsonObject {
                put("date", day.date); put("value", day.value); put("locked", day.locked)
            } }))))
        }
        val snapshot = UsageSnapshot.calendar(owner, calendar)!!
        assertEquals(1234L, snapshot.updatedAt)
        assertTrue(snapshot.refreshFailed)
        assertEquals(7_000_000L, snapshot.value(true, today))
        assertNull(UsageSnapshot.calendar(owner, JsonObject(calendar + ("scope" to JsonPrimitive("local")))))
        assertFalse(snapshot.copy(days = days() + days().first()).valid)
        assertFalse(snapshot.copy(days = listOf(UsageDay("2026-02-30", 0, false))).valid)
        assertFalse(snapshot.copy(owner = "account@example.test").valid)
    }
    @Test fun ownerIdentifiersAreHashedAndUnambiguous() {
        fun account(host: String, id: String) = buildJsonObject { put("signedIn", true); put("host", host); put("accountId", id) }
        assertNotEquals(UsageSnapshot.owner(account("a", "bc")), UsageSnapshot.owner(account("ab", "c")))
        assertTrue(UsageSnapshot.owner(account("https://example.test", "private"))!!.matches(Regex("[a-f0-9]{64}")))
        assertNull(UsageSnapshot.owner(buildJsonObject { put("signedIn", false) }))
        assertNull(UsageSnapshot.owner(buildJsonObject { put("signedIn", buildJsonObject {}) }))
    }
    @Test fun malformedCalendarsCannotBecomeFreshOrUnlockedUsage() {
        val cell = buildJsonObject { put("date", today.toString()); put("value", 1_000_000L); put("locked", false) }
        fun calendar(cells: List<JsonElement>, timestamp: JsonElement? = JsonPrimitive(1234L)) = buildJsonObject {
            put("scope", "account")
            if (timestamp != null) put("fetchedAtMs", timestamp)
            put("rows", JsonArray(listOf(JsonArray(cells))))
        }
        assertNotNull(UsageSnapshot.calendar(owner, calendar(listOf(JsonNull, cell))))
        assertNull(UsageSnapshot.calendar(owner, calendar(listOf(cell), null)))
        assertNull(UsageSnapshot.calendar(owner, calendar(listOf(cell), JsonPrimitive("invalid"))))
        assertNull(UsageSnapshot.calendar(owner, calendar(listOf(cell, JsonPrimitive("invalid")))))
        assertNull(UsageSnapshot.calendar(owner, calendar(listOf(JsonObject(cell + ("locked" to JsonPrimitive("invalid")))))))
        // Duplicates outside the retained 35 days must still invalidate the response.
        val old = JsonObject(cell + ("date" to JsonPrimitive(today.minusDays(40).toString())))
        val rows = (35 downTo 0).map { JsonObject(cell + ("date" to JsonPrimitive(today.minusDays(it.toLong()).toString()))) }
        assertNull(UsageSnapshot.calendar(owner, calendar(listOf(old, old) + rows)))
    }
    @Test fun logoutAndAccountSwitchRejectLateLoads() {
        val session = UsageSession()
        assertTrue(session.acceptsCachedOwner(owner))
        val a = session.verify(owner, session.epoch, fromApp = true)!!
        assertTrue(session.acceptsCachedOwner(owner))
        assertFalse(session.acceptsCachedOwner("b".repeat(64)))
        val priorCheck = session.epoch
        session.clear(block = true)
        assertFalse(session.acceptsCachedOwner(owner))
        assertFalse(session.current(a))
        assertNull(session.verify(owner, priorCheck, fromApp = false))
        assertNull(session.verify(owner, session.epoch, fromApp = false))
        val newA = session.verify(owner, session.epoch, fromApp = true)!!
        assertNotEquals(a, newA)
        val b = session.verify("b".repeat(64), session.epoch, fromApp = true)!!
        assertFalse(session.current(newA)); assertTrue(session.current(b))
        assertNull(session.verify(null, session.epoch, fromApp = true))
        assertFalse(session.acceptsCachedOwner(b.owner))
        assertFalse(session.current(b))
    }
    @Test fun quotasSupportUnknownProvidersAndRequireDatedFiniteReadings() {
        val wire = Json.parseToJsonElement("""[{"source":"future_vendor","observedAtMs":1234,"windows":[{"label":"weekly","scope":"primary","percent":104,"resetsAtMs":5000},{"label":"weekly","scope":"secondary","percent":20}]}]""")
        val unavailable = Json.parseToJsonElement("""{"source":"unavailable","observedAtMs":0,"windows":[]}""")
        assertEquals(1, QuotaProvider.parse(JsonArray(wire.jsonArray + unavailable))!!.size)
        val provider = QuotaProvider.parse(wire)!!.single()
        assertEquals("Future vendor", provider.name)
        assertEquals(1f, provider.windows.first().fraction)
        assertEquals(104.0, provider.peak(4000)!!.percent, 0.0)
        assertEquals(20.0, provider.peak(5000)!!.percent, 0.0)
        assertTrue(provider.windows.first().expired(5000))
        assertTrue(provider.stale(1_000_000))
        assertFalse(provider.copy(windows = listOf(QuotaWindow("weekly", Double.NaN))).valid)
        assertNull(QuotaProvider.parse(Json.parseToJsonElement("""[{"source":"new","windows":[]}]""")))
        assertNull(QuotaProvider.parse(JsonArray(listOf(wire.jsonArray.first(), wire.jsonArray.first()))))
        assertFalse(UsageSnapshot(owner, limits = listOf(provider, provider)).valid)
        assertFalse(provider.copy(source = "../private").valid)
        assertFalse(provider.copy(windows = List(9) { QuotaWindow("window-$it", 1.0) }).valid)
        val old = Json.decodeFromJsonElement<UsageSnapshot>(buildJsonObject { put("owner", owner) })
        assertTrue(old.valid && old.limits.isEmpty())
    }

}
