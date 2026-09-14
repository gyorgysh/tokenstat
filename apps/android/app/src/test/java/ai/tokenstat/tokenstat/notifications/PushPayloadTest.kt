// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.notifications

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/// Pins the push payload shape: a fixed reason plus a machine id, never free
/// text. Mirrors `tokenstat-sync::push::Reason` wire names and the Apple
/// client's `NotificationOpen.parse` routing.
class PushPayloadTest {

    @Test
    fun knownReasonsParseFlat() {
        val delivery = PushPayload.parse(mapOf("reason" to "run.needs_input", "machine" to "abc"))
        assertEquals("run.needs_input", delivery?.reason)
        assertEquals("abc", delivery?.machine)
    }

    @Test
    fun nestedTsPayloadParses() {
        val delivery = PushPayload.parse(
            mapOf("ts" to """{"reason":"chat.finished","machine":"m1"}"""),
        )
        assertEquals("chat.finished", delivery?.reason)
        assertEquals("m1", delivery?.machine)
    }

    @Test
    fun unknownReasonIsDropped() {
        assertNull(PushPayload.parse(mapOf("reason" to "run.unknown", "machine" to "m1")))
        assertNull(PushPayload.parse(mapOf("reason" to "", "machine" to "m1")))
        assertNull(PushPayload.parse(mapOf("machine" to "m1")))
    }

    @Test
    fun freeTextTitleAndBodyAreNeverRead() {
        // A server-composed title or body must not leak into the banner: the
        // copy is composed from the reason, so these keys change nothing, and
        // a payload with only them parses to nothing.
        assertNull(PushPayload.parse(mapOf("title" to "Hi", "body" to "tap here", "route" to "x")))
        val delivery = PushPayload.parse(
            mapOf("reason" to "run.finished", "title" to "Hi", "body" to "tap here"),
        )
        assertEquals("Run finished", PushPayload.title(delivery!!.reason))
        assertEquals(
            "An agent run finished on one of your machines.",
            PushPayload.body(delivery.reason),
        )
    }

    @Test
    fun blankMachineIsAbsent() {
        assertNull(PushPayload.parse(mapOf("reason" to "test"))?.machine)
        assertNull(PushPayload.parse(mapOf("reason" to "test", "machine" to "  "))?.machine)
    }

    @Test
    fun openRoutingMatchesApple() {
        assertTrue(PushPayload.opensWork("chat.finished"))
        assertTrue(PushPayload.opensWork("chat.failed"))
        assertTrue(PushPayload.opensWork("run.needs_input"))
        assertTrue(PushPayload.waiting("run.needs_input"))
        assertFalse(PushPayload.opensWork("run.finished"))
        assertFalse(PushPayload.opensWork("run.failed"))
        assertFalse(PushPayload.opensWork("screen.access"))
        assertFalse(PushPayload.opensWork("test"))
    }

    @Test
    fun copyMatchesAppleBanners() {
        assertEquals("Waiting for you", PushPayload.title("run.needs_input"))
        assertEquals("Chat finished", PushPayload.title("chat.finished"))
        assertEquals("Chat did not finish", PushPayload.title("chat.failed"))
        assertEquals("Run finished", PushPayload.title("run.finished"))
        assertEquals("Run failed", PushPayload.title("run.failed"))
        assertEquals("Notifications are on", PushPayload.title("test"))
    }
}
