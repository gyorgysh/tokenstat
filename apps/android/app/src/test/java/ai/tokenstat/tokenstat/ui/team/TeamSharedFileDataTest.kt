// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.team

import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test
import java.util.Base64

class TeamSharedFileDataTest {
    private val bytes = "Fictional shared document".toByteArray()
    private fun reply(id: String = "file", size: JsonPrimitive = JsonPrimitive(bytes.size), data: String = Base64.getEncoder().encodeToString(bytes), media: String = "text/plain") = buildJsonObject {
        put("attachment", buildJsonObject { put("id", id); put("name", "../../fictional.txt"); put("mediaType", media); put("size", size) }); put("data", data)
    }
    @Test fun readsOnlyTheExactBoundedFileWithoutEnablingSvgDecoding() {
        val file = TeamSharedFileData.read(reply(), "file")
        assertEquals("fictional.txt", file.name); assertArrayEquals(bytes, file.bytes); assertFalse(file.raster)
        assertFalse(TeamSharedFileData.read(reply(media = "IMAGE/SVG+XML"), "file").raster)
        assertEquals("application/octet-stream", TeamSharedFileData.read(reply(media = "invalid\nvalue"), "file").mediaType)
    }
    @Test fun rejectsForeignIdsMalformedBytesAndMismatchedOrOversizedMetadata() {
        listOf(reply(id = "another-file"), reply(size = JsonPrimitive(999)), reply(size = JsonPrimitive("24")),
            reply(size = JsonPrimitive(TeamSharedFileData.MAXIMUM_BYTES + 1)), reply(data = "not base64!")).forEach {
            assertTrue(runCatching { TeamSharedFileData.read(it, "file") }.isFailure)
        }
    }
    @Test fun filenamesCannotCarryPathsDevicesOrDirectionControlsAndKeepWholeUnicode() {
        assertEquals("_CON.txt", TeamSharedFileData.safeName("C:\\fictional\\CON.txt"))
        assertEquals("shared-file", TeamSharedFileData.safeName("../.."))
        assertEquals("a.txt", TeamSharedFileData.safeName("a\u202E.txt\n"))
        val unicode = TeamSharedFileData.safeName("🙂".repeat(150))
        assertEquals(120, unicode.codePointCount(0, unicode.length))
        assertEquals("🙂".repeat(120), unicode)
    }
}
