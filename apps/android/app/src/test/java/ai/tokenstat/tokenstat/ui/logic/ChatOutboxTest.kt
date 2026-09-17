// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.logic

import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/// Queued messages are somebody's own writing, so the rules that decide what
/// may be edited, resent or dropped are pinned here. Twin of the behaviour in
/// `ChatOutboxStore.swift` and `ChatQueueStrip.title`.
class ChatOutboxTest {
    private fun message(
        id: String,
        delivery: ChatDelivery = ChatDelivery.Waiting,
        revision: Long? = 7,
        whenConnected: Boolean = false,
    ) = QueuedMessage(
        id = id,
        text = "text $id",
        delivery = delivery,
        expectedRevision = revision,
        whenConnected = whenConnected,
    )

    @Test
    fun `a message the host may already have is neither editable nor resendable`() {
        assertTrue(message("a", ChatDelivery.Sending).needsReceipt)
        assertTrue(message("a", ChatDelivery.DeliveryUnknown).needsReceipt)
        assertFalse(message("a", ChatDelivery.Sending).canEdit)
        assertFalse(message("a", ChatDelivery.Failed).needsReceipt)
        assertTrue(message("a", ChatDelivery.Failed).canEdit)
        assertTrue(message("a", ChatDelivery.Waiting).canEdit)
    }

    /// The point of `accept`: the host took one message and moved the
    /// conversation on by one, so its siblings are still aimed at something
    /// that exists and do not need reviewing.
    @Test
    fun `accepting one message carries its siblings to the new revision`() {
        val items = listOf(message("a"), message("b"), message("c"))
        val rest = ChatOutboxRules.accept(items, "a", revision = 8)
        assertEquals(listOf("b", "c"), rest.map { it.id })
        assertEquals(listOf(8L, 8L), rest.map { it.expectedRevision })
    }

    /// Anything other than exactly one step means somebody else changed the
    /// conversation too, and those messages have to be looked at.
    @Test
    fun `a revision that jumped leaves the siblings where they were`() {
        val items = listOf(message("a"), message("b"))
        assertEquals(listOf(7L), ChatOutboxRules.accept(items, "a", revision = 12).map { it.expectedRevision })
        assertEquals(listOf(7L), ChatOutboxRules.accept(items, "a", revision = null).map { it.expectedRevision })
    }

    @Test
    fun `only waiting siblings written against the same revision move`() {
        val items = listOf(
            message("a"),
            message("b", ChatDelivery.NeedsReview),
            message("c", revision = 3),
            message("d"),
        )
        val rest = ChatOutboxRules.accept(items, "a", revision = 8)
        assertEquals(listOf(7L, 3L, 8L), rest.map { it.expectedRevision })
    }

    @Test
    fun `a queue is only valid with unique, non-empty, bounded ids`() {
        assertTrue(ChatOutboxRules.valid(listOf(message("a"), message("b"))))
        assertFalse(ChatOutboxRules.valid(listOf(message("a"), message("a"))))
        assertFalse(ChatOutboxRules.valid(listOf(message(""))))
        assertFalse(ChatOutboxRules.valid(listOf(message("x".repeat(257)))))
        assertFalse(ChatOutboxRules.valid((1..21).map { message("m$it") }))
    }

    @Test
    fun `reordering moves one message and leaves the rest in order`() {
        val items = listOf(message("a"), message("b"), message("c"))
        assertEquals(listOf("b", "c", "a"), ChatOutboxRules.moved(items, 0, 2).map { it.id })
        assertEquals(listOf("c", "a", "b"), ChatOutboxRules.moved(items, 2, 0).map { it.id })
        assertEquals(listOf("a", "b", "c"), ChatOutboxRules.moved(items, 1, 1).map { it.id })
        assertEquals(listOf("a", "b", "c"), ChatOutboxRules.moved(items, 0, 9).map { it.id })
    }

    /// An unconfirmed delivery outranks every other line, because it is the
    /// one state where doing nothing is the right move.
    @Test
    fun `the strip says what is actually true`() {
        val waiting = listOf(message("a"))
        assertEquals("Waiting to send after this turn", ChatOutboxRules.title(waiting, paused = false, offline = false))
        assertEquals(
            "Waiting to send after this turn · 2",
            ChatOutboxRules.title(listOf(message("a"), message("b")), paused = false, offline = false),
        )
        assertEquals(
            "Paused on this device · Choose Send now to continue",
            ChatOutboxRules.title(waiting, paused = true, offline = false),
        )
        assertEquals(
            "Delivery needs checking",
            ChatOutboxRules.title(listOf(message("a", ChatDelivery.DeliveryUnknown)), paused = false, offline = false),
        )
        assertEquals(
            "Delivery needs checking · Reconnect to review",
            ChatOutboxRules.title(listOf(message("a", ChatDelivery.Sending)), paused = false, offline = true),
        )
        assertEquals(
            "Waiting for connection · Cancel by removing the copy",
            ChatOutboxRules.title(listOf(message("a", whenConnected = true)), paused = false, offline = true),
        )
        assertEquals(
            "Review the conversation before sending",
            ChatOutboxRules.title(listOf(message("a", ChatDelivery.NeedsReview)), paused = false, offline = false),
        )
    }

    @Test
    fun `two hosts with the same conversation id keep separate queues`() {
        val one = ChatOutboxRules.key("peerA", "ws", "chat1")
        val two = ChatOutboxRules.key("peerB", "ws", "chat1")
        assertTrue(one != two)
    }

    // The store.

    @Test
    fun `an update that changes nothing writes nothing back`() = runTest {
        val store = InMemoryChatOutbox()
        store.update("k") { it.add(message("a")) }
        val same = store.update("k") { }
        assertEquals(listOf("a"), same.map { it.id })
    }

    @Test
    fun `emptying a queue removes it`() = runTest {
        val store = InMemoryChatOutbox()
        store.update("k") { it.add(message("a")) }
        store.update("k") { it.clear() }
        assertTrue(store.items("k").isEmpty())
    }

    @Test
    fun `a queue past capacity is refused and the old one survives`() = runTest {
        val store = InMemoryChatOutbox()
        store.update("k") { it.add(message("a")) }
        val failure = runCatching {
            store.update("k") { list -> (1..ChatOutboxRules.CAPACITY).forEach { list.add(message("x$it")) } }
        }.exceptionOrNull() as? ChatOutboxFailure
        assertEquals(ChatOutboxFailure.Reason.Full, failure?.reason)
        assertEquals(listOf("a"), store.items("k").map { it.id })
    }

    @Test
    fun `a duplicate id is refused`() = runTest {
        val store = InMemoryChatOutbox()
        store.update("k") { it.add(message("a")) }
        val failure = runCatching {
            store.update("k") { it.add(message("a")) }
        }.exceptionOrNull() as? ChatOutboxFailure
        assertEquals(ChatOutboxFailure.Reason.Invalid, failure?.reason)
        assertEquals(1, store.items("k").size)
    }

    /// One send per conversation at a time, so two taps cannot both deliver.
    @Test
    fun `only one delivery runs per conversation`() {
        val store = InMemoryChatOutbox()
        assertTrue(store.beginDelivery("k"))
        assertFalse(store.beginDelivery("k"))
        assertTrue(store.beginDelivery("other"))
        store.endDelivery("k")
        assertTrue(store.beginDelivery("k"))
    }

    @Test
    fun `delivery states survive their wire names`() {
        ChatDelivery.entries.forEach { assertEquals(it, ChatDelivery.of(it.wire)) }
        assertEquals(ChatDelivery.Waiting, ChatDelivery.of(null))
        assertEquals(ChatDelivery.Waiting, ChatDelivery.of("nonsense"))
    }

    /// The distinction that decides whether somebody is told to check a
    /// delivery or simply to try again.
    @Test
    fun `a request that never left the device is a refusal, not an unknown`() {
        assertFalse(ChatOutboxRules.deliveryUnknown(null, "peer is not on the tunnel"))
        assertFalse(ChatOutboxRules.deliveryUnknown(null, "no_such_peer"))
        assertFalse(ChatOutboxRules.deliveryUnknown(null, "tunnel is not connected"))
        assertFalse(ChatOutboxRules.deliveryUnknown("refused", "That was refused."))
    }

    @Test
    fun `an answer that never came back leaves delivery unknown`() {
        assertTrue(ChatOutboxRules.deliveryUnknown(null, "the request timed out"))
        assertTrue(ChatOutboxRules.deliveryUnknown("delivery_unknown", "anything"))
        assertTrue(ChatOutboxRules.deliveryUnknown(null, "deadline exceeded"))
        assertTrue(ChatOutboxRules.deliveryUnknown(null, "the answer could not be read"))
    }

    @Test
    fun `accepting a message that is not there still drops nothing else`() {
        val items = listOf(message("a"), message("b"))
        assertEquals(listOf("a", "b"), ChatOutboxRules.accept(items, "gone", revision = 8).map { it.id })
        assertNull(ChatOutboxRules.accept(items, "a", 8).firstOrNull { it.id == "a" })
    }
}
