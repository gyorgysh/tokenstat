// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.workspace

import java.io.File
import java.security.MessageDigest
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class ChatFileTransfersTest {
    @get:Rule val temporary = TemporaryFolder()

    @Test fun decliningRelayPreservesTheDownloadedPrefix() = runBlocking {
        val directory = temporary.newFolder()
        val bytes = "already downloaded prefix".toByteArray()
        fun sha(value: ByteArray) = MessageDigest.getInstance("SHA-256").digest(value).joinToString("") { "%02x".format(it.toInt() and 255) }
        val checksum = sha(bytes)
        val key = sha("owner|chat|attachment|$checksum".toByteArray())
        val cached = File(File(directory, key).apply { mkdirs() }, "archive.bin").apply { writeBytes(bytes.copyOf(7)) }
        var prompts = 0
        repeat(3) { attempt ->
            try {
                downloadChatFile(directory, "chat", if (attempt == 2) "new-attachment" else "attachment", "owner", call = { method, _ -> when (method) {
                    "protocol" -> buildJsonObject { put("protocolVersion", 34) }
                    "chat.fileCapabilities" -> buildJsonObject { put("maxFileBytes", FILE_MAX); put("relay", true); put("relayRemainingBytes", 1234) }
                    "chat.fileDownloadInfo" -> buildJsonObject { put("sha256", checksum); put("attachment", buildJsonObject { put("name", "archive.bin"); put("size", bytes.size) }) }
                    else -> throw AssertionError("Declining must not fetch a chunk: $method")
                } }, confirm = {
                    prompts++
                    assertEquals(1234L, it)
                    if (attempt == 1) throw kotlinx.coroutines.CancellationException("Dialog dismissed")
                    false
                }, progress = { error("Nothing was transferred") })
                org.junit.Assert.fail("Declined download returned a file")
            } catch (_: IllegalStateException) {}
            assertTrue("Declining or dismissing consent keeps the partial file", cached.exists())
            org.junit.Assert.assertArrayEquals(bytes.copyOf(7), cached.readBytes())
        }
        assertEquals(3, prompts)
        assertEquals("A declined new transfer creates no empty folder", 1, directory.listFiles()!!.size)
    }

    @Test fun completedCachedDownloadDoesNotAskForRelayAgain() = runBlocking {
        val directory = temporary.newFolder()
        val bytes = "a small GLB".toByteArray()
        fun sha(value: ByteArray) = MessageDigest.getInstance("SHA-256").digest(value).joinToString("") { "%02x".format(it.toInt() and 255) }
        val checksum = sha(bytes)
        val key = sha("owner|chat|attachment|$checksum".toByteArray())
        val cached = File(File(directory, key).apply { mkdirs() }, "rocket.glb").apply { writeBytes(bytes) }
        val result = downloadChatFile(directory, "chat", "attachment", "owner",
            call = { method, _ -> when (method) {
                "protocol" -> buildJsonObject { put("protocolVersion", 34) }
                "chat.fileCapabilities" -> buildJsonObject { put("maxFileBytes", FILE_MAX); put("relay", true); put("relayRemainingBytes", 1234) }
                "chat.fileDownloadInfo" -> buildJsonObject { put("sha256", checksum); put("attachment", buildJsonObject { put("name", "rocket.glb"); put("size", bytes.size) }) }
                else -> error("A completed cache entry must not request a chunk: $method")
            } },
            confirm = { error("A completed cache entry must not ask for relay allowance") }, progress = {})
        assertEquals(cached, result)
    }

    @Test
    fun automaticPreviewLimitIsCheckedAgainstTheHostDescriptorBeforeDownloading() = runBlocking {
        val calls = mutableListOf<String>()
        try {
            downloadChatFile(temporary.newFolder(), "chat", "image", "owner",
                call = { method, _ ->
                    calls.add(method)
                    when (method) {
                        "protocol" -> buildJsonObject { put("protocolVersion", 34) }
                        "chat.fileCapabilities" -> buildJsonObject { put("maxFileBytes", FILE_MAX); put("relay", false) }
                        "chat.fileDownloadInfo" -> buildJsonObject { put("attachment", buildJsonObject { put("size", CHAT_IMAGE_PREVIEW_BYTES + 1) }) }
                        else -> error("Preview must refuse before any chunk: $method")
                    }
                }, confirm = { error("Automatic previews cannot request relay allowance") }, progress = {}, byteLimit = CHAT_IMAGE_PREVIEW_BYTES)
            error("The authoritative size must enforce the preview limit")
        } catch (_: IllegalArgumentException) {
            assertTrue("chat.fileDownloadInfo" in calls)
            assertEquals(3, calls.size)
        }
    }

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
