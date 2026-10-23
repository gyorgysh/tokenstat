// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.team

import java.io.File
import java.util.UUID
import kotlinx.serialization.json.*

internal data class TeamAskRecord(val input: JsonObject, val fence: JsonObject? = null) {
    val text get() = input.string("text").orEmpty()
    fun validate() {
        require(input.keys == setOf("text", "review", "clientMessageId", "clientMessageCreatedAtMs") && text.isNotBlank() && text.toByteArray().size <= 8192)
        require(input.string("review")?.matches(Regex("[a-f0-9]{64}")) == true)
        require(input.string("clientMessageId")?.let { runCatching { UUID.fromString(it) }.isSuccess } == true)
        require((input["clientMessageCreatedAtMs"] as? JsonPrimitive)?.takeIf { !it.isString }?.longOrNull?.let { it > 0 } == true)
        require(input.toString().toByteArray().size <= 14 * 1024 && (fence == null || validFence(fence)))
    }
    fun terminal(response: JsonObject, share: String): Boolean {
        val r = response["receipt"] as? JsonObject ?: return false
        return r.string("shareId") == share && r["clientMessageId"] == input["clientMessageId"] &&
            r.string("state") in setOf("notStarted", "succeeded", "failed", "stopped", "recovered") &&
            r.string("runId")?.matches(Regex("run_[a-f0-9]{32}")) == true
    }
    companion object {
        fun validFence(value: JsonObject) = value.keys == setOf("runId", "incarnation") &&
            value.string("runId")?.matches(Regex("run_[a-f0-9]{32}")) == true &&
            value.string("incarnation")?.matches(Regex("[a-f0-9]{64}")) == true
        private fun JsonObject.string(key: String) = (this[key] as? JsonPrimitive)?.takeIf { it.isString }?.content
    }
}

/** Separate Ask envelopes reuse the atomic, locked CAS draft storage. They
 * never enter the Comment queue and are never replayed just by opening a chat. */
internal class TeamAskRecoveryStore(directory: File) {
    data class Snapshot(val saved: TeamCommentDraft, val record: TeamAskRecord)
    data class Entry(val target: TeamCommentTarget, val snapshot: Snapshot)
    data class Page(val entries: List<Entry>, val next: String?, val unreadable: Boolean)
    private val files = TeamCommentDraftStore(directory)
    fun load(target: TeamCommentTarget): Snapshot? {
        val saved = files.load(target) ?: return null
        return decode(saved)
    }
    private fun decode(saved: TeamCommentDraft): Snapshot {
        require(saved.attempt == null)
        val value = Json.parseToJsonElement(saved.text).jsonObject
        require(value["version"] == JsonPrimitive(1))
        val record = TeamAskRecord(value["input"]!!.jsonObject, value["fence"]?.takeUnless { it == JsonNull }?.jsonObject)
        record.validate()
        return Snapshot(saved, record)
    }
    fun list(origin: String, person: String, after: String? = null): Page {
        val page = files.list(origin, person, after)
        var unreadable = page.unreadable
        val entries = page.entries.mapNotNull { entry ->
            try {
                val saved = entry.draft ?: error("ask_save_failed")
                if (entry.unsaved != null) unreadable = true
                Entry(entry.target, decode(saved))
            } catch (_: Exception) { unreadable = true; null }
        }
        return Page(entries, page.next, unreadable)
    }
    fun replace(target: TeamCommentTarget, record: TeamAskRecord?, expected: Snapshot?, label: String = ""): Snapshot? {
        record?.validate()
        val content = record?.let { buildJsonObject { put("version", 1); put("input", it.input); it.fence?.let { f -> put("fence", f) } }.toString() }.orEmpty()
        return try {
            val saved = files.save(target, content, expected?.saved, expected?.saved?.label ?: label)
            if (saved != null && record != null) Snapshot(saved, record) else null
        } catch (failure: TeamDraftFailure) {
            if (failure.key != "comment_draft_changed") throw failure
            val current = load(target)
            if (current?.record == record) current else throw failure
        }
    }
}
