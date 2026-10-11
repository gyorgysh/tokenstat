// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.workspace

import java.io.File
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class ChatFileTransfersTest {
    @get:Rule val temporary = TemporaryFolder()

    @Test
    fun completedUploadSurvivesRetryWhenAnotherAttachmentRefusesTheMessage() = runBlocking {
        val source = temporary.newFile("original.zip").apply { writeBytes(ByteArray(1000) { 42 }) }
        val staged = StagedAttachment(source.name, "", "application/zip", 1000, source.path)
        var starts = 0
        var finishes = 0
        var statuses = 0
        val attachment = buildJsonObject {
            put("id", "file-existing")
            put("name", source.name)
            put("size", 1000)
        }
        suspend fun call(method: String, params: JsonObject): JsonElement =
            when (method) {
                "protocol" -> buildJsonObject { put("protocolVersion", 34) }
                "chat.fileCapabilities" ->
                    buildJsonObject {
                        put("maxFileBytes", FILE_MAX)
                        put("relay", false)
                    }
                "chat.fileUploadStart" -> {
                    starts++
                    // A previous setup acknowledgement was lost after the final
                    // chunk. The host resumes it; no Android Base64 API is needed.
                    buildJsonObject {
                        put("transferId", "transfer-one")
                        put("offset", 1000)
                    }
                }
                "chat.fileUploadFinish" -> {
                    finishes++
                    attachment
                }
                "chat.fileUploadStatus" -> {
                    statuses++
                    assertEquals("transfer-one", params["transferId"]!!.jsonPrimitive.content)
                    buildJsonObject {
                        put("finished", true)
                        put("attachment", attachment)
                    }
                }
                else -> error("Unexpected request: $method")
            }
        repeat(3) {
            val returned =
                uploadChatFile(
                    staged,
                    "chat-one",
                    "account-one",
                    ::call,
                    { error("Direct transfer must not ask for relay") },
                    {},
                )
            assertEquals("file-existing", returned["id"]!!.jsonPrimitive.content)
        }
        assertEquals(1, starts)
        assertEquals(1, finishes)
        assertEquals(2, statuses)
        assertEquals(1000L, File(source.path).length())
    }
}
