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

    @Test fun inlineDraftsKeepTheirMetadataAndRequireConsentOnlyOnRelay() = runBlocking {
        val staged = StagedAttachment("image.png", "aGVsbG8=", "image/png", 5, null)
        for (route in listOf("direct", "relay", "declined", "failed")) {
            var requests = 0
            var prompts = 0
            try {
                val result = uploadChatFile(staged, "chat", "owner", { method, params ->
                    assertEquals("chat.attach", method)
                    assertEquals("image.png", params["name"]!!.jsonPrimitive.content)
                    assertEquals("image/png", params["mediaType"]!!.jsonPrimitive.content)
                    assertEquals(staged.data, params["data"]!!.jsonPrimitive.content)
                    requests++
                    if (route == "failed") throw ai.tokenstat.tokenstat.core.CoreFailure("disconnected", "Offline")
                    if (route != "direct" && params["allowRelay"]?.jsonPrimitive?.content != "true")
                        throw ai.tokenstat.tokenstat.core.CoreFailure("relay_consent_required", "Relay")
                    buildJsonObject { put("id", "uploaded") }
                }, {
                    prompts++
                    assertEquals(null, it)
                    route == "relay"
                }, {})
                assertTrue(route == "direct" || route == "relay")
                assertEquals("uploaded", result["id"]!!.jsonPrimitive.content)
            } catch (error: ai.tokenstat.tokenstat.core.CoreFailure) {
                assertTrue(route == "declined" || route == "failed")
                assertEquals(if (route == "declined") "relay_consent_required" else "disconnected", error.code)
            }
            assertEquals(if (route == "relay") 2 else 1, requests)
            assertEquals(if (route == "relay" || route == "declined") 1 else 0, prompts)
        }
    }

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
    fun relayRetryOnlyAsksWhenTheSavedUploadStillNeedsBytes() = runBlocking {
        val source = temporary.newFile("resume.zip").apply { writeBytes(ByteArray(1000) { 42 }) }
        val staged = StagedAttachment(source.name, "", "application/zip", 1000, source.path)
        var relay = false
        var finishFails = true
        var cancelStatus = false
        var cap = FILE_MAX
        var offset = 1000L
        var prompts = 0
        var starts = 0
        var finishes = 0
        suspend fun call(method: String, params: JsonObject): JsonElement = when (method) {
            "protocol" -> buildJsonObject { put("protocolVersion", 34) }
            "chat.fileCapabilities" -> buildJsonObject { put("maxFileBytes", cap); put("relay", relay) }
            "chat.fileUploadStart" -> {
                starts++
                buildJsonObject { put("transferId", "resume"); put("offset", 1000) }
            }
            "chat.fileUploadStatus" -> {
                assertEquals("resume", params["transferId"]!!.jsonPrimitive.content)
                if (cancelStatus) throw kotlinx.coroutines.CancellationException("Navigation changed")
                buildJsonObject { put("transferId", "resume"); put("offset", offset) }
            }
            "chat.fileUploadFinish" -> {
                finishes++
                if (finishFails) throw ai.tokenstat.tokenstat.core.CoreFailure("disconnected", "Connection closed")
                buildJsonObject { put("id", "finished"); put("name", source.name) }
            }
            else -> error("No file data or cancellation request was expected: $method")
        }
        try {
            uploadChatFile(staged, "chat", "owner", ::call, { error("Direct") }, {})
            error("Fixture must leave an unfinished receipt")
        } catch (_: ai.tokenstat.tokenstat.core.CoreFailure) {}
        val receipt = source.parentFile!!.listFiles()!!.single { it.name.endsWith(".upload") }
        val saved = receipt.readText()
        relay = true
        finishFails = false
        cancelStatus = true
        try {
            uploadChatFile(staged, "chat", "owner", ::call,
                { error("A cancelled status read must not ask for consent") }, {})
            error("Cancelled status read continued")
        } catch (_: kotlinx.coroutines.CancellationException) {}
        assertEquals(1, starts)
        assertEquals(saved, receipt.readText())
        cancelStatus = false
        cap = 500
        val result = uploadChatFile(staged, "chat", "owner", ::call,
            { error("Finishing already uploaded bytes needs no consent") }, {})
        assertEquals("finished", result["id"]!!.jsonPrimitive.content)

        // A host can retain only a prefix after an interrupted upload. Refusing
        // or dismissing its relay prompt must keep that upload available.
        offset = 500
        cap = FILE_MAX
        repeat(2) { attempt ->
            try {
                uploadChatFile(staged, "chat", "owner", ::call, {
                    prompts++
                    if (attempt == 1) throw kotlinx.coroutines.CancellationException("Dismissed")
                    false
                }, {})
                error("Declined upload continued")
            } catch (_: IllegalStateException) {}
            assertEquals(saved, receipt.readText())
            assertEquals(1000L, source.length())
        }
        assertEquals(2, prompts)
        assertEquals(1, starts)
        assertEquals(2, finishes)
    }

    @Test
    fun identicalBytesWithDifferentNamesOrMediaTypesStaySeparateAttachments() = runBlocking {
        val source = temporary.newFile("original.zip").apply { writeBytes(ByteArray(1000) { 42 }) }
        val staged = StagedAttachment(source.name, "", "application/zip", 1000, source.path)
        val uploads = mutableMapOf<String, JsonObject>()
        var starts = 0
        suspend fun call(method: String, params: JsonObject): JsonElement = when (method) {
            "protocol" -> buildJsonObject { put("protocolVersion", 34) }
            "chat.fileCapabilities" -> buildJsonObject { put("maxFileBytes", FILE_MAX); put("relay", false) }
            "chat.fileUploadStart" -> {
                val transfer = "transfer-${++starts}"
                uploads[transfer] = buildJsonObject {
                    put("id", "file-$starts")
                    put("name", params["name"]!!)
                    put("mediaType", params["mediaType"]!!)
                    put("size", 1000)
                }
                // All bytes already reached the host; only finish is pending.
                buildJsonObject { put("transferId", transfer); put("offset", 1000) }
            }
            "chat.fileUploadFinish" -> uploads.getValue(params["transferId"]!!.jsonPrimitive.content)
            "chat.fileUploadStatus" -> buildJsonObject {
                put("finished", true)
                put("attachment", uploads.getValue(params["transferId"]!!.jsonPrimitive.content))
            }
            else -> error("Unexpected request: $method")
        }
        for (file in listOf(staged, staged.copy(name = "renamed.zip"), staged.copy(mediaType = "application/octet-stream"))) {
            repeat(2) {
                val result = uploadChatFile(file, "chat", "owner", ::call,
                    { error("No file bytes need relay consent") }, {})
                assertEquals(file.name, result["name"]!!.jsonPrimitive.content)
                assertEquals(file.mediaType, result["mediaType"]!!.jsonPrimitive.content)
            }
        }
        assertEquals("Each distinct attachment starts once; exact retries reuse it", 3, starts)
    }

    @Test
    fun completedUploadSurvivesRetryWhenAnotherAttachmentRefusesTheMessage() = runBlocking {
        val source = temporary.newFile("original.zip").apply { writeBytes(ByteArray(1000) { 42 }) }
        val staged = StagedAttachment(source.name, "", "application/zip", 1000, source.path)
        var starts = 0
        var finishes = 0
        var statuses = 0
        var capabilities = 0
        var relay = false
        val attachment = buildJsonObject {
            put("id", "file-existing")
            put("name", source.name)
            put("size", 1000)
        }
        suspend fun call(method: String, params: JsonObject): JsonElement =
            when (method) {
                "protocol" -> buildJsonObject { put("protocolVersion", 34) }
                "chat.fileCapabilities" -> {
                    capabilities++
                    buildJsonObject {
                        // After a direct upload, the next route can have a
                        // smaller file limit. Reusing its receipt sends no data.
                        put("maxFileBytes", if (relay) 500 else FILE_MAX)
                        put("relay", relay)
                    }
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
                    { error("Direct or completed transfer must not ask for relay") },
                    {},
                )
            assertEquals("file-existing", returned["id"]!!.jsonPrimitive.content)
            relay = true
        }
        assertEquals(1, starts)
        assertEquals(1, finishes)
        assertEquals(2, statuses)
        assertEquals("Completed retries do not discover another file channel", 1, capabilities)
        assertEquals(1000L, File(source.path).length())
    }
}
