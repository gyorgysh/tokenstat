// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.team

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import kotlinx.coroutines.*
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.serialization.json.*

internal class TeamCommentModel(private val storage: TeamCommentDraftStore, private val target: TeamCommentTarget, private val label: String,
    private val call: suspend (String, JsonObject) -> JsonObject) {
    var text by mutableStateOf(""); private set
    var recoveredText by mutableStateOf<String?>(null); private set
    var draft by mutableStateOf<TeamCommentDraft?>(null); private set
    var loaded by mutableStateOf(false); private set
    var busy by mutableStateOf(false); private set
    var error by mutableStateOf<String?>(null); private set
    var status by mutableStateOf<String?>(null); private set
    val pending get() = draft?.attempt != null
    val tooLong get() = text.isNotBlank() && !TeamCommentDraft("", text, draft?.attempt, label).canSend
    val canSend get() = loaded && !busy && recoveredText == null && TeamCommentDraft("", text, draft?.attempt, label).canSend
    // An app-owned save finishes when its view leaves. It has no network
    // retry loop; send/check are always explicit actions.
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private var autosave: Job? = null
    private val saving = Mutex()
    suspend fun restore() {
        if (loaded) return
        try {
            val saved = withContext(Dispatchers.IO) { storage.load(target) }
            val unsaved = storage.unsaved(target)
            draft = saved
            if (unsaved != null && unsaved.expected != saved) { text = saved?.text.orEmpty(); recoveredText = unsaved.text }
            else text = unsaved?.text ?: saved?.text.orEmpty()
            loaded = true
            error = if (unsaved == null) null else if (recoveredText == null) "comment_save_failed" else "comment_draft_changed"
            if (pending) status = "comment_unconfirmed"
        } catch (cancelled: CancellationException) { throw cancelled }
        catch (_: Exception) { error = "comment_save_failed" }
    }
    fun edit(value: String) {
        if (!loaded || busy || pending || recoveredText != null) return
        text = value; status = null
        storage.remember(target, text, draft, label)
        autosave?.cancel()
        autosave = scope.launch {
            try { delay(350); flush() }
            catch (cancelled: CancellationException) { throw cancelled }
            catch (e: Exception) { error = (e as? TeamDraftFailure)?.key ?: "comment_save_failed" }
        }
    }
    fun leave() {
        autosave?.cancel()
        scope.launch {
            try { flush() } catch (_: Exception) { /* Storage retains the unsaved copy. */ }
        }
    }
    private suspend fun flush() = saving.withLock {
        if (!loaded || pending) return@withLock
        if (recoveredText != null) throw TeamDraftFailure("comment_draft_changed")
        while (draft?.text != text && !(draft == null && text.isEmpty())) {
            val words = text; val expected = draft
            // Once a local write starts it settles before another flush uses
            // its expected revision, even if the debounce is cancelled.
            withContext(NonCancellable) {
                draft = withContext(Dispatchers.IO) { storage.save(target, words, expected, label) }
            }
        }
        storage.forgetUnsaved(target); error = null
    }
    suspend fun send() {
        if (!canSend) return
        busy = true; error = null; status = null; autosave?.cancel()
        try {
            flush()
            val saved = draft ?: throw TeamDraftFailure("comment_save_failed")
            val reserved = withContext(NonCancellable) {
                withContext(Dispatchers.IO) { storage.reserve(target, saved) }.also { draft = it }
            }
            currentCoroutineContext().ensureActive()
            val response = call("teams.comment.send", buildJsonObject { put("target", fields()); put("input", reserved.input!!) })
            accept(response["receipt"] as? JsonObject ?: throw TeamDraftFailure("comment_unconfirmed"), reserved)
        } catch (cancelled: CancellationException) { if (pending) status = "comment_unconfirmed"; throw cancelled }
        catch (e: Exception) { error = (e as? TeamDraftFailure)?.key ?: if (pending) null else "comment_save_failed"; if (pending) status = "comment_unconfirmed" }
        finally { busy = false }
    }
    suspend fun check() {
        val expected = draft ?: return
        val a = expected.attempt ?: return
        if (!loaded || busy) return
        busy = true; error = null
        try {
            val response = call("teams.connection.call", buildJsonObject {
                put("target", fields()); put("method", "team.chat.receipt"); put("params", buildJsonObject { put("clientMessageId", a.id) })
            })
            accept(response["receipt"] as? JsonObject ?: throw TeamDraftFailure("comment_unconfirmed"), expected)
        } catch (cancelled: CancellationException) { throw cancelled }
        catch (e: Exception) { error = (e as? TeamDraftFailure)?.key ?: "comment_unconfirmed" }
        finally { busy = false }
    }
    private suspend fun accept(receipt: JsonObject, expected: TeamCommentDraft) {
        val state = receiptState(target, expected, receipt)
        withContext(NonCancellable) {
            draft = withContext(Dispatchers.IO) { storage.resolve(target, expected, receipt) }
            text = draft?.text.orEmpty()
            status = when (state) { "accepted" -> "comment_posted"; "notAccepted" -> "comment_not_accepted"; else -> "comment_unconfirmed" }
        }
    }
    suspend fun reload() {
        if (busy) return
        busy = true
        autosave?.cancel()
        try { saving.withLock {
            try {
                draft = withContext(Dispatchers.IO) { storage.load(target) }
                storage.forgetUnsaved(target); text = draft?.text.orEmpty(); recoveredText = null; loaded = true; error = null
                status = if (pending) "comment_unconfirmed" else null
            } catch (cancelled: CancellationException) { throw cancelled }
            catch (_: Exception) { error = "comment_save_failed" }
        } } finally { busy = false }
    }
    private fun fields() = buildJsonObject { put("organization", target.organization); put("repository", target.repository); put("checkout", target.checkout); put("share", target.share) }
}
