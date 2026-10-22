// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.team

import java.io.File
import java.io.FileOutputStream
import java.io.RandomAccessFile
import java.nio.channels.FileChannel
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import java.nio.file.StandardOpenOption
import java.security.MessageDigest
import java.util.UUID
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.*

@Serializable internal data class TeamCommentTarget(val origin: String, val person: String, val organization: String, val repository: String, val checkout: String, val share: String, val host: String)
@Serializable internal data class TeamCommentAttempt(val id: String, val createdAtMs: Long)
@Serializable internal data class TeamCommentDraft(val revision: String, val text: String, val attempt: TeamCommentAttempt?, val label: String) {
    val input: JsonObject? get() = attempt?.let { a -> buildJsonObject {
        put("text", text); put("clientMessageId", a.id); put("clientMessageCreatedAtMs", a.createdAtMs)
    } }
    val canSend: Boolean get() = text.isNotBlank() && text.toByteArray().size <= 8192 &&
        copy(attempt = attempt ?: TeamCommentAttempt(UUID.randomUUID().toString(), 1)).input.toString().toByteArray().size <= 14 * 1024
}
internal data class TeamCommentUnsaved(val text: String, val expected: TeamCommentDraft?, val label: String)
internal data class TeamCommentRecovery(val target: TeamCommentTarget, val draft: TeamCommentDraft?, val unsaved: TeamCommentUnsaved?)
internal data class TeamCommentDraftPage(val entries: List<TeamCommentRecovery>, val next: String?, val unreadable: Boolean)
internal class TeamDraftFailure(val key: String) : java.io.IOException(key)

/** App-private local writing. No personal queue, shared storage or automatic resend. */
internal class TeamCommentDraftStore(private val directory: File) {
    companion object {
        private val gate = Any(); private const val LIMIT = 128 * 1024
        private val shared = mutableMapOf<String, TeamCommentDraftStore>()
        fun shared(directory: File): TeamCommentDraftStore = synchronized(gate) { shared.getOrPut(directory.absolutePath) { TeamCommentDraftStore(directory) } }
    }
    private val json = Json { explicitNulls = true }
    private val unsaved = mutableMapOf<TeamCommentTarget, TeamCommentUnsaved>()
    @Serializable private data class Envelope(val version: Int, val target: TeamCommentTarget, val draft: TeamCommentDraft)
    private fun hash(value: String) = MessageDigest.getInstance("SHA-256").digest(value.toByteArray()).joinToString("") { "%02x".format(it) }
    private fun name(t: TeamCommentTarget) = hash(json.encodeToString(t)) + ".json"
    private fun valid(t: TeamCommentTarget) {
        if (listOf(t.origin, t.person, t.organization, t.repository, t.checkout, t.share, t.host).any { it.isBlank() || it.toByteArray().size > 2048 }) throw TeamDraftFailure("comment_save_failed")
    }
    private fun <T> locked(t: TeamCommentTarget, block: (File) -> T): T = synchronized(gate) {
        valid(t)
        Files.createDirectories(directory.toPath())
        if (Files.isSymbolicLink(directory.toPath())) throw TeamDraftFailure("comment_save_failed")
        val owner = File(directory, hash(json.encodeToString(listOf(t.origin, t.person))))
        Files.createDirectories(owner.toPath())
        if (Files.isSymbolicLink(owner.toPath())) throw TeamDraftFailure("comment_save_failed")
        val lock = File(owner, "drafts.lock")
        if (Files.isSymbolicLink(lock.toPath())) throw TeamDraftFailure("comment_save_failed")
        RandomAccessFile(lock, "rw").use { file ->
            val held = file.channel.tryLock() ?: throw TeamDraftFailure("comment_save_failed")
            held.use { block(owner) }
        }
    }
    private fun read(file: File): Envelope? {
        if (!file.exists()) return null
        if (Files.isSymbolicLink(file.toPath()) || file.length() > LIMIT) throw TeamDraftFailure("comment_save_failed")
        // Bound the read even when a file changes after the length check.
        val bytes = file.inputStream().use { stream ->
            val buffer = ByteArray(LIMIT + 1); var length = 0
            while (length < buffer.size) { val count = stream.read(buffer, length, buffer.size - length); if (count < 0) break; length += count }
            buffer.copyOf(length)
        }
        if (bytes.size > LIMIT) throw TeamDraftFailure("comment_save_failed")
        val e = json.decodeFromString<Envelope>(bytes.toString(Charsets.UTF_8))
        valid(e.target)
        val d = e.draft
        if (e.version != 1 || runCatching { UUID.fromString(d.revision) }.isFailure || d.text.toByteArray().size > 64 * 1024 || d.label.toByteArray().size > 2560 ||
            d.attempt?.let { runCatching { UUID.fromString(it.id) }.isFailure || it.createdAtMs <= 0 || !d.canSend } == true) throw TeamDraftFailure("comment_save_failed")
        return e
    }
    private fun read(owner: File, t: TeamCommentTarget): TeamCommentDraft? {
        val e = read(File(owner, name(t))) ?: return null
        if (e.target != t) throw TeamDraftFailure("comment_save_failed")
        return e.draft
    }
    private fun write(owner: File, t: TeamCommentTarget, draft: TeamCommentDraft?) {
        val file = File(owner, name(t))
        if (draft == null) {
            Files.deleteIfExists(file.toPath())
        } else {
            if (draft.text.toByteArray().size > 64 * 1024) throw TeamDraftFailure("comment_too_long")
            val bytes = json.encodeToString(Envelope(1, t, draft)).toByteArray()
            if (bytes.size > LIMIT) throw TeamDraftFailure("comment_too_long")
            val temp = File(owner, ".${UUID.randomUUID()}.tmp")
            try {
                Files.createFile(temp.toPath())
                FileOutputStream(temp).use { it.write(bytes); it.fd.sync() }
                Files.move(temp.toPath(), file.toPath(), StandardCopyOption.ATOMIC_MOVE, StandardCopyOption.REPLACE_EXISTING)
            } finally { temp.delete() }
        }
        // The attempt's rename is durable before the caller sends anything.
        FileChannel.open(owner.toPath(), StandardOpenOption.READ).use { it.force(true) }
    }
    fun load(t: TeamCommentTarget): TeamCommentDraft? = locked(t) { read(it, t) }
    fun remember(t: TeamCommentTarget, text: String, expected: TeamCommentDraft?, label: String) = synchronized(gate) { unsaved[t] = TeamCommentUnsaved(text, expected, label) }
    fun unsaved(t: TeamCommentTarget): TeamCommentUnsaved? = synchronized(gate) { unsaved[t] }
    fun forgetUnsaved(t: TeamCommentTarget) = synchronized(gate) { unsaved.remove(t); Unit }
    fun save(t: TeamCommentTarget, text: String, expected: TeamCommentDraft?, label: String): TeamCommentDraft? = synchronized(gate) {
        try {
            val next = locked(t) { owner ->
                val current = read(owner, t)
                if (current != expected) throw TeamDraftFailure("comment_draft_changed")
                if (current?.attempt != null) throw TeamDraftFailure("comment_check_first")
                if (current?.text == text) return@locked current
                val value = if (text.isEmpty()) null else TeamCommentDraft(UUID.randomUUID().toString(), text, null, label)
                write(owner, t, value); value
            }
            unsaved.remove(t); next
        } catch (failure: Throwable) { unsaved[t] = TeamCommentUnsaved(text, expected, label); throw failure }
    }
    fun reserve(t: TeamCommentTarget, expected: TeamCommentDraft): TeamCommentDraft = locked(t) { owner ->
        if (read(owner, t) != expected) throw TeamDraftFailure("comment_draft_changed")
        if (!expected.canSend) throw TeamDraftFailure("comment_too_long")
        if (expected.attempt != null) return@locked expected
        val next = expected.copy(revision = UUID.randomUUID().toString(), attempt = TeamCommentAttempt(UUID.randomUUID().toString(), System.currentTimeMillis()))
        write(owner, t, next); next
    }
    fun resolve(t: TeamCommentTarget, expected: TeamCommentDraft, receipt: JsonObject): TeamCommentDraft? = locked(t) { owner ->
        val state = receiptState(t, expected, receipt)
        val current = read(owner, t)
        if (current == null && state == "accepted") return@locked null
        if (current != expected) throw TeamDraftFailure("comment_draft_changed")
        if (state in setOf("pending", "unknown")) return@locked expected
        val next = if (state == "accepted") null else expected.copy(revision = UUID.randomUUID().toString(), attempt = null)
        write(owner, t, next); next
    }
    fun list(origin: String, person: String, after: String? = null): TeamCommentDraftPage = locked(TeamCommentTarget(origin, person, "list", "list", "list", "list", "list")) { owner ->
        val recovery = unsaved.filterKeys { it.origin == origin && it.person == person }.mapKeys { name(it.key) }
        val candidates = java.util.TreeSet<String>()
        fun candidate(name: String) {
            if (!name.endsWith(".json") || after != null && name <= after) return
            candidates.add(name); if (candidates.size > 201) candidates.pollLast()
        }
        Files.newDirectoryStream(owner.toPath()).use { files -> files.forEach { candidate(it.fileName.toString()) } }
        recovery.keys.forEach(::candidate)
        val names = candidates.toList()
        val entries = mutableListOf<TeamCommentRecovery>(); var visited = 0; var unreadable = false
        for (name in names) {
            visited++
            try {
                val e = read(File(owner, name))
                val t = e?.target ?: unsaved.keys.first { name(it) == name }
                if (t.origin != origin || t.person != person || name(t) != name) throw TeamDraftFailure("comment_save_failed")
                entries += TeamCommentRecovery(t, e?.draft, recovery[name])
            } catch (_: Exception) {
                unreadable = true
                unsaved.keys.firstOrNull { name(it) == name }?.let { entries += TeamCommentRecovery(it, unsaved[it]?.expected, unsaved[it]) }
            }
            if (entries.size == 40 || visited == 200) break
        }
        TeamCommentDraftPage(entries, if (visited < names.size) names[visited - 1] else null, unreadable)
    }
    fun discard(entry: TeamCommentRecovery) = locked(entry.target) { owner ->
        if (read(owner, entry.target) != entry.draft || unsaved[entry.target] != entry.unsaved) throw TeamDraftFailure("comment_draft_changed")
        write(owner, entry.target, null); unsaved.remove(entry.target); Unit
    }
}

internal fun receiptState(t: TeamCommentTarget, expected: TeamCommentDraft, receipt: JsonObject): String {
    fun str(key: String) = (receipt[key] as? JsonPrimitive)?.takeIf { it.isString }?.content
    val state = str("state")
    val a = expected.attempt
    val seq = receipt["sequence"]
    val time = receipt["acceptedAtMs"]
    if (a == null || str("shareId") != t.share || str("clientMessageId") != a.id || state !in setOf("unknown", "pending", "accepted", "notAccepted") ||
        (if (state == "accepted") (seq as? JsonPrimitive)?.takeIf { !it.isString }?.content?.toULongOrNull() == null ||
            (time as? JsonPrimitive)?.takeIf { !it.isString }?.longOrNull?.let { it > 0 } != true else seq != null && seq != JsonNull || time != null && time != JsonNull)) throw TeamDraftFailure("comment_unconfirmed")
    return state!!
}
