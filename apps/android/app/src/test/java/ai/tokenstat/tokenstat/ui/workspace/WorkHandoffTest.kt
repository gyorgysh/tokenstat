// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.workspace

import kotlinx.serialization.json.Json
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class WorkHandoffTest {
    @Test fun receivedFilesBindToTheirConversationAndDoNotUploadAgain() = runBlocking {
        val files = readSharedHandoffFiles(
            call = { method, parameters ->
                assertEquals("work.continuity.attachments", method)
                assertEquals("""{"workspaceId":"w","conversationId":"c","attachmentIds":["f"]}""", parameters.toString())
                Json.parseToJsonElement("""[{"id":"f","name":"proof.png","size":40,"mediaType":"image/png"}]""")
            },
            workspace = "w",
            conversation = "c",
            owner = "target",
            ids = listOf("f"),
        )
        val file = files.single()
        assertEquals(StagedHostFile("f", "target"), file.hostFile)
        assertNull(file.filePath)
        assertEquals(40, file.bytes)
        val reused = uploadChatFile(file, "c", "target", call = { _, _ -> error("must not upload") },
            confirm = { error("must not bill relay") }, progress = { error("must not report progress") })
        assertEquals("f", reused.str("id"))
        val wrongOwner = runCatching {
            uploadChatFile(file, "different", "other", call = { _, _ -> error("must not upload") },
                confirm = { error("must not bill relay") }, progress = { error("must not report progress") })
        }.exceptionOrNull()
        assertEquals(true, wrongOwner is IllegalStateException)
    }

    @Test fun readsWhatAnotherDeviceShared() {
        val record = parseHandoff(
            Json.parseToJsonElement(
                """{"revision":3,"requestId":"r","deviceId":"d","deviceName":"MacBook","updatedAtMs":12,
                   "draft":{"text":"words","attachmentIds":["f"]},
                   "anchor":{"eventId":"text-s40","fraction":2500,"followsLatest":false}}""",
            ),
        )!!
        assertEquals(HandoffDraft("words", listOf("f")), record.draft)
        assertEquals(HandoffAnchor("text-s40", 2500, false), record.anchor)
        assertNull(parseHandoff(null))
        assertNull(parseHandoff(Json.parseToJsonElement("null")))
    }

    @Test fun asksForNothingItDoesNotShare() {
        assertEquals(
            """{"workspaceId":"w","conversationId":"c","handoff":{"requestId":"r","expectedRevision":2,"deviceName":"Pixel"}}""",
            HandoffRequest("r", 2, "Pixel", null, null).json("w", "c").toString(),
        )
    }

    @Test fun theReadersPlaceIsARowTheHostNamed() {
        val rows = listOf("0-3", "g:tool-s10", "text-s20", "text-s30")
        val screen = listOf(RowSpan("earlier", -90, 40), RowSpan("0-3", -50, 45), RowSpan("g:tool-s10", -50, 200), RowSpan("text-s20", 150, 900))
        assertEquals(HandoffAnchor("tool-s10", 2500, false), shareAnchor(screen, rows, atEnd = false))
        assertEquals(HandoffAnchor("text-s30", 0, true), shareAnchor(screen, rows, atEnd = true))
        assertNull(shareAnchor(listOf(RowSpan("0-3", 0, 40)), rows, atEnd = false))
    }

    @Test fun aSharedPlaceIsFoundWhenRowsAreFoldedOrJoined() {
        val rows = listOf("user-s5", "g:tool-s10", "text-s20", "user-s90")
        assertEquals(2, anchorRow("text-s20", rows))
        assertEquals(1, anchorRow("tool-s10", rows))
        assertEquals(1, anchorRow("tool-s14", rows))
        assertEquals(2, anchorRow("text-s44", rows))
        assertNull(anchorRow("text-s2", rows))
        assertNull(anchorRow("nonsense", rows))
    }
}
