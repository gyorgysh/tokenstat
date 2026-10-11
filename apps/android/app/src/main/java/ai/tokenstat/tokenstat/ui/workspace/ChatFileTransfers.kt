// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.workspace

import ai.tokenstat.tokenstat.core.CoreFailure
import ai.tokenstat.tokenstat.ui.localization.L10n
import ai.tokenstat.tokenstat.ui.logic.HostContracts
import android.util.Base64
import java.io.File
import java.io.RandomAccessFile
import java.security.MessageDigest
import kotlin.coroutines.coroutineContext
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.*

private val fileTransferClaims = java.util.concurrent.ConcurrentHashMap.newKeySet<String>()
private const val FILE_CHUNK = 512 * 1024
internal const val FILE_MAX = 256 * 1024 * 1024

private fun JsonObject.text(key: String) = (get(key) as? JsonPrimitive)?.contentOrNull.orEmpty()

private fun JsonObject.number(key: String) = (get(key) as? JsonPrimitive)?.longOrNull ?: 0L

private fun digest(bytes: ByteArray) = bytes.joinToString("") { "%02x".format(it.toInt() and 255) }

internal suspend fun uploadChatFile(
    attachment: StagedAttachment,
    chat: String,
    owner: String,
    call: suspend (String, JsonObject) -> JsonElement,
    confirm: suspend (Long?) -> Boolean,
    progress: suspend (Float) -> Unit,
): JsonObject {
    val file = attachment.filePath?.let(::File)
    if (file == null)
        return call(
            "chat.attach",
            buildJsonObject {
                put("id", chat)
                put("name", attachment.name)
                put("data", attachment.data)
                attachment.mediaType?.let { put("mediaType", it) }
            },
        )
            as JsonObject
    val protocol = call("protocol", buildJsonObject {}) as? JsonObject
    if ((HostContracts.protocolOf(protocol) ?: 0) < 34) {
        require(file.length() <= 12 * 1024 * 1024) { L10n.text("common.chat_route_unavailable") }
        val encoded =
            withContext(Dispatchers.IO) {
                RandomAccessFile(file, "r").use { input ->
                    val size = input.length()
                    require(size in 1..12L * 1024 * 1024)
                    val bytes = ByteArray(size.toInt())
                    input.readFully(bytes)
                    require(input.length() == size)
                    Base64.encodeToString(bytes, Base64.NO_WRAP)
                }
            }
        var relay = false
        suspend fun send() =
            call(
                "chat.attach",
                buildJsonObject {
                    put("id", chat)
                    put("name", attachment.name)
                    put("data", encoded)
                    put("allowRelay", relay)
                },
            )
                as JsonObject
        return try {
            send()
        } catch (error: CoreFailure) {
            if (error.code != "relay_consent_required" || !confirm(null)) throw error
            relay = true
            send()
        }
    }
    val size = file.length()
    require(size in 1..FILE_MAX.toLong()) { L10n.text("common.chat_files_too_large") }
    val hash =
        withContext(Dispatchers.IO) {
            var total = 0L
            val digest = MessageDigest.getInstance("SHA-256")
            file.inputStream().use { input ->
                val buffer = ByteArray(FILE_CHUNK)
                while (true) {
                    coroutineContext.ensureActive()
                    val count = input.read(buffer)
                    if (count < 0) break
                    total += count
                    require(total <= size)
                    digest.update(buffer, 0, count)
                }
            }
            require(total == size)
            digest(digest.digest())
        }
    val caps = call("chat.fileCapabilities", buildJsonObject { put("id", chat) }) as JsonObject
    require(size in 1..minOf(FILE_MAX.toLong(), caps.number("maxFileBytes"))) {
        L10n.text("common.chat_files_too_large")
    }
    var allowRelay = false
    if ((caps["relay"] as? JsonPrimitive)?.booleanOrNull == true) {
        check(confirm((caps["relayRemainingBytes"] as? JsonPrimitive)?.longOrNull))
        allowRelay = true
    }
    val key =
        digest(
            MessageDigest.getInstance("SHA-256")
                .digest((owner + "|" + chat + "|" + hash).toByteArray())
        )
    check(fileTransferClaims.add(key)) { L10n.text("common.chat_files_busy") }
    try {
        val receipt = File(file.parentFile, file.name + ".$key.upload")
        val old =
            withContext(Dispatchers.IO) {
                runCatching {
                        require(receipt.length() in 1..8192)
                        Json.parseToJsonElement(receipt.readText()).jsonObject
                    }
                    .getOrNull()
            }
        val previous =
            old?.text("transferId")
                ?.takeIf { it.isNotBlank() }
                ?.let { transfer ->
                    runCatching {
                        call(
                            "chat.fileUploadStatus",
                            buildJsonObject {
                                put("id", chat)
                                put("transferId", transfer)
                            },
                        )
                            as JsonObject
                    }
                        .getOrNull()
                }
        if (previous?.get("finished")?.jsonPrimitive?.booleanOrNull == true) {
            receipt.delete()
            return previous["attachment"] as JsonObject
        }
        val start =
            previous
                ?: call(
                    "chat.fileUploadStart",
                    buildJsonObject {
                        put("id", chat)
                        put("name", attachment.name)
                        put("size", size)
                        put("sha256", hash)
                        attachment.mediaType?.let { put("mediaType", it) }
                    },
                )
                    as JsonObject
        try {
            withContext(Dispatchers.IO) {
                val temporary = File(receipt.path + ".tmp")
                temporary.writeText(start.toString())
                check(temporary.renameTo(receipt))
            }
        } catch (error: Exception) {
            runCatching {
                call(
                    "chat.fileUploadCancel",
                    buildJsonObject {
                        put("id", chat)
                        put("transferId", start.text("transferId"))
                    },
                )
            }
            throw error
        }
        val transfer = start.text("transferId")
        var offset = start.number("offset")
        require(offset in 0..size)
        try {
            RandomAccessFile(file, "r").use { input ->
                while (offset < size) {
                    coroutineContext.ensureActive()
                    val bytes =
                        withContext(Dispatchers.IO) {
                            input.seek(offset)
                            ByteArray(minOf(FILE_CHUNK.toLong(), size - offset).toInt()).also {
                                input.readFully(it)
                            }
                        }
                    suspend fun send() =
                        call(
                            "chat.fileUploadChunk",
                            buildJsonObject {
                                put("id", chat)
                                put("transferId", transfer)
                                put("offset", offset)
                                put("data", Base64.encodeToString(bytes, Base64.NO_WRAP))
                                put("allowRelay", allowRelay)
                            },
                        )
                            as JsonObject
                    val result =
                        try {
                            send()
                        } catch (error: CoreFailure) {
                            if (
                                error.code != "relay_consent_required" ||
                                    allowRelay ||
                                    !confirm(
                                        (caps["relayRemainingBytes"] as? JsonPrimitive)?.longOrNull
                                    )
                            )
                                throw error
                            allowRelay = true
                            send()
                        }
                    check(result.number("offset") == offset + bytes.size) {
                        "Invalid file transfer response"
                    }
                    offset = result.number("offset")
                    progress(offset.toFloat() / size)
                }
            }
            val result =
                call(
                    "chat.fileUploadFinish",
                    buildJsonObject {
                        put("id", chat)
                        put("transferId", transfer)
                    },
                )
                    as JsonObject
            receipt.delete()
            return result
        } catch (error: Exception) {
            if (error is kotlinx.coroutines.CancellationException) {
                withContext(kotlinx.coroutines.NonCancellable) {
                    kotlinx.coroutines.withTimeoutOrNull(5000) {
                        runCatching {
                            call(
                                "chat.fileUploadCancel",
                                buildJsonObject {
                                    put("id", chat)
                                    put("transferId", transfer)
                                },
                            )
                        }
                    }
                }
                receipt.delete()
            }
            throw error
        }
    } finally {
        fileTransferClaims.remove(key)
    }
}

internal suspend fun downloadChatFile(
    directory: File,
    chat: String,
    attachment: String,
    owner: String,
    call: suspend (String, JsonObject) -> JsonElement,
    confirm: suspend (Long?) -> Boolean,
    progress: suspend (Float) -> Unit,
): File {
    val protocol = call("protocol", buildJsonObject {}) as? JsonObject
    if ((HostContracts.protocolOf(protocol) ?: 0) < 34) {
        var relay = false
        suspend fun request() =
            call(
                "chat.attachment",
                buildJsonObject {
                    put("id", chat)
                    put("attachmentId", attachment)
                    put("allowRelay", relay)
                },
            )
                as JsonObject
        val result =
            try {
                request()
            } catch (error: CoreFailure) {
                if (error.code != "relay_consent_required" || !confirm(null)) throw error
                relay = true
                request()
            }
        val encoded = result.text("data")
        require(encoded.length <= 16 * 1024 * 1024 + 4)
        val bytes = Base64.decode(encoded, Base64.DEFAULT)
        require(bytes.size <= 12 * 1024 * 1024)
        val name =
            File((result["attachment"] as? JsonObject)?.text("name").orEmpty()).name.takeIf {
                it.isNotBlank() && it != "." && it != ".."
            } ?: "attachment"
        val folder = File(directory, java.util.UUID.randomUUID().toString())
        folder.mkdirs()
        return File(folder, name).also { withContext(Dispatchers.IO) { it.writeBytes(bytes) } }
    }
    val caps = call("chat.fileCapabilities", buildJsonObject { put("id", chat) }) as JsonObject
    val info =
        call(
            "chat.fileDownloadInfo",
            buildJsonObject {
                put("id", chat)
                put("attachmentId", attachment)
            },
        )
            as JsonObject
    val descriptor = info["attachment"] as JsonObject
    val size = descriptor.number("size")
    require(size in 1..minOf(FILE_MAX.toLong(), caps.number("maxFileBytes"))) {
        L10n.text("common.chat_files_too_large")
    }
    var allowRelay = false
    if ((caps["relay"] as? JsonPrimitive)?.booleanOrNull == true) {
        check(confirm((caps["relayRemainingBytes"] as? JsonPrimitive)?.longOrNull))
        allowRelay = true
    }
    val key =
        digest(
            MessageDigest.getInstance("SHA-256")
                .digest(
                    (owner + "|" + chat + "|" + attachment + "|" + info.text("sha256"))
                        .toByteArray()
                )
        )
    check(fileTransferClaims.add(key)) { L10n.text("common.chat_files_busy") }
    try {
        val folder = File(directory, key)
        folder.mkdirs()
        val name =
            File(descriptor.text("name")).name.takeIf { it.isNotBlank() && it != "." && it != ".." }
                ?: "attachment"
        val target = File(folder, name)
        try {
            val hash = MessageDigest.getInstance("SHA-256")
            var offset = 0L
            if (target.exists()) {
                require(target.length() <= size)
                withContext(Dispatchers.IO) {
                    target.inputStream().use { input ->
                        val buffer = ByteArray(FILE_CHUNK)
                        while (true) {
                            val count = input.read(buffer)
                            if (count < 0) break
                            hash.update(buffer, 0, count)
                            offset += count
                        }
                    }
                }
            }
            java.io.FileOutputStream(target, true).use { output ->
                while (offset < size) {
                    coroutineContext.ensureActive()
                    suspend fun request() =
                        call(
                            "chat.fileDownloadChunk",
                            buildJsonObject {
                                put("id", chat)
                                put("attachmentId", attachment)
                                put("offset", offset)
                                put("allowRelay", allowRelay)
                            },
                        )
                            as JsonObject
                    val chunk =
                        try {
                            request()
                        } catch (error: CoreFailure) {
                            if (
                                error.code != "relay_consent_required" ||
                                    allowRelay ||
                                    !confirm(
                                        (caps["relayRemainingBytes"] as? JsonPrimitive)?.longOrNull
                                    )
                            )
                                throw error
                            allowRelay = true
                            request()
                        }
                    val encoded = chunk.text("data")
                    require(encoded.length <= 699052)
                    val bytes = Base64.decode(encoded, Base64.DEFAULT)
                    require(
                        bytes.isNotEmpty() &&
                            bytes.size <= FILE_CHUNK &&
                            chunk.number("offset") == offset &&
                            chunk.number("nextOffset") == offset + bytes.size &&
                            offset + bytes.size <= size
                    )
                    withContext(Dispatchers.IO) { output.write(bytes) }
                    hash.update(bytes)
                    offset += bytes.size
                    progress(offset.toFloat() / size)
                }
            }
            check(digest(hash.digest()) == info.text("sha256")) { "File integrity check failed" }
            return target
        } catch (error: Exception) {
            if (
                error is kotlinx.coroutines.CancellationException ||
                    error is IllegalArgumentException ||
                    error is IllegalStateException
            )
                folder.deleteRecursively()
            throw error
        }
    } finally {
        fileTransferClaims.remove(key)
    }
}
