// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.team

import ai.tokenstat.tokenstat.core.CoreFailure
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import kotlinx.coroutines.CancellationException
import kotlinx.serialization.json.*

/** Viewing an invitation does not join or grant anything. Acceptance uses
 * only its reviewed identity, and never navigates to a different team reply. */
internal class TeamInboxModel(private val calls: TeamCalls) {
    var page by mutableStateOf(TeamManagementPage()); private set
    var busy by mutableStateOf(false); private set
    var joining by mutableStateOf(false); private set
    var error by mutableStateOf<String?>(null); private set
    var selected by mutableStateOf<String?>(null); private set
    var preview by mutableStateOf<JsonObject?>(null); private set
    private var generation = 0L
    val canJoin get() = !busy && !joining && preview?.let {
        it["eligible"] == JsonPrimitive(true) && it["available"] == JsonPrimitive(true) && (it["invitation"] as? JsonObject)?.teamString("state") == "pending"
    } == true
    private suspend fun request(operation: String, fields: JsonObject = buildJsonObject {}): JsonObject = calls.call("teams.directory", buildJsonObject {
        put("operation", operation); fields.forEach { (key, value) -> put(key, value) }
    })
    suspend fun load(more: Boolean = false) {
        if (busy || joining) return
        val offset = if (more) page.next ?: return else 0
        busy = true; error = null
        try {
            val next = TeamDirectoryPage.read(request("inbox.list", buildJsonObject { put("page", buildJsonObject { put("limit", 100); put("offset", offset) }) }), "invitations", offset)
            page = TeamManagementPage(if (more) TeamCatalogPage.append(page.rows, next.rows) else next.rows, next.next, true)
        } catch (cancelled: CancellationException) { throw cancelled }
        catch (failure: Exception) { error = if (failure is CoreFailure) failure.message else "load_failed" }
        finally { busy = false }
    }
    fun close() { if (!joining) { generation++; selected = null; preview = null; busy = false; error = null } }
    suspend fun review(id: String) {
        if (joining) return
        val ticket = ++generation
        selected = id; preview = null; busy = true; error = null
        try {
            val result = request("inbox.get", buildJsonObject { put("invitation", id) })
            if (generation != ticket || selected != id) return
            val invitation = result["invitation"] as? JsonObject ?: error("Missing invitation")
            require(invitation.teamString("id") == id && invitation.teamString("organizationId")?.isNotBlank() == true)
            require(invitation.teamString("role") in setOf("member", "admin"))
            val access = result["repositoryAccess"] as? JsonArray ?: error("Missing access review")
            require(access.size <= 50 && access.all { row -> row is JsonObject && row.teamString("repositoryId")?.isNotBlank() == true && row.teamString("name")?.isNotBlank() == true && row.teamString("role") in setOf("viewer", "contributor", "maintainer") })
            require(access.map { it.jsonObject.teamString("repositoryId") }.distinct().size == access.size)
            require(result["eligible"] in setOf(JsonPrimitive(true), JsonPrimitive(false)) && result["available"] in setOf(JsonPrimitive(true), JsonPrimitive(false)))
            preview = result
        } catch (cancelled: CancellationException) { throw cancelled }
        catch (failure: Exception) { if (ticket == generation) error = if (failure is CoreFailure) failure.message else "load_failed" }
        finally { if (ticket == generation) busy = false }
    }
    suspend fun accept(): JsonObject? {
        if (!canJoin) return null
        val id = selected ?: return null
        val reviewed = preview ?: return null
        val organization = reviewed["invitation"]!!.jsonObject.teamString("organizationId")!!
        joining = true; error = null
        try {
            val answer = request("inbox.accept", buildJsonObject { put("invitation", id) })
            require(answer["joined"] == JsonPrimitive(true) && answer.teamString("organizationId") == organization)
            val details = calls.call("teams.directory", buildJsonObject { put("operation", "organizations.get"); put("organization", organization) })
            val result = details["organization"] as? JsonObject ?: error("Missing Team")
            require(result.teamString("id") == organization)
            return result
        } catch (cancelled: CancellationException) { throw cancelled }
        catch (failure: Exception) { error = if (failure is CoreFailure) failure.message else "load_failed"; return null }
        finally { joining = false }
    }
}
