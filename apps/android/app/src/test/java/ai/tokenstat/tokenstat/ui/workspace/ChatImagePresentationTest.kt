// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.workspace

import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import org.junit.Assert.*
import org.junit.Test

class ChatImagePresentationTest {
    private fun image(id: String, call: String? = null) = ChatDisplayItem.Attachment("attachment-$id", id, "$id.png", "image/png", 100, call)
    private fun tool(id: String) = ChatDisplayItem.Tool("tool-$id", ChatToolState(id, "Read", "image.png", false, false, null, 1, 2, emptyList()))

    @Test fun consecutiveImagesShareBoundedRowsWithoutDroppingOverflow() {
        for (count in 1..20) {
            val raw = (0 until count).map { image("$it") }
            val gallery = chatImageRows(raw, raw).rows.single() as ChatDisplayItem.ImageGallery
            assertEquals(raw, gallery.images)
            assertEquals(minOf(count, 4), chatImageVisibleCount(count))
            assertEquals(if (count == 1) 1 else 2, chatImageGridColumns(count))
        }
        val text = ChatDisplayItem.Assistant("reply", "Between images", "codex")
        val file = image("document").copy(mediaType = "application/pdf")
        val raw = listOf(image("one"), text, image("two"), file, image("three"))
        val rows = chatImageRows(raw, raw).rows
        assertEquals(5, rows.size)
        assertSame(text, rows[1])
        assertSame(file, rows[3])
    }

    @Test fun onlyExplicitExactToolLinksMoveImagesBesideSteps() {
        val step = tool("read-1")
        val linked = image("linked", "read-1")
        val ordinary = image("ordinary")
        val unmatched = image("unknown", "read-2")
        val raw = listOf(step, ordinary, linked, unmatched)
        val result = chatImageRows(raw, raw)
        assertEquals(listOf(linked), result.toolImages[step.id])
        assertEquals(listOf(ordinary, unmatched), (result.rows.last() as ChatDisplayItem.ImageGallery).images)
        assertFalse(result.rows.any { it.id == linked.id })
    }

    @Test fun foldedGroupsCollectExactLinksAndExpandedStepsOwnTheirThumbnails() {
        val one = tool("one")
        val two = tool("two")
        val raw = listOf(one, two, image("a", "one"), image("b", "two"))
        for (level in ChatDetail.entries) {
            val closed = foldTranscript(raw, level, false) { false }
            val result = chatImageRows(closed, raw)
            assertEquals(2, result.toolImages.values.sumOf { it.size })
            assertFalse(result.rows.any { it is ChatDisplayItem.ImageGallery })
            assertTrue(result.toolImages.keys.all { key -> result.rows.any { it.id == key } })
            val open = chatImageRows(foldTranscript(raw, level, false) { true }, raw)
            assertEquals(listOf("tool-one", "tool-two"), open.toolImages.keys.toList())
        }
        // A tool outside the loaded page is never guessed from a nearby step.
        val orphan = image("orphan", "missing")
        assertTrue(chatImageRows(listOf(one, orphan), listOf(one, orphan)).rows.last() is ChatDisplayItem.ImageGallery)
    }

    @Test fun coalescerRetainsWireAndArchiveToolProvenance() {
        for (key in listOf("callId", "call_id")) {
            val event = buildJsonObject { put("event", buildJsonObject {
                put("kind", "attachment"); put("id", "image"); put("name", "image.png"); put("mediaType", "image/png"); put(key, "read-1")
            }) }
            assertEquals("read-1", (coalesceTranscript(listOf(event)).single() as ChatDisplayItem.Attachment).callId)
        }
    }

    @Test fun reusedCallIdsStayWithTheirOwnPrecedingTurn() {
        val first = tool("reused").copy(id = "first-tool")
        val second = tool("reused").copy(id = "second-tool")
        val firstImage = image("first", "reused")
        val secondImage = image("second", "reused")
        val missing = image("unloaded", "reused")
        val raw = listOf(first, firstImage, ChatDisplayItem.User("question", "Next"), missing, second, secondImage)
        val result = chatImageRows(raw, raw)
        assertEquals(listOf(firstImage), result.toolImages[first.id])
        assertEquals(listOf(secondImage), result.toolImages[second.id])
        assertEquals(listOf(missing), result.rows.filterIsInstance<ChatDisplayItem.ImageGallery>().single().images)
    }

    @Test fun backendNamespacesPreventCrossAgentLinksAndGalleries() {
        val claude = tool("same").copy(id = "claude-tool", state = tool("same").state.copy(backend = "claude"))
        val codex = tool("same").copy(id = "codex-tool", state = tool("same").state.copy(backend = "codex"))
        val a = image("a", "same").copy(backend = "claude")
        val b = image("b", "same").copy(backend = "codex")
        val unknown = image("unknown", "same")
        val raw = listOf(claude, codex, a, b, unknown)
        val result = chatImageRows(raw, raw)
        assertEquals(listOf(a), result.toolImages[claude.id])
        assertEquals(listOf(b), result.toolImages[codex.id])
        assertEquals(listOf(unknown), result.rows.filterIsInstance<ChatDisplayItem.ImageGallery>().single().images)
        val ordinary = listOf(a.copy(callId = null), b.copy(callId = null))
        assertEquals(2, chatImageRows(ordinary, ordinary).rows.size)
        val aroundLinked = listOf(codex, a.copy(callId = null), b, a.copy(id = "later-a", attachmentId = "later-a", callId = null))
        assertEquals(2, chatImageRows(aroundLinked, aroundLinked).rows.filterIsInstance<ChatDisplayItem.ImageGallery>().size)
    }

    @Test fun coalescerKeepsSameNamedToolsAndMergedEditsInTheirBackendNamespace() {
        fun event(backend: String, kind: String, verb: String = "Read") = buildJsonObject {
            put("backend", backend)
            put("event", buildJsonObject { put("kind", kind); put("callId", "same"); put("verb", verb); put("target", "image.png"); put("detail", backend); put("ok", true) })
        }
        val rows = coalesceTranscript(listOf(event("claude", "toolStart"), event("codex", "toolStart"), event("codex", "toolEnd")))
        val steps = rows.filterIsInstance<ChatDisplayItem.Tool>()
        assertTrue(steps.first().state.running)
        assertFalse(steps.last().state.running)
        assertEquals("codex", steps.last().state.detail)
        val edit = coalesceTranscript(listOf(event("claude", "toolStart", "Edit"))).filterIsInstance<ChatDisplayItem.Edit>().single()
        assertEquals("same", edit.state.callId)
        assertEquals("claude", edit.state.backend)
        val attachment = image("edit-output", "same").copy(backend = "claude")
        assertEquals(listOf(attachment), chatImageRows(listOf(edit, attachment), listOf(edit, attachment)).toolImages[edit.id])
    }

    @Test fun previewsStayBoundedAndNeverSpendRelayAllowanceAutomatically() {
        assertTrue(chatImageAutomaticPreviewAllowed(CHAT_IMAGE_PREVIEW_BYTES, "direct"))
        for (size in listOf(null, 0L, -1L, CHAT_IMAGE_PREVIEW_BYTES + 1)) assertFalse(chatImageAutomaticPreviewAllowed(size, "direct"))
        assertFalse(chatImageAutomaticPreviewAllowed(1, "relay"))
        assertFalse(chatImageAutomaticPreviewAllowed(1, null))
        assertEquals(512 to 256, chatImageDecodeSize(4096, 2048, 512))
        assertEquals(1 to 2048, chatImageDecodeSize(1, Int.MAX_VALUE, 2048))
        assertEquals(120 to 80, chatImageDecodeSize(120, 80, 512))
    }
}
