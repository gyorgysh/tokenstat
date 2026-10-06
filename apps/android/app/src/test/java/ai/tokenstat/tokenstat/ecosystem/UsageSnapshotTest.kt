// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ecosystem

import java.time.LocalDate
import org.junit.Assert.*
import org.junit.Test
import kotlinx.serialization.json.*

class UsageSnapshotTest {
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
}
