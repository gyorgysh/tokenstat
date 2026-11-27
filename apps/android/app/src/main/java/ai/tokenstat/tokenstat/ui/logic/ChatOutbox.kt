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
    val firstAttemptAtMs: Long? = null,
    val attemptedAtMs: Long? = null,
    val expectedRevision: Long? = null,
    val whenConnected: Boolean = false,
) {
    val needsReceipt: Boolean
        get() = delivery == ChatDelivery.Sending || delivery == ChatDelivery.DeliveryUnknown

    val canEdit: Boolean get() = !needsReceipt
}

object ChatOutboxRules {
    const val CAPACITY = 20
    const val MAX_ID_BYTES = 256

    fun valid(items: List<QueuedMessage>): Boolean =
        items.size <= CAPACITY &&
            items.map { it.id }.toSet().size == items.size &&
            items.all { it.id.isNotEmpty() && it.id.toByteArray(Charsets.UTF_8).size <= MAX_ID_BYTES }

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

    fun moved(items: List<QueuedMessage>, from: Int, to: Int): List<QueuedMessage> {
        if (from !in items.indices || to !in items.indices || from == to) return items
        val out = items.toMutableList()
        out.add(to, out.removeAt(from))
        return out
    }

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

    fun pending(items: List<QueuedMessage>, deliveringId: String?): List<QueuedMessage> =
        if (deliveringId == null) items else items.filter { it.id != deliveringId }

    fun key(peer: String, workspaceId: String, chatId: String): String =
        listOf(peer, workspaceId, chatId).joinToString("\u0000")

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


    fun deliveryUnknown(code: String?, message: String?): Boolean {
        if (TunnelCopy.isAbsent(message.orEmpty())) return false
        if (code in setOf("delivery_unknown", "unknown", "null")) return true
        val text = message.orEmpty().lowercase()
        return text.contains("timed out") || text.contains("timeout") ||
            text.contains("deadline") || text.contains("could not be read")
    }}

class ChatOutboxFailure(val reason: Reason, message: String) : Exception(message) {
    enum class Reason { Invalid, Full, Conflict, Unavailable }
}

interface ChatOutbox {
    suspend fun items(key: String): List<QueuedMessage>

    suspend fun pendingKeys(): Set<String>

    suspend fun update(key: String, mutate: (MutableList<QueuedMessage>) -> Unit): List<QueuedMessage>

    suspend fun recoverLegacy(legacyKey: String, scopedKey: String, reviewed: List<QueuedMessage>): List<QueuedMessage>

    fun beginDelivery(key: String): Boolean
    fun endDelivery(key: String)
}

class FileChatOutbox internal constructor(
    private val directory: File,
    private val byteLimit: Int = 8 * 1024 * 1024,
) : ChatOutbox {
    constructor(context: Context, byteLimit: Int = 8 * 1024 * 1024) :
        this(File(context.filesDir, "tokenstat-drafts"), byteLimit)

    private companion object {
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
