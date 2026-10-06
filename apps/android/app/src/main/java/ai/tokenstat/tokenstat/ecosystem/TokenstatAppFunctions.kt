// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ecosystem

import androidx.annotation.RequiresApi
import androidx.appfunctions.*
import ai.tokenstat.tokenstat.core.CoreClient
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import kotlinx.serialization.json.*

@AppFunctionSerializable
data class ProjectFunctionResult(val id: String, val name: String, val computer: String, val url: String)

@AppFunctionSerializable
data class UsageFunctionResult(val period: String, val valueUsd: Double, val fetchedAtMs: Long, val refreshFailed: Boolean)

/** Available only through Android's permission-protected service on supporting systems. */
@RequiresApi(36)
@AppFunctionServiceEntryPoint(serviceName = "TokenstatAppFunctionService", appFunctionXmlFileName = "tokenstat_functions")
abstract class BaseTokenstatAppFunctionService : AppFunctionService() {
    private suspend fun verify(): String {
        val epoch = UsageWidgetStore.epoch()
        val account = CoreClient.call("account.status") as? JsonObject
            ?: throw AppFunctionAppUnknownException("The account could not be verified. Open tokenstat and try again.")
        val owner = UsageSnapshot.owner(account) ?: throw AppFunctionPermissionRequiredException("Sign in to tokenstat first.")
        if (UsageWidgetStore.verify(this, account, epoch) == null)
            throw AppFunctionPermissionRequiredException("Open tokenstat to verify this account first.")
        SystemProjects.verify(this, account)
        return owner
    }

    /**
     * Finds the signed-in person's known projects and returns links to open them in tokenstat.
     * Only local project metadata is searched. No files or conversation content are returned.
     * @param query Project or computer name. An empty query returns recent projects.
     */
    @AppFunction(isDescribedByKDoc = true)
    suspend fun searchProjects(query: String): List<ProjectFunctionResult> = withContext(Dispatchers.IO) {
        withTimeout(15_000) {
            val owner = verify()
            SystemProjects.search(query.take(200)).filter { it.owner == owner }.map {
                ProjectFunctionResult(it.id, it.name, it.hostName, it.uri.toString())
            }
        }
    }

    /**
     * Reads cached account usage at published API list rates, including its original fetch time.
     * This is an estimated value of usage, not a bill or subscription charge.
     * @param period Either today or week (the last seven calendar days).
     */
    @AppFunction(isDescribedByKDoc = true)
    suspend fun getUsage(period: String): UsageFunctionResult = withContext(Dispatchers.IO) {
        withTimeout(15_000) {
            if (period !in setOf("today", "week")) throw AppFunctionInvalidArgumentException("period must be today or week")
            val owner = verify()
            val snapshot = UsageWidgetStore.read(this@BaseTokenstatAppFunctionService)?.takeIf { it.owner == owner }
                ?: throw AppFunctionAppUnknownException("Usage is unavailable. Open tokenstat to sync.")
            val amount = snapshot.value(period == "week")
                ?: throw AppFunctionAppUnknownException("Usage for this period is unavailable.")
            UsageFunctionResult(period, amount / 1_000_000.0,
                snapshot.updatedAt ?: throw AppFunctionAppUnknownException("The fetch time is unavailable."), snapshot.refreshFailed)
        }
    }

    /**
     * Creates a note in the chosen project on its computer. Does not execute an agent or command.
     * Call only when the person asks to save a note; use searchProjects to obtain the project id.
     * @param projectId Exact id returned by searchProjects.
     * @param title A short note title.
     * @param body The note content to save.
     * @return The created note's id.
     */
    @AppFunction(isDescribedByKDoc = true)
    suspend fun createNote(projectId: String, title: String, body: String): String = withContext(Dispatchers.IO) {
        withTimeout(15_000) {
            if (title.isBlank() || title.length > 200 || body.length > 100_000)
                throw AppFunctionInvalidArgumentException("A title of 1–200 characters and body under 100000 characters are required.")
            val owner = verify()
            val project = SystemProjects.find(projectId, owner)
                ?: throw AppFunctionInvalidArgumentException("That project is no longer available on this account.")
            if (SystemProjects.owner != owner || SystemProjects.find(projectId, owner) != project)
                throw AppFunctionPermissionRequiredException("This account or project is no longer available.")
            val result = CoreClient.remote(project.peer, "todo.create", buildJsonObject {
                put("workspaceId", project.workspaceId); put("kind", "note"); put("title", title.trim())
                put("notes", body); put("column", "backlog"); put("backend", ""); put("budgetSeconds", 0)
            }) as? JsonObject
            (result?.get("id") as? JsonPrimitive)?.contentOrNull
                ?: throw AppFunctionAppUnknownException("The computer did not confirm the note. Check the project before retrying.")
        }
    }
}
