// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.workspace

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.*
import org.junit.Test

class ChatHistoryWindowTest {
    private fun json(value: String) = Json.parseToJsonElement(value).jsonObject

    @Test fun olderPagesPreserveLiveTailAndResetRejectsStaleReplies() {
        val history = ChatHistoryWindow()
        history.page(json("""{"events":[{"id":"recent"}],"nextOffset":900,"tailCursor":"tail-a","cursor":"older-a","hasEarlier":true}"""), true)
        val generation = history.generation
        assertEquals(1, history.events.size)
        assertTrue(history.hasEarlier)
        assertTrue(history.tail(json("""{"events":[{"id":"live"}],"nextOffset":1000,"tailCursor":"tail-b"}"""), generation))
        history.page(json("""{"events":[{"id":"oldest"}],"nextOffset":500,"cursor":null,"hasEarlier":false}"""))
        assertEquals(listOf("oldest", "recent", "live"), history.events.map { it["id"]!!.jsonPrimitive.content })
        assertEquals(1000L, history.offset)
        assertEquals("tail-b", history.tailCursor)
        assertFalse(history.hasEarlier)
        val unchanged = history.events
        assertTrue(history.tail(json("""{"events":[],"nextOffset":1000,"tailCursor":"tail-b"}"""), generation))
        assertSame(unchanged, history.events)
        history.page(json("""{"reset":true,"events":[{"id":"replacement"}],"nextOffset":80,"tailCursor":"new"}"""))
        assertFalse(history.tail(json("""{"events":[{"id":"stale"}],"nextOffset":1100}"""), generation))
        assertEquals(1, history.events.size)
        assertEquals(80L, history.offset)
        assertFalse(history.tail(json("""{"reset":true,"events":[],"nextOffset":0}"""), history.generation))
    }
}
