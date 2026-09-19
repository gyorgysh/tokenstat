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
}
