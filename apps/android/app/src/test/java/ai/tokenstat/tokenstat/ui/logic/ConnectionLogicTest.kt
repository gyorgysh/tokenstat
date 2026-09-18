// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.logic

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class ConnectionLogicTest {
    private val now = 1_700_000_000_000L

    @Test
    fun a_method_that_never_leaves_the_device_is_on_no_plane() {
        assertNull(NetworkPlane.of("workspace.list"))
        assertNull(NetworkPlane.of("pricing.refresh"))
        assertEquals(NetworkPlane.PEER, NetworkPlane.of("remote.call"))
        assertEquals(NetworkPlane.ACCOUNT, NetworkPlane.of("account.status"))
        assertEquals(NetworkPlane.ACCOUNT, NetworkPlane.of("sync"))
        // Signing out clears this device's login on its own, so it must not
        // be refused while offline nor counted as evidence about the network.
        assertNull(NetworkPlane.of("account.logout"))
        assertNull(NetworkPlane.of("account.cancelLogin"))
    }

    @Test
    fun codes_beat_sentences_and_an_unknown_phrase_moves_nothing() {
        assertEquals(NetworkFailureKind.OFFLINE, NetworkClassifier.kind("offline", ""))
        assertEquals(NetworkFailureKind.PEER_ABSENT, NetworkClassifier.kind("no_such_peer", ""))
        assertEquals(NetworkFailureKind.ACCOUNT, NetworkClassifier.kind("not_on_this_plan", ""))
        assertEquals(
            NetworkFailureKind.PEER_ABSENT,
            NetworkClassifier.kind("", "that machine is not on the tunnel"),
        )
        assertEquals(
            NetworkFailureKind.OTHER,
            NetworkClassifier.kind("", "no such file or directory"),
        )
        assertFalse(NetworkFailureKind.OTHER.isNetwork)
        assertFalse(NetworkFailureKind.ACCOUNT.isNetwork)
    }

    @Test
    fun one_failure_is_a_request_and_two_are_a_state() {
        val tracker = ConnectionTracker()
        tracker.setPath(PathStatus.ONLINE)
        tracker.note(NetworkPlane.ACCOUNT, null, NetworkFailureKind.SERVICE, now)
        assertTrue(tracker.ui().ok)
        tracker.note(NetworkPlane.ACCOUNT, null, NetworkFailureKind.SERVICE, now)
        assertEquals("No connection", tracker.ui().title)
        tracker.note(NetworkPlane.ACCOUNT, null, null, now)
        assertTrue(tracker.ui().ok)
    }

    @Test
    fun a_machine_nobody_has_seen_working_is_off_rather_than_unreachable() {
        val tracker = ConnectionTracker()
        tracker.setPath(PathStatus.ONLINE)
        repeat(4) { tracker.note(NetworkPlane.PEER, "studio", NetworkFailureKind.PEER_ABSENT, now) }
        assertTrue(tracker.ui().ok)
        tracker.note(NetworkPlane.PEER, "studio", null, now)
        repeat(2) { tracker.note(NetworkPlane.PEER, "studio", NetworkFailureKind.PEER_ABSENT, now) }
        assertFalse(tracker.ui().ok)
    }

    @Test
    fun one_machine_failing_does_not_speak_for_another() {
        val tracker = ConnectionTracker()
        tracker.setPath(PathStatus.ONLINE)
        tracker.setPeerNames(mapOf("STUDIO" to "Studio", "laptop" to "Laptop"))
        tracker.note(NetworkPlane.PEER, "studio", null, now)
        tracker.note(NetworkPlane.PEER, "laptop", null, now)
        tracker.note(NetworkPlane.PEER, "studio", NetworkFailureKind.PEER_ABSENT, now)
        tracker.note(NetworkPlane.PEER, "laptop", null, now)
        tracker.note(NetworkPlane.PEER, "studio", NetworkFailureKind.PEER_ABSENT, now)
        val ui = tracker.ui()
        assertEquals("Studio unreachable", ui.title)
        assertFalse(ui.down)
        assertFalse(ui.offline)
    }

    @Test
    fun a_peer_failure_never_blames_the_service() {
        val tracker = ConnectionTracker()
        tracker.setPath(PathStatus.ONLINE)
        tracker.note(NetworkPlane.PEER, "studio", null, now)
        repeat(3) { tracker.note(NetworkPlane.PEER, "studio", NetworkFailureKind.TIMED_OUT, now) }
        assertFalse(tracker.ui().service)
    }

    @Test
    fun no_network_at_all_is_offline_without_waiting_for_a_call() {
        val tracker = ConnectionTracker()
        tracker.setPath(PathStatus.OFFLINE)
        assertTrue(tracker.offline)
        val ui = tracker.ui()
        assertEquals("Offline", ui.title)
        assertTrue(ui.down)
    }

    @Test
    fun an_unvalidated_network_waits_for_the_app_to_agree() {
        val tracker = ConnectionTracker()
        // A network that blocks the platform's own probe still carries
        // traffic, so this alone must not strand anybody behind an offline
        // card.
        tracker.setPath(PathStatus.UNVALIDATED)
        assertFalse(tracker.offline)
        tracker.note(NetworkPlane.ACCOUNT, null, NetworkFailureKind.SERVICE, now)
        assertFalse(tracker.offline)
        tracker.note(NetworkPlane.ACCOUNT, null, NetworkFailureKind.SERVICE, now)
        assertTrue(tracker.offline)
        assertEquals("Offline", tracker.ui().title)
    }

    @Test
    fun the_core_saying_offline_twice_is_evidence_of_its_own() {
        val tracker = ConnectionTracker()
        tracker.setPath(PathStatus.ONLINE)
        tracker.note(NetworkPlane.PEER, "studio", NetworkFailureKind.OFFLINE, now)
        assertFalse(tracker.offline)
        tracker.note(NetworkPlane.PEER, "studio", NetworkFailureKind.OFFLINE, now)
        assertTrue(tracker.offline)
        // A path that came back clears evidence about a network that is gone.
        tracker.setPath(PathStatus.ONLINE)
        assertFalse(tracker.offline)
    }

    @Test
    fun try_now_forgets_the_counters_but_keeps_what_each_machine_proved() {
        val tracker = ConnectionTracker()
        tracker.setPath(PathStatus.ONLINE)
        tracker.note(NetworkPlane.PEER, "studio", null, now)
        repeat(2) { tracker.note(NetworkPlane.PEER, "studio", NetworkFailureKind.PEER_ABSENT, now) }
        assertFalse(tracker.ui().ok)
        tracker.reset()
        assertTrue(tracker.ui().ok)
        // Still a machine this app has seen working, so two more failures
        // raise it again rather than falling back behind the never-seen rule.
        repeat(2) { tracker.note(NetworkPlane.PEER, "studio", NetworkFailureKind.PEER_ABSENT, now) }
        assertFalse(tracker.ui().ok)
    }

    @Test
    fun nothing_has_answered_yet_is_said_by_leaving_the_time_out() {
        val tracker = ConnectionTracker()
        tracker.setPath(PathStatus.OFFLINE)
        assertNull(tracker.ui().lastGoodMs)
        tracker.setPath(PathStatus.ONLINE)
        tracker.note(NetworkPlane.ACCOUNT, null, null, now)
        tracker.setPath(PathStatus.OFFLINE)
        assertEquals(now, tracker.ui().lastGoodMs!!.toLong())
    }

    @Test
    fun offline_outranks_every_other_thing_that_is_wrong() {
        val tracker = ConnectionTracker()
        tracker.setPath(PathStatus.ONLINE)
        tracker.note(NetworkPlane.PEER, "studio", null, now)
        repeat(2) { tracker.note(NetworkPlane.PEER, "studio", NetworkFailureKind.PEER_ABSENT, now) }
        repeat(2) { tracker.note(NetworkPlane.ACCOUNT, null, NetworkFailureKind.SERVICE, now) }
        tracker.setPath(PathStatus.OFFLINE)
        assertEquals("Offline", tracker.ui().title)
    }

    @Test
    fun two_unreachable_machines_are_named_in_the_plural() {
        val tracker = ConnectionTracker()
        tracker.setPath(PathStatus.ONLINE)
        listOf("studio", "laptop").forEach { peer ->
            tracker.note(NetworkPlane.PEER, peer, null, now)
            repeat(2) { tracker.note(NetworkPlane.PEER, peer, NetworkFailureKind.PEER_ABSENT, now) }
        }
        assertEquals("Computers unreachable", tracker.ui().title)
    }
}
