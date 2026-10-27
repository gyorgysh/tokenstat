// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.team

import ai.tokenstat.tokenstat.core.CoreFailure
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import kotlinx.coroutines.CancellationException
import kotlinx.serialization.json.*

internal fun JsonObject.teamString(key: String) = (this[key] as? JsonPrimitive)?.takeIf { it.isString }?.content
/**
 * A project whose last computer stopped sharing stays in the team until an
 * admin removes it. An older account server sends no count, and then every
 * project reads as shared, as it always did.
 */
internal fun JsonObject.teamShared(): Boolean = (this["activeCheckouts"] as? JsonPrimitive)?.takeIf { !it.isString }?.longOrNull?.let { it > 0 } ?: true
internal fun JsonObject.teamRevision(): Long = (this["revision"] as? JsonPrimitive)?.takeIf { !it.isString }?.longOrNull?.takeIf { it >= 0 }
    ?: throw IllegalArgumentException("Invalid Team revision")
internal fun teamNameValid(value: String) = value.trim().isNotEmpty() && value.trim().length <= 80
internal fun teamSuggestedSlug(value: String): String = java.text.Normalizer.normalize(value, java.text.Normalizer.Form.NFKD)
    .lowercase(java.util.Locale.ROOT).replace(Regex("\\p{M}+"), "").replace(Regex("[^a-z0-9]+"), "-").take(48).trim('-')
internal fun teamSlugValid(value: String) = value.matches(Regex("[a-z][a-z0-9-]{1,46}[a-z0-9]")) && !value.contains("--")
internal fun teamHandle(value: String) = value.trim().removePrefix("@").lowercase(java.util.Locale.ROOT)
internal fun teamHandleValid(value: String) = teamHandle(value).matches(Regex("[a-z0-9][a-z0-9-]{1,31}"))

internal data class TeamManagementPage(val rows: List<JsonObject> = emptyList(), val next: Int? = null, val loaded: Boolean = false)

/** Native management keeps the exact organization, person and reviewed row
 * revision. The service remains authoritative for every permission change. */
internal class TeamManagementModel(private val calls: TeamCalls, initial: JsonObject) {
    val organizationId = initial.teamString("id") ?: error("Missing Team")
    var organization by mutableStateOf(initial); private set
    var verified by mutableStateOf(false); private set
    var ownershipRequest by mutableStateOf<JsonObject?>(null); private set
    var members by mutableStateOf(TeamManagementPage()); private set
    var repositories by mutableStateOf(TeamManagementPage()); private set
    var invitations by mutableStateOf(TeamManagementPage()); private set
    var busy by mutableStateOf(false); private set
    var error by mutableStateOf<String?>(null); private set
    val role get() = organization.teamString("role")
    val active get() = verified && organization.teamString("state") == "active" && organization["eligible"] == JsonPrimitive(true)
    val manager get() = active && role in setOf("owner", "admin")
    val owner get() = active && role == "owner"
    val currentOwner get() = verified && role == "owner"

    private suspend fun request(operation: String, fields: JsonObject = buildJsonObject {}): JsonObject = calls.call("teams.directory", buildJsonObject {
        put("operation", operation); put("organization", organizationId)
        fields.forEach { (key, value) -> put(key, value) }
    })
    suspend fun refresh(section: String, more: Boolean = false) {
        if (busy) return
        busy = true; error = null
        try {
            if (!more) {
                verified = false
                val details = request("organizations.get")
                val fresh = details["organization"] as? JsonObject ?: error("Missing Team")
                require(fresh.teamString("id") == organizationId)
                fresh.teamRevision()
                organization = fresh; ownershipRequest = details["ownershipRequest"]?.takeUnless { it == JsonNull }?.jsonObject; verified = true
                if (!manager) invitations = TeamManagementPage(loaded = true)
            }
            val old = when (section) { "members" -> members; "repositories" -> repositories; "invitations" -> invitations; else -> return }
            if (section == "invitations" && !manager) return
            val offset = if (more) old.next ?: return else 0
            val page = TeamDirectoryPage.read(request("$section.list", buildJsonObject { put("page", buildJsonObject { put("limit", 100); put("offset", offset) }) }), section, offset)
            if (section != "members") require(page.rows.all { it.teamString("organizationId") == organizationId })
            val next = TeamManagementPage(if (more) TeamCatalogPage.append(old.rows, page.rows) else page.rows, page.next, true)
            when (section) { "members" -> members = next; "repositories" -> repositories = next; "invitations" -> invitations = next }
        } catch (cancelled: CancellationException) { throw cancelled }
        catch (failure: Exception) { error = if (failure is CoreFailure) failure.message else "load_failed" }
        finally { busy = false }
    }
    private fun person(member: JsonObject): String {
        require(member.teamString("id")?.isNotBlank() == true)
        return member.teamString("id")!!
    }
    fun rename(name: String): JsonObject {
        require(manager && teamNameValid(name))
        return buildJsonObject { put("name", name.trim()); put("expectedRevision", organization.teamRevision()) }
    }
    fun memberRole(member: JsonObject, role: String): JsonObject {
        require(owner && person(member) != calls.person && member.teamString("role") in setOf("member", "admin") && role in setOf("admin", "member"))
        return buildJsonObject { put("role", role); put("expectedRevision", member.teamRevision()) }
    }
    fun removeMember(member: JsonObject): JsonObject {
        require(manager && person(member) != calls.person && member.teamString("role") in setOf("member", "admin") && (owner || member.teamString("role") == "member"))
        return buildJsonObject { put("expectedRevision", member.teamRevision()) }
    }
    fun invite(handle: String, role: String, assignments: Map<String, String>): JsonObject {
        require(manager && teamHandleValid(handle) && (role == "member" || owner && role == "admin") && assignments.size <= 50)
        require(assignments.all { (id, role) -> repositories.rows.any { it.teamString("id") == id } && role in setOf("viewer", "contributor", "maintainer") })
        return buildJsonObject {
            put("handle", teamHandle(handle)); put("role", role)
            put("assignments", JsonArray(assignments.toSortedMap().map { (id, access) -> buildJsonObject { put("repositoryId", id); put("role", access) } }))
        }
    }
    fun access(repository: JsonObject, member: JsonObject, role: String?): JsonObject {
        require(active && (manager || repository.teamString("role") == "maintainer") && repository.teamString("organizationId") == organizationId)
        require(role == null || role in setOf("viewer", "contributor", "maintainer")); person(member)
        return buildJsonObject { put("role", role?.let(::JsonPrimitive) ?: JsonNull); put("expectedRevision", member.teamRevision()) }
    }
    private fun originalOrganization(expected: JsonObject) {
        require(verified && expected.teamString("id") == organizationId && expected.teamRevision() == organization.teamRevision())
    }
    fun transfer(member: JsonObject, expected: JsonObject): JsonObject {
        originalOrganization(expected)
        require(currentOwner && person(member) != organization.teamString("ownerId") && member["ownershipEligible"] == JsonPrimitive(true))
        return buildJsonObject { put("userId", person(member)); put("expectedRevision", expected.teamRevision()) }
    }
    fun deleteOrganization(confirmation: String, expected: JsonObject): JsonObject {
        originalOrganization(expected)
        require(currentOwner && confirmation == expected.teamString("name"))
        return buildJsonObject { put("confirmName", confirmation); put("expectedRevision", expected.teamRevision()) }
    }
    fun leave(expected: JsonObject): JsonObject {
        originalOrganization(expected)
        require(role in setOf("member", "admin") && calls.person?.isNotBlank() == true)
        val revision = (expected["membershipRevision"] as? JsonPrimitive)?.takeIf { !it.isString }?.longOrNull ?: error("Missing membership revision")
        require(revision > 0 && expected["membershipRevision"] == organization["membershipRevision"])
        return buildJsonObject { put("expectedRevision", revision) }
    }
    fun ownershipDecision(reviewed: JsonObject, cancelling: Boolean): JsonObject {
        require(verified && reviewed == ownershipRequest && reviewed.teamString("requestId")?.isNotBlank() == true)
        if (cancelling) require(currentOwner && reviewed.teamString("fromUserId") == calls.person)
        else require(reviewed.teamString("toUserId") == calls.person && reviewed["current"] == JsonPrimitive(true))
        return buildJsonObject { put("requestId", reviewed.teamString("requestId")); put("expectedRevision", reviewed.teamRevision()) }
    }
    suspend fun mutate(operation: String, input: JsonObject, user: String? = null, repository: String? = null, invitation: String? = null): JsonObject {
        check(!busy && verified)
        require(operation in setOf("organizations.rename", "members.role", "members.remove", "invitations.create", "invitations.renew", "invitations.revoke", "repositories.access", "repositories.archive", "organizations.delete", "ownership.request", "ownership.accept", "ownership.cancel"))
        when (operation) {
            "members.role" -> require(owner)
            "members.remove" -> if (user == calls.person) require(verified && role in setOf("member", "admin")) else require(manager)
            "organizations.delete", "ownership.request" -> require(currentOwner)
            "ownership.accept" -> { ownershipDecision(ownershipRequest ?: error("Missing request"), false) }
            "ownership.cancel" -> { ownershipDecision(ownershipRequest ?: error("Missing request"), true) }
            "repositories.access" -> require(active && (manager || repositories.rows.any { it.teamString("id") == repository && it.teamString("role") == "maintainer" }))
            "repositories.archive" -> require(active && manager && repositories.rows.any { it.teamString("id") == repository && !it.teamShared() })
            else -> require(manager)
        }
        busy = true; error = null
        try {
            return request(operation, buildJsonObject {
                put("input", input); user?.let { put("user", it) }; repository?.let { put("repository", it) }; invitation?.let { put("invitation", it) }
            })
        } catch (cancelled: CancellationException) { throw cancelled }
        catch (failure: Exception) { error = if (failure is CoreFailure) failure.message else "load_failed"; throw failure }
        finally { busy = false }
    }
    suspend fun repositoryMembers(repository: JsonObject, offset: Int = 0): TeamDirectoryPage {
        require(repository.teamString("organizationId") == organizationId && (manager || repository.teamString("role") == "maintainer"))
        return TeamDirectoryPage.read(request("repositories.members", buildJsonObject {
            put("repository", repository.teamString("id")!!); put("page", buildJsonObject { put("limit", 100); put("offset", offset) })
        }), "members", offset)
    }
}
