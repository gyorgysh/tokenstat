// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.team

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import kotlinx.coroutines.CancellationException
import kotlinx.serialization.json.*

/** Discovery is independent of the currently selected team. A new refresh
 * retires all older page completions without discarding visible offline rows. */
internal class TeamProjectsModel(private val calls: TeamCalls) {
    var organizations by mutableStateOf(TeamManagementPage()); private set
    var projects by mutableStateOf<Map<String, TeamManagementPage>>(emptyMap()); private set
    var organizationBusy by mutableStateOf(false); private set
    var organizationError by mutableStateOf<String?>(null); private set
    var loading by mutableStateOf<Set<String>>(emptySet()); private set
    var errors by mutableStateOf<Map<String, String>>(emptyMap()); private set
    var revision by mutableStateOf(0L); private set
    private var generation = 0L
    suspend fun loadOrganizations(more: Boolean = false) {
        if (organizationBusy) return
        val offset = if (more) organizations.next ?: return else 0
        val ticket = if (more) generation else ++generation
        organizationBusy = true
        if (!more) loading = emptySet()
        try {
            val page = TeamDirectoryPage.read(calls.directory("organizations.list", offset = offset), "organizations", offset)
            if (ticket != generation) return
            organizations = TeamManagementPage(if (more) TeamCatalogPage.append(organizations.rows, page.rows) else page.rows, page.next, true)
            organizationError = null
            if (!more) { projects = emptyMap(); errors = emptyMap(); revision++ }
        } catch (cancelled: CancellationException) { throw cancelled }
        catch (failure: Exception) { if (ticket == generation) organizationError = failure.message ?: "load_failed" }
        finally { if (ticket == generation) organizationBusy = false }
    }
    suspend fun loadProjects(organization: String, more: Boolean = false) {
        if (organization in loading || organizations.rows.none { it.teamString("id") == organization }) return
        val before = projects[organization] ?: TeamManagementPage()
        val offset = if (more) before.next ?: return else 0
        val ticket = generation
        loading = loading + organization
        try {
            val answer = calls.directory("repositories.list", offset = offset) { JsonObject(this + ("organization" to JsonPrimitive(organization))) }
            val page = TeamDirectoryPage.read(answer, "repositories", offset)
            require(page.rows.all { it.teamString("organizationId") == organization })
            if (ticket != generation) return
            val assigned = page.rows.filter { it.teamString("role") in setOf("viewer", "contributor", "maintainer") }
            projects = projects + (organization to TeamManagementPage(if (more) TeamCatalogPage.append(before.rows, assigned) else assigned, page.next, true))
            errors = errors - organization
        } catch (cancelled: CancellationException) { throw cancelled }
        catch (failure: Exception) { if (ticket == generation) errors = errors + (organization to (failure.message ?: "load_failed")) }
        finally { if (ticket == generation) loading = loading - organization }
    }
}
