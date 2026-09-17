// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.logic

import android.content.Context
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.longOrNull
import kotlinx.serialization.json.put
import java.io.File

/// Messages waiting for the open turn to finish. Port of `ChatQueuedMessage`
/// and `ChatOutboxStore` (`Features/Work/ChatOutboxStore.swift`).
///
/// The host takes one turn at a time, so a second prompt has to wait
/// somewhere. Queued messages are somebody's own writing, not a cache that
/// can be rebuilt, so they are written to disk before the host is asked and
/// they only leave once the host has acknowledged them.

/// Where a queued message has got to.
///
/// `DeliveryUnknown` is the one that matters: the send left this device and
/// no answer came back. It is not "never sent", so the copy stays and the
/// only honest next step is to ask the host for a receipt.
enum class ChatDelivery {
    Waiting,
    Sending,
    DeliveryUnknown,
    Failed,
    NeedsReview,
    Ready,
    ;

    val wire: String
        get() = when (this) {
            Waiting -> "waiting"
            Sending -> "sending"
            DeliveryUnknown -> "deliveryUnknown"
            Failed -> "failed"
            NeedsReview -> "needsReview"
            Ready -> "ready"
        }

    companion object {
        fun of(wire: String?): ChatDelivery =
            entries.firstOrNull { it.wire == wire } ?: Waiting
    }
}

data class QueuedAttachment(val id: String, val name: String)

data class QueuedMessage(
    val id: String,
    val text: String,
    val attachments: List<QueuedAttachment> = emptyList(),
    val delivery: ChatDelivery = ChatDelivery.Waiting,
    /// Fixed at the first attempt, including retries of a refused send, so the
    /// host sees one creation time for one message.
    val firstAttemptAtMs: Long? = null,
    val attemptedAtMs: Long? = null,
    /// The conversation revision this message was written against. The host
    /// refuses a send whose revision has moved, which is what stops a queued
    /// message landing on a conversation somebody has since changed.
    val expectedRevision: Long? = null,
    val whenConnected: Boolean = false,
) {
    /// The host may or may not have this message. Nothing may be resent and
    /// nothing may be edited until a receipt says which.
    val needsReceipt: Boolean
        get() = delivery == ChatDelivery.Sending || delivery == ChatDelivery.DeliveryUnknown

    val canEdit: Boolean get() = !needsReceipt
}

/// The rules, with no storage and no Android under them, so the awkward parts
/// have tests that need neither a device nor a file.
object ChatOutboxRules {
    /// Twenty is the Apple store's capacity. A queue longer than that is not a
    /// queue, it is a lost draft folder.
    const val CAPACITY = 20
    const val MAX_ID_BYTES = 256

    fun valid(items: List<QueuedMessage>): Boolean =
        items.size <= CAPACITY &&
            items.map { it.id }.toSet().size == items.size &&
            items.all { it.id.isNotEmpty() && it.id.toByteArray(Charsets.UTF_8).size <= MAX_ID_BYTES }

    /// The host took one message. Drop it, and carry every sibling that was
    /// written against the same revision forward to the new one.
    ///
    /// Only when the new revision is exactly one past what they expected: any
    /// other jump means somebody else changed the conversation in between, and
    /// those messages have to be reviewed rather than quietly re-aimed.
    fun accept(
        items: List<QueuedMessage>,
        acceptedId: String,
        revision: Long?,
    ): List<QueuedMessage> {
        val accepted = items.firstOrNull { it.id == acceptedId }
        val rest = items.filterNot { it.id == acceptedId }
        val expected = accepted?.expectedRevision ?: return rest
        if (revision == null || revision != expected + 1) return rest
        return rest.map {
            if (it.delivery == ChatDelivery.Waiting && it.expectedRevision == expected) {
                it.copy(expectedRevision = revision)
            } else {
                it
            }
        }
    }

    /// Reorder, the way a drag on the pending list does.
    fun moved(items: List<QueuedMessage>, from: Int, to: Int): List<QueuedMessage> {
        if (from !in items.indices || to !in items.indices || from == to) return items
        val out = items.toMutableList()
        out.add(to, out.removeAt(from))
        return out
    }

    /// The line on the strip. Port of `ChatQueueStrip.title`: it says what is
    /// actually true, and an unconfirmed delivery outranks everything else
    /// because it is the only state where doing nothing is the right move.
    fun title(items: List<QueuedMessage>, paused: Boolean, offline: Boolean): String {
        val first = items.firstOrNull()
        if (offline && first?.needsReceipt == true) {
            return "Delivery needs checking · Reconnect to review"
        }
        if (offline) {
            return if (first?.whenConnected == true) {
                "Waiting for connection · Cancel by removing the copy"
            } else {
                "Paused · Reconnect to review delivery"
            }
        }
        if (first?.needsReceipt == true) return "Delivery needs checking"
        if (first?.delivery == ChatDelivery.NeedsReview) return "Review the conversation before sending"
        if (first?.delivery == ChatDelivery.Ready) return "Ready · Choose Send now when you are ready"
        if (paused) return "Paused on this device · Choose Send now to continue"
        return if (items.size <= 1) {
            "Waiting to send after this turn"
        } else {
            "Waiting to send after this turn · ${items.size}"
        }
    }

    /// One key per conversation, and the host is part of it: two machines can
    /// hand out the same conversation id and their queues must not merge.
    fun key(peer: String, workspaceId: String, chatId: String): String =
        listOf(peer, workspaceId, chatId).joinToString("\u0000")


    /// Whether a failed send might still have reached the host.
    ///
    /// Port of `Bridge.isDeliveryUnknown`. A timeout or an unreadable answer
    /// is not a refusal: the message may already be running. These are the
    /// cases where the only safe next step is a receipt, never a resend.
    fun deliveryUnknown(code: String?, message: String?): Boolean {
        // The request never left this device: the host was not on the tunnel
        // to be asked. That is a refusal with a known answer, and calling it
        // unknown would put a message somebody can see is unsent behind
        // "Check delivery" with nothing to check.
        if (TunnelCopy.isAbsent(message.orEmpty())) return false
        if (code in setOf("delivery_unknown", "unknown", "null")) return true
        val text = message.orEmpty().lowercase()
        return text.contains("timed out") || text.contains("timeout") ||
            text.contains("deadline") || text.contains("could not be read")
    }}

/// Why a queue change was refused.
class ChatOutboxFailure(val reason: Reason, message: String) : Exception(message) {
    enum class Reason { Invalid, Full, Conflict, Unavailable }
}

interface ChatOutbox {
    suspend fun items(key: String): List<QueuedMessage>

    /// Read, mutate and write under one lock, so a change is never made
    /// against a copy that something else has already replaced.
    suspend fun update(key: String, mutate: (MutableList<QueuedMessage>) -> Unit): List<QueuedMessage>

    /// One delivery per conversation at a time. Returns false when one is
    /// already running.
    fun beginDelivery(key: String): Boolean
    fun endDelivery(key: String)
}

/// The store the app uses: one JSON file, written whole.
///
/// The Apple store takes an `fcntl` write lock because several windows of one
/// Mac app share the file. An Android app is a single process, so every disk
/// access runs on one thread instead, off the main thread and in the order
/// the calls were made: keystrokes persist per character, and two writes
/// running in parallel could land out of order and drop one.
class FileChatOutbox(
    context: Context,
    private val byteLimit: Int = 8 * 1024 * 1024,
) : ChatOutbox {
    private val directory = File(context.filesDir, "tokenstat-drafts")
    private val file = File(directory, "outbox.v1.json")
    private val active = mutableSetOf<String>()
    private val files = Dispatchers.IO.limitedParallelism(1)

    override suspend fun items(key: String): List<QueuedMessage> =
        withContext(files) { read()[key].orEmpty() }

    override suspend fun update(
        key: String,
        mutate: (MutableList<QueuedMessage>) -> Unit,
    ): List<QueuedMessage> = withContext(files) {
        val queues = read().toMutableMap()
        val original = queues[key].orEmpty()
        val items = original.toMutableList()
        mutate(items)
        if (items == original) return@withContext original
        if (items.size > ChatOutboxRules.CAPACITY) {
            throw ChatOutboxFailure(
                ChatOutboxFailure.Reason.Full,
                "This conversation already has ${ChatOutboxRules.CAPACITY} messages waiting.",
            )
        }
        if (!ChatOutboxRules.valid(items)) {
            throw ChatOutboxFailure(ChatOutboxFailure.Reason.Invalid, "That queue is not valid.")
        }
        if (items.isEmpty()) queues.remove(key) else queues[key] = items
        write(queues)
        return@withContext items
    }

    @Synchronized
    override fun beginDelivery(key: String): Boolean = active.add(key)

    @Synchronized
    override fun endDelivery(key: String) {
        active.remove(key)
    }

    /// A file that exists but cannot be read is refused, never treated as
    /// empty: `update` writes back only the one queue it changed, so reading
    /// a corrupt file as empty would delete every other conversation's
    /// pending messages, which are somebody's own writing.
    private fun read(): Map<String, List<QueuedMessage>> {
        if (!file.isFile) return emptyMap()
        val raw = runCatching { file.readText(Charsets.UTF_8) }.getOrNull()
            ?: throw ChatOutboxFailure(
                ChatOutboxFailure.Reason.Unavailable,
                "Pending messages could not be read on this device.",
            )
        if (raw.toByteArray(Charsets.UTF_8).size > byteLimit) {
            throw ChatOutboxFailure(
                ChatOutboxFailure.Reason.Unavailable,
                "Pending messages could not be read on this device.",
            )
        }
        val root = runCatching { Json.parseToJsonElement(raw).jsonObject }.getOrNull()
            ?: throw ChatOutboxFailure(
                ChatOutboxFailure.Reason.Unavailable,
                "Pending messages could not be read on this device.",
            )
        if (root["version"]?.jsonPrimitive?.contentOrNull != "1") {
            throw ChatOutboxFailure(
                ChatOutboxFailure.Reason.Unavailable,
                "Pending messages were saved in a format this version cannot read.",
            )
        }
        val queues = root["queues"] as? JsonObject
            ?: throw ChatOutboxFailure(
                ChatOutboxFailure.Reason.Unavailable,
                "Pending messages could not be read on this device.",
            )
        val out = mutableMapOf<String, List<QueuedMessage>>()
        for ((key, value) in queues) {
            val items = (value as? JsonArray)?.mapNotNull { decode(it as? JsonObject ?: return@mapNotNull null) }
                .orEmpty()
            // A queue that does not survive its own rules is dropped rather
            // than half-loaded: a duplicate id would make Remove ambiguous.
            if (items.isNotEmpty() && ChatOutboxRules.valid(items)) out[key] = items
        }
        return out
    }

    private fun write(queues: Map<String, List<QueuedMessage>>) {
        val root = buildJsonObject {
            put("version", "1")
            put(
                "queues",
                buildJsonObject {
                    queues.forEach { (key, items) ->
                        put(key, buildJsonArray { items.forEach { add(encode(it)) } })
                    }
                },
            )
        }
        val text = root.toString()
        if (text.toByteArray(Charsets.UTF_8).size > byteLimit) {
            throw ChatOutboxFailure(ChatOutboxFailure.Reason.Full, "The queue is too large to save.")
        }
        runCatching {
            directory.mkdirs()
            // Written beside and renamed, so a kill in the middle leaves the
            // last good file rather than half of this one.
            val temporary = File(directory, "outbox.v1.json.tmp")
            temporary.writeText(text, Charsets.UTF_8)
            if (!temporary.renameTo(file)) {
                file.writeText(text, Charsets.UTF_8)
                temporary.delete()
            }
        }.onFailure {
            throw ChatOutboxFailure(
                ChatOutboxFailure.Reason.Unavailable,
                "Pending messages could not be saved on this device.",
            )
        }
    }

    private fun encode(item: QueuedMessage): JsonObject = buildJsonObject {
        put("id", item.id)
        put("text", item.text)
        put(
            "attachments",
            buildJsonArray {
                item.attachments.forEach {
                    add(buildJsonObject { put("id", it.id); put("name", it.name) })
                }
            },
        )
        put("delivery", item.delivery.wire)
        item.firstAttemptAtMs?.let { put("firstAttemptAtMs", it) }
        item.attemptedAtMs?.let { put("attemptedAtMs", it) }
        item.expectedRevision?.let { put("expectedRevision", it) }
        put("whenConnected", item.whenConnected)
    }

    private fun decode(row: JsonObject): QueuedMessage? {
        val id = row["id"]?.jsonPrimitive?.contentOrNull?.takeIf { it.isNotEmpty() } ?: return null
        return QueuedMessage(
            id = id,
            text = row["text"]?.jsonPrimitive?.contentOrNull.orEmpty(),
            attachments = (row["attachments"] as? JsonArray).orEmpty().mapNotNull { element ->
                val file = element as? JsonObject ?: return@mapNotNull null
                val fileId = file["id"]?.jsonPrimitive?.contentOrNull ?: return@mapNotNull null
                QueuedAttachment(fileId, file["name"]?.jsonPrimitive?.contentOrNull.orEmpty())
            },
            delivery = ChatDelivery.of(row["delivery"]?.jsonPrimitive?.contentOrNull),
            firstAttemptAtMs = row["firstAttemptAtMs"]?.jsonPrimitive?.longOrNull,
            attemptedAtMs = row["attemptedAtMs"]?.jsonPrimitive?.longOrNull,
            expectedRevision = row["expectedRevision"]?.jsonPrimitive?.longOrNull,
            whenConnected = row["whenConnected"]?.jsonPrimitive?.booleanOrNull ?: false,
        )
    }
}

/// What a test or a preview uses.
class InMemoryChatOutbox : ChatOutbox {
    private val queues = mutableMapOf<String, List<QueuedMessage>>()
    private val active = mutableSetOf<String>()

    override suspend fun items(key: String): List<QueuedMessage> = queues[key].orEmpty()

    override suspend fun update(
        key: String,
        mutate: (MutableList<QueuedMessage>) -> Unit,
    ): List<QueuedMessage> {
        val original = queues[key].orEmpty()
        val items = original.toMutableList()
        mutate(items)
        if (items == original) return original
        if (items.size > ChatOutboxRules.CAPACITY) {
            throw ChatOutboxFailure(ChatOutboxFailure.Reason.Full, "That queue is full.")
        }
        if (!ChatOutboxRules.valid(items)) {
            throw ChatOutboxFailure(ChatOutboxFailure.Reason.Invalid, "That queue is not valid.")
        }
        if (items.isEmpty()) queues.remove(key) else queues[key] = items.toList()
        return items
    }

    override fun beginDelivery(key: String): Boolean = active.add(key)

    override fun endDelivery(key: String) {
        active.remove(key)
    }
}
