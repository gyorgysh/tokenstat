// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.logic

import java.io.File
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.test.runTest
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class FileChatOutboxTest {
    @get:Rule val temporary = TemporaryFolder()

    @Test fun `separate store instances preserve concurrent queue changes`() = runTest {
        val directory = temporary.newFolder()
        val a = FileChatOutbox(directory)
        val b = FileChatOutbox(directory)
        (0 until 30).map { i -> async {
            (if (i % 2 == 0) a else b).update("chat-$i") { it.add(QueuedMessage("id-$i", "draft-$i")) }
        } }.awaitAll()
        repeat(30) { i -> assertEquals("draft-$i", a.items("chat-$i").single().text) }
    }

    @Test fun `corrupt sibling queue refuses a write and keeps original bytes`() = runTest {
        val directory = temporary.newFolder()
        val file = File(directory, "outbox.v1.json")
        val original = """{"version":"1","queues":{"good":[{"id":"one","text":"keep me"}],"bad":[{"text":"missing id"}]}}"""
        file.writeText(original)
        val store = FileChatOutbox(directory)
        try {
            store.update("good") { it.add(QueuedMessage("two", "new")) }
            fail("Damaged drafts must not be discarded")
        } catch (error: ChatOutboxFailure) { assertEquals(ChatOutboxFailure.Reason.Unavailable, error.reason) }
        assertEquals(original, file.readText())
    }

    @Test fun `failed size check preserves the existing draft`() = runTest {
        val directory = temporary.newFolder()
        val store = FileChatOutbox(directory, byteLimit = 1024)
        store.update("chat") { it.add(QueuedMessage("one", "original")) }
        try {
            store.update("chat") { it[0] = it[0].copy(text = "x".repeat(2048)) }
            fail("Expected refusal")
        } catch (error: ChatOutboxFailure) { assertEquals(ChatOutboxFailure.Reason.Full, error.reason) }
        assertEquals("original", FileChatOutbox(directory).items("chat").single().text)
    }

    @Test fun `delivery exclusivity is shared between store instances`() {
        val directory = temporary.newFolder()
        val a = FileChatOutbox(directory)
        val b = FileChatOutbox(directory)
        assertTrue(a.beginDelivery("chat"))
        try { assertFalse(b.beginDelivery("chat")) } finally { a.endDelivery("chat") }
        assertTrue(b.beginDelivery("chat"))
        b.endDelivery("chat")
    }

    @Test fun `two account recovery attempts claim legacy writing exactly once`() = runTest {
        val directory = temporary.newFolder()
        val a = FileChatOutbox(directory)
        val b = FileChatOutbox(directory)
        val reviewed = listOf(QueuedMessage("saved", "writing", whenConnected = true))
        a.update("legacy") { it.addAll(reviewed) }
        val attempts = listOf(
            async { runCatching { a.recoverLegacy("legacy", "account-a", reviewed) } },
            async { runCatching { b.recoverLegacy("legacy", "account-b", reviewed) } },
        ).awaitAll()
        assertEquals(1, attempts.count { it.isSuccess })
        assertEquals(ChatOutboxFailure.Reason.Conflict, (attempts.single { it.isFailure }.exceptionOrNull() as ChatOutboxFailure).reason)
        val reopened = FileChatOutbox(directory)
        assertTrue(reopened.items("legacy").isEmpty())
        val owned = reopened.items("account-a") + reopened.items("account-b")
        assertEquals(listOf(reviewed.single().copy(delivery = ChatDelivery.NeedsReview, whenConnected = false)), owned)
    }

    @Test fun `recovered unknown delivery metadata survives reopening without resending permission`() = runTest {
        val directory = temporary.newFolder()
        val store = FileChatOutbox(directory)
        val sent = QueuedMessage("sent", "writing", listOf(QueuedAttachment("attachment", "notes.txt")),
            ChatDelivery.Sending, firstAttemptAtMs = 100, attemptedAtMs = 200, expectedRevision = 7, whenConnected = true)
        store.update("legacy") { it.add(sent) }
        store.recoverLegacy("legacy", "scoped", listOf(sent))
        val reopened = FileChatOutbox(directory)
        assertTrue(reopened.items("legacy").isEmpty())
        val recovered = reopened.items("scoped").single()
        assertEquals(sent.copy(delivery = ChatDelivery.DeliveryUnknown, whenConnected = false), recovered)
        assertTrue(recovered.needsReceipt)
        assertFalse(recovered.canEdit)
    }

    @Test fun `recovery write refusal preserves the source destination and exact file bytes`() = runTest {
        val directory = temporary.newFolder()
        val store = FileChatOutbox(directory, byteLimit = 512)
        val reviewed = listOf(QueuedMessage("saved", "writing"))
        val key = "project.v1|" + "scope".repeat(120) + "|conversation|4:chat"
        store.update("legacy") { it.addAll(reviewed) }
        val file = File(directory, "outbox.v1.json")
        val original = file.readText()
        val failure = runCatching { store.recoverLegacy("legacy", key, reviewed) }.exceptionOrNull() as? ChatOutboxFailure
        assertEquals(ChatOutboxFailure.Reason.Full, failure?.reason)
        assertEquals(original, file.readText())
        assertEquals(reviewed, store.items("legacy"))
        assertTrue(store.items(key).isEmpty())
    }
}
