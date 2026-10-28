// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.team

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import java.util.UUID
import kotlinx.coroutines.*
import kotlinx.serialization.json.*
import ai.tokenstat.tokenstat.core.CoreFailure

internal class TeamAskNotAccepted(message: String) : Exception(message)

internal class TeamAskModel(private val storage: TeamAskRecoveryStore, private val target: TeamCommentTarget, private val label: String,
    private val call: suspend (String, JsonObject) -> JsonObject) {
    var text by mutableStateOf("")
    var loaded by mutableStateOf(false); private set
    var busy by mutableStateOf(false); private set
    var stopping by mutableStateOf(false); private set
    var fence by mutableStateOf<JsonObject?>(null); private set
    var error by mutableStateOf<String?>(null); private set
    private var saved: TeamAskRecoveryStore.Snapshot? = null
    /**
     * The sharing computer holds this request until its owner answers. The
     * same request is sent again while this screen is open, until it starts,
     * is declined, or the owner's window to answer has passed.
     */
    var awaitingApproval by mutableStateOf(false); private set
    private var approvalSince: Long? = null
    val pending get() = saved != null && fence == null
    val canAsk get() = loaded && !busy && fence == null && text.isNotBlank() && text.toByteArray().size <= 8192
    private suspend fun replace(record: TeamAskRecord?) = withContext(NonCancellable) {
        saved = withContext(Dispatchers.IO) { storage.replace(target, record, saved, label) }
    }
    suspend fun restore(force: Boolean = false) {
        if (loaded && !force || busy || fence != null) return
        busy = true
        try {
            val restored = withContext(Dispatchers.IO) { storage.load(target) }
            saved = restored; fence = restored?.record?.fence; text = restored?.record?.text.orEmpty(); loaded = true
            error = if (pending) "ask_unconfirmed" else null
        } catch (cancelled: CancellationException) { throw cancelled }
        catch (_: Exception) { loaded = false; error = "ask_save_failed" }
        finally { busy = false }
    }
    suspend fun ask() {
        if (!canAsk) return
        busy = true; error = null; awaitingApproval = false
        try {
            if (saved == null) {
                val review = call("team.chat.ask.review", buildJsonObject {})
                if (review["agentRuns"] != JsonPrimitive(true)) { error = "agent_runs_off"; return }
                replace(TeamAskRecord(buildJsonObject {
                    put("text", text.trim()); put("review", review["review"] ?: JsonNull)
                    put("clientMessageId", UUID.randomUUID().toString()); put("clientMessageCreatedAtMs", System.currentTimeMillis())
                }))
            }
            currentCoroutineContext().ensureActive()
            val original = saved ?: throw IllegalStateException("Missing durable Ask")
            val response = call("team.chat.ask", original.record.input)
            val running = response["fence"] as? JsonObject
            if (response["state"] == JsonPrimitive("running") && running != null && TeamAskRecord.validFence(running)) {
                fence = running // Retain Stop if saving the running reply fails.
                replace(original.record.copy(fence = running)); text = ""
            } else if (original.record.terminal(response, target.share)) { replace(null); text = "" }
            else error = "ask_unconfirmed"
        } catch (refusal: TeamAskNotAccepted) {
            try { replace(null); error = refusal.message } catch (_: Exception) { error = "ask_save_failed" }
        } catch (cancelled: CancellationException) { throw cancelled }
        catch (failure: Exception) {
            if (failure is CoreFailure && failure.code == "team_agent_approval_pending") {
                val since = approvalSince ?: System.currentTimeMillis().also { approvalSince = it }
                if (System.currentTimeMillis() - since >= 15 * 60 * 1000L) { approvalSince = null; error = "agent_approval_expired" }
                else { awaitingApproval = true; error = "agent_waiting_approval" }
            } else error = if (failure is TeamDraftFailure || failure is IllegalArgumentException) "ask_save_failed" else failure.message ?: "ask_unconfirmed"
        }
        finally { busy = false; if (!awaitingApproval) approvalSince = null }
        if (awaitingApproval) { delay(4000); if (awaitingApproval) ask() }
    }
    suspend fun check() {
        val running = fence ?: return
        if (busy) return
        try {
            val response = call("team.chat.ask.status", buildJsonObject { put("fence", running) })
            val active = (response["running"] as? JsonPrimitive)?.takeIf { !it.isString }?.booleanOrNull
            if (active == false && fence == running) { replace(null); fence = null; stopping = false; text = ""; error = null }
            else if (active == null) error = "run_status_unconfirmed"
            else if (error == "run_status_unconfirmed") error = null
        } catch (cancelled: CancellationException) { throw cancelled }
        catch (_: Exception) { error = "run_status_unconfirmed" }
    }
    suspend fun stop() {
        val running = fence ?: return
        if (stopping) return
        stopping = true; error = null
        try {
            val response = call("team.chat.ask.stop", buildJsonObject { put("fence", running) })
            require((response["stopping"] as? JsonPrimitive)?.takeIf { !it.isString }?.booleanOrNull != null)
        } catch (cancelled: CancellationException) { stopping = false; throw cancelled }
        catch (failure: Exception) { error = failure.message ?: "run_status_unconfirmed"; stopping = false }
    }
}
