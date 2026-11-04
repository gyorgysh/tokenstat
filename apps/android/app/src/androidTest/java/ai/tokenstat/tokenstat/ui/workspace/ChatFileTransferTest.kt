// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.workspace

import ai.tokenstat.tokenstat.core.CoreFailure
import android.os.Looper
import android.util.Base64
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import java.io.ByteArrayOutputStream
import java.io.File
import java.security.MessageDigest
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class ChatFileTransferTest {
    private fun directory() = File(InstrumentationRegistry.getInstrumentation().targetContext.cacheDir,
        "transfer-check-${java.util.UUID.randomUUID()}").apply { mkdirs() }
    private fun sha(bytes: ByteArray) = MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it.toInt() and 255) }
    private fun onMain() = assertSame("Transport and UI callbacks must retain their caller's coroutine", Looper.getMainLooper(), Looper.myLooper())
    private fun protocol() = buildJsonObject { put("protocolVersion", 34) }
    private fun capabilities() = buildJsonObject { put("maxFileBytes", FILE_MAX); put("relay", false) }

    @Test fun uploadChunksPreserveBytesAndReuseEncodingAfterRelayFallback() = runBlocking {
        val root = directory()
        val bytes = ByteArray(2 * 512 * 1024 + 17) { (it * 37).toByte() }
        val source = File(root, "source.bin").apply { writeBytes(bytes) }
        val received = ByteArrayOutputStream()
        var refusedEncoding: String? = null
        var prompts = 0
        val progress = mutableListOf<Float>()
        try {
            withContext(Dispatchers.Main) {
                val result = uploadChatFile(StagedAttachment(source.name, "", "application/octet-stream", bytes.size, source.path), "chat", "owner",
                    call = { method, params ->
                        onMain()
                        when (method) {
                            "protocol" -> protocol()
                            "chat.fileCapabilities" -> capabilities()
                            "chat.fileUploadStart" -> buildJsonObject { put("transferId", "upload"); put("offset", 0) }
                            "chat.fileUploadChunk" -> {
                                val encoded = params["data"]!!.jsonPrimitive.content
                                if (params["allowRelay"]!!.jsonPrimitive.boolean != true) {
                                    refusedEncoding = encoded
                                    throw CoreFailure("relay_consent_required", "Relay consent required")
                                }
                                if (received.size() == 0) assertEquals("A retry sends the same encoded chunk", refusedEncoding, encoded)
                                assertEquals(received.size().toLong(), params["offset"]!!.jsonPrimitive.long)
                                withContext(Dispatchers.Default) { received.write(Base64.decode(encoded, Base64.DEFAULT)) }
                                buildJsonObject { put("offset", received.size()) }
                            }
                            "chat.fileUploadFinish" -> buildJsonObject { put("id", "uploaded"); put("size", received.size()) }
                            else -> error("Unexpected request: $method")
                        }
                    }, confirm = { onMain(); prompts++; true }, progress = { onMain(); progress.add(it) })
                assertEquals("uploaded", result["id"]!!.jsonPrimitive.content)
            }
            assertArrayEquals(bytes, received.toByteArray())
            assertArrayEquals(bytes, source.readBytes())
            assertEquals(1, prompts)
            assertEquals(3, progress.size)
            assertEquals(1f, progress.last())
        } finally { root.deleteRecursively() }
    }

    @Test fun downloadResumesChecksIntegrityAndKeepsCallbacksOnMain() = runBlocking {
        val root = directory()
        val bytes = ByteArray(2 * 512 * 1024 + 17) { (it * 53).toByte() }
        val digest = sha(bytes)
        val key = sha("owner|chat|file|$digest".toByteArray())
        val cached = File(File(root, key).apply { mkdirs() }, "image.png").apply { writeBytes(bytes.copyOf(31)) }
        var prompts = 0
        var chunks = 0
        try {
            val result = withContext(Dispatchers.Main) {
                downloadChatFile(root, "chat", "file", "owner", call = { method, params ->
                    onMain()
                    when (method) {
                        "protocol" -> protocol()
                        "chat.fileCapabilities" -> capabilities()
                        "chat.fileDownloadInfo" -> buildJsonObject {
                            put("sha256", digest)
                            put("attachment", buildJsonObject { put("name", "image.png"); put("size", bytes.size) })
                        }
                        "chat.fileDownloadChunk" -> {
                            if (params["allowRelay"]!!.jsonPrimitive.boolean != true) throw CoreFailure("relay_consent_required", "Relay consent required")
                            val offset = params["offset"]!!.jsonPrimitive.int
                            if (chunks++ == 0) assertEquals(31, offset)
                            val end = minOf(bytes.size, offset + 512 * 1024)
                            val encoded = withContext(Dispatchers.Default) { Base64.encodeToString(bytes.copyOfRange(offset, end), Base64.NO_WRAP) }
                            buildJsonObject { put("offset", offset); put("nextOffset", end); put("data", encoded) }
                        }
                        else -> error("Unexpected request: $method")
                    }
                }, confirm = { onMain(); prompts++; true }, progress = { onMain() })
            }
            assertEquals(cached, result)
            assertArrayEquals(bytes, result.readBytes())
            assertEquals(1, prompts)
            assertEquals(2, chunks)
        } finally { root.deleteRecursively() }
    }

    @Test fun cancelledDownloadDoesNotPublishPartialBytes() = runBlocking {
        val root = directory()
        val bytes = ByteArray(512 * 1024 + 1) { 42 }
        val digest = sha(bytes)
        var chunks = 0
        try {
            try {
                withContext(Dispatchers.Main) {
                    downloadChatFile(root, "chat", "cancelled", "owner", call = { method, _ -> when (method) {
                        "protocol" -> protocol()
                        "chat.fileCapabilities" -> capabilities()
                        "chat.fileDownloadInfo" -> buildJsonObject { put("sha256", digest); put("attachment", buildJsonObject { put("name", "cancelled.bin"); put("size", bytes.size) }) }
                        "chat.fileDownloadChunk" -> {
                            chunks++
                            val encoded = withContext(Dispatchers.Default) { Base64.encodeToString(bytes.copyOf(512 * 1024), Base64.NO_WRAP) }
                            buildJsonObject { put("offset", 0); put("nextOffset", 512 * 1024); put("data", encoded) }
                        }
                        else -> error("Unexpected request: $method")
                    } }, confirm = { error("Direct transfer must not prompt") }, progress = { throw CancellationException("Navigation changed") })
                }
                fail("Cancelled transfer returned a file")
            } catch (_: CancellationException) {}
            assertEquals(1, chunks)
            assertTrue(root.listFiles().orEmpty().isEmpty())
        } finally { root.deleteRecursively() }
    }
}
