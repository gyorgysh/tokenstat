// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.logic

import ai.tokenstat.tokenstat.ui.localization.L10n

import android.content.Context
import ai.tokenstat.tokenstat.core.readBounded
import java.nio.file.Files
import java.nio.file.StandardCopyOption
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
            if (wire == null) Waiting else entries.firstOrNull { it.wire == wire } ?: NeedsReview
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
            return L10n.text("android.chatoutbox.delivery_needs_checking_reconnect_to_revie.c2182f4e")
        }
        if (offline) {
            return if (first?.whenConnected == true) {
                L10n.text("android.chatoutbox.waiting_for_connection_cancel_by_removing.e4b6b3d3")
            } else {
                L10n.text("android.chatoutbox.paused_reconnect_to_review_delivery.1f9b08dc")
            }
        }
        if (first?.needsReceipt == true) return L10n.text("android.chatoutbox.delivery_needs_checking.62805e9a")
        if (first?.delivery == ChatDelivery.NeedsReview) return L10n.text("android.chatoutbox.review_the_conversation_before_sending.62bc9ce3")
        if (first?.delivery == ChatDelivery.Ready) return L10n.text("android.chatoutbox.ready_choose_send_now_when_you_are_ready.f283a341")
        if (paused) return L10n.text("android.chatoutbox.paused_on_this_device_choose_send_now_to_c.29cb28cc")
        return if (items.size <= 1) {
            L10n.text("android.chatoutbox.waiting_to_send_after_this_turn.103f59e4")
        } else {
            L10n.text("android.chatoutbox.waiting_to_send_after_this_turn_0.a42fb840", "${items.size}")
        }
    }

    /// What the pending strip draws: everything genuinely waiting, which is
    /// to say everything except the send that is in flight right now. Port of
    /// `ChatModel.pendingQueue`.
    ///
    /// The outbox is written before the host is asked, because an
    /// acknowledgement that never arrives must not take the words with it.
    /// That record is not news to the person who just pressed Send: on a
    /// healthy send it exists for one round trip, and drawing it made the
    /// pending strip open and shut on every message.
    fun pending(items: List<QueuedMessage>, deliveringId: String?): List<QueuedMessage> =
        if (deliveringId == null) items else items.filter { it.id != deliveringId }

    /// One key per conversation, and the host is part of it: two machines can
    /// hand out the same conversation id and their queues must not merge.
    fun key(peer: String, workspaceId: String, chatId: String): String =
        listOf(peer, workspaceId, chatId).joinToString("\u0000")

    /// Claim only the writing actually reviewed. A recovered record is never
    /// authorized to send, and an uncertain delivery still needs its receipt.
    fun recoverLegacy(
        legacy: List<QueuedMessage>,
        scoped: List<QueuedMessage>,
        reviewed: List<QueuedMessage>,
    ): List<QueuedMessage> {
        if (legacy != reviewed) {
            throw ChatOutboxFailure(ChatOutboxFailure.Reason.Conflict,
                L10n.text("android.chatoutbox.these_saved_messages_changed_review_them_a.07553b5d"))
        }
        if (!valid(legacy) || !valid(scoped)) {
            throw ChatOutboxFailure(ChatOutboxFailure.Reason.Invalid, L10n.text("android.chatoutbox.that_queue_is_not_valid.f77ac6ee"))
        }
        val ids = scoped.map { it.id }.toSet()
        if (legacy.any { it.id in ids }) {
            throw ChatOutboxFailure(ChatOutboxFailure.Reason.Conflict,
                L10n.text("android.chatoutbox.this_conversation_already_has_a_message_wi.3f3dc86a"))
        }
        if (legacy.size > CAPACITY - scoped.size) {
            throw ChatOutboxFailure(ChatOutboxFailure.Reason.Full,
                L10n.text("android.chatoutbox.this_conversation_cannot_hold_all_the_reco.525857cf"))
        }
        return scoped + legacy.map { item ->
            item.copy(
                delivery = if (item.needsReceipt) ChatDelivery.DeliveryUnknown else ChatDelivery.NeedsReview,
                whenConnected = false,
            )
        }
    }


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

    suspend fun pendingKeys(): Set<String>

    /// Read, mutate and write under one lock, so a change is never made
    /// against a copy that something else has already replaced.
    suspend fun update(key: String, mutate: (MutableList<QueuedMessage>) -> Unit): List<QueuedMessage>

    /// Explicitly transfer reviewed accountless writing to a ProjectOwner
    /// conversation key. Both queues change in one durable write or neither does.
    suspend fun recoverLegacy(legacyKey: String, scopedKey: String, reviewed: List<QueuedMessage>): List<QueuedMessage>

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
class FileChatOutbox internal constructor(
    private val directory: File,
    private val byteLimit: Int = 8 * 1024 * 1024,
) : ChatOutbox {
    constructor(context: Context, byteLimit: Int = 8 * 1024 * 1024) :
        this(File(context.filesDir, "tokenstat-drafts"), byteLimit)

    private companion object {
        // All instances address the same file; per-instance queues can lose writes.
        val files = Dispatchers.IO.limitedParallelism(1)
        val active = mutableSetOf<String>()
    }
    private val file = File(directory, "outbox.v1.json")

    override suspend fun items(key: String): List<QueuedMessage> =
        withContext(files) { read()[key].orEmpty() }

    override suspend fun pendingKeys(): Set<String> =
        withContext(files) { read().filterValues { it.isNotEmpty() }.keys }

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
                L10n.text("android.chatoutbox.this_conversation_already_has_0_messages_w.ac197c73", "${ChatOutboxRules.CAPACITY}"),
            )
        }
        if (!ChatOutboxRules.valid(items)) {
            throw ChatOutboxFailure(ChatOutboxFailure.Reason.Invalid, L10n.text("android.chatoutbox.that_queue_is_not_valid.f77ac6ee"))
        }
        if (items.isEmpty()) queues.remove(key) else queues[key] = items
        write(queues)
        return@withContext items
    }

    override suspend fun recoverLegacy(
        legacyKey: String,
        scopedKey: String,
        reviewed: List<QueuedMessage>,
    ): List<QueuedMessage> = withContext(files) {
        checkRecoveryKeys(legacyKey, scopedKey)
        val queues = read().toMutableMap()
        val legacy = queues[legacyKey].orEmpty()
        val merged = ChatOutboxRules.recoverLegacy(legacy, queues[scopedKey].orEmpty(), reviewed)
        if (legacy.isEmpty()) return@withContext merged
        queues.remove(legacyKey)
        queues[scopedKey] = merged
        write(queues)
        merged
    }

    override fun beginDelivery(key: String): Boolean = synchronized(active) {
        active.add(file.absolutePath + "\u0000" + key)
    }

    override fun endDelivery(key: String) {
        synchronized(active) { active.remove(file.absolutePath + "\u0000" + key) }
    }

    /// A file that exists but cannot be read is refused, never treated as
    /// empty: `update` writes back only the one queue it changed, so reading
    /// a corrupt file as empty would delete every other conversation's
    /// pending messages, which are somebody's own writing.
    private fun read(): Map<String, List<QueuedMessage>> = try {
        readChecked()
    } catch (error: Exception) {
        if (error is ChatOutboxFailure) throw error
        throw ChatOutboxFailure(ChatOutboxFailure.Reason.Unavailable,
            L10n.text("android.chatoutbox.pending_messages_could_not_be_read_on_this.9053a6c1"))
    }

    private fun readChecked(): Map<String, List<QueuedMessage>> {
        if (!file.isFile) return emptyMap()
        val raw = runCatching { file.inputStream().use { it.readBounded(byteLimit).toString(Charsets.UTF_8) } }.getOrNull()
            ?: throw ChatOutboxFailure(
                ChatOutboxFailure.Reason.Unavailable,
                L10n.text("android.chatoutbox.pending_messages_could_not_be_read_on_this.9053a6c1"),
            )
        if (raw.toByteArray(Charsets.UTF_8).size > byteLimit) {
            throw ChatOutboxFailure(
                ChatOutboxFailure.Reason.Unavailable,
                L10n.text("android.chatoutbox.pending_messages_could_not_be_read_on_this.9053a6c1"),
            )
        }
        val root = runCatching { Json.parseToJsonElement(raw).jsonObject }.getOrNull()
            ?: throw ChatOutboxFailure(
                ChatOutboxFailure.Reason.Unavailable,
                L10n.text("android.chatoutbox.pending_messages_could_not_be_read_on_this.9053a6c1"),
            )
        if (root["version"]?.jsonPrimitive?.contentOrNull != "1") {
            throw ChatOutboxFailure(
                ChatOutboxFailure.Reason.Unavailable,
                L10n.text("android.chatoutbox.pending_messages_were_saved_in_a_format_th.9b35ddce"),
            )
        }
        val queues = root["queues"] as? JsonObject
            ?: throw ChatOutboxFailure(
                ChatOutboxFailure.Reason.Unavailable,
                L10n.text("android.chatoutbox.pending_messages_could_not_be_read_on_this.9053a6c1"),
            )
        val out = mutableMapOf<String, List<QueuedMessage>>()
        for ((key, value) in queues) {
            val rows = value as? JsonArray ?: error(L10n.text("android.chatoutbox.invalid_queue.2402eabe"))
            val items = rows.map { decode(it as? JsonObject ?: error(L10n.text("android.chatoutbox.invalid_message.84f51149")))
                ?: error(L10n.text("android.chatoutbox.invalid_message.84f51149")) }
            // Refuse the entire mutation: dropping a damaged sibling queue loses drafts.
            check(ChatOutboxRules.valid(items)) { L10n.text("android.chatoutbox.invalid_queue.2402eabe") }
            if (items.isNotEmpty()) out[key] = items
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
            throw ChatOutboxFailure(ChatOutboxFailure.Reason.Full, L10n.text("android.chatoutbox.the_queue_is_too_large_to_save.79be0ca8"))
        }
        runCatching {
            directory.mkdirs()
            // Written beside and renamed, so a kill in the middle leaves the
            // last good file rather than half of this one.
            val temporary = File(directory, "outbox.v1.json.tmp")
            temporary.outputStream().use { output ->
                output.write(text.toByteArray(Charsets.UTF_8))
                output.fd.sync()
            }
            Files.move(temporary.toPath(), file.toPath(),
                StandardCopyOption.ATOMIC_MOVE, StandardCopyOption.REPLACE_EXISTING)
        }.onFailure {
            throw ChatOutboxFailure(
                ChatOutboxFailure.Reason.Unavailable,
                L10n.text("android.chatoutbox.pending_messages_could_not_be_saved_on_thi.c98829a9"),
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
            text = row["text"]?.jsonPrimitive?.contentOrNull ?: return null,
            attachments = (row["attachments"]?.let { it as? JsonArray ?: return null }).orEmpty().map { element ->
                val file = element as? JsonObject ?: return null
                val fileId = file["id"]?.jsonPrimitive?.contentOrNull ?: return null
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

    override suspend fun pendingKeys(): Set<String> = queues.filterValues { it.isNotEmpty() }.keys

    override suspend fun update(
        key: String,
        mutate: (MutableList<QueuedMessage>) -> Unit,
    ): List<QueuedMessage> {
        val original = queues[key].orEmpty()
        val items = original.toMutableList()
        mutate(items)
        if (items == original) return original
        if (items.size > ChatOutboxRules.CAPACITY) {
            throw ChatOutboxFailure(ChatOutboxFailure.Reason.Full, L10n.text("android.chatoutbox.that_queue_is_full.03116014"))
        }
        if (!ChatOutboxRules.valid(items)) {
            throw ChatOutboxFailure(ChatOutboxFailure.Reason.Invalid, L10n.text("android.chatoutbox.that_queue_is_not_valid.f77ac6ee"))
        }
        if (items.isEmpty()) queues.remove(key) else queues[key] = items.toList()
        return items
    }

    override suspend fun recoverLegacy(
        legacyKey: String,
        scopedKey: String,
        reviewed: List<QueuedMessage>,
    ): List<QueuedMessage> {
        checkRecoveryKeys(legacyKey, scopedKey)
        val merged = ChatOutboxRules.recoverLegacy(queues[legacyKey].orEmpty(), queues[scopedKey].orEmpty(), reviewed)
        queues.remove(legacyKey)
        if (merged.isEmpty()) queues.remove(scopedKey) else queues[scopedKey] = merged
        return merged
    }

    override fun beginDelivery(key: String): Boolean = active.add(key)

    override fun endDelivery(key: String) {
        active.remove(key)
    }
}

private fun checkRecoveryKeys(legacyKey: String, scopedKey: String) {
    if (legacyKey.isBlank() || scopedKey.isBlank() || legacyKey == scopedKey) {
        throw ChatOutboxFailure(ChatOutboxFailure.Reason.Invalid, L10n.text("android.chatoutbox.the_recovery_destination_is_not_valid.751fd4d7"))
    }
}
