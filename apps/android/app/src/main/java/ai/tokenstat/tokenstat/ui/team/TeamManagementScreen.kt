// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.team

import ai.tokenstat.tokenstat.core.CoreFailure
import ai.tokenstat.tokenstat.ui.components.*
import ai.tokenstat.tokenstat.ui.localization.L10n
import ai.tokenstat.tokenstat.ui.marks.Avatar
import ai.tokenstat.tokenstat.ui.theme.LocalTsColors
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.ClipEntry
import androidx.compose.ui.platform.LocalClipboard
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.platform.LocalSoftwareKeyboardController
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.launch
import kotlinx.serialization.json.*

private fun managementFailure(failure: Exception) = if (failure is CoreFailure) failure.message else L10n.text("common.teams.load_failed")
internal fun teamRoleLabel(role: String?): String = when (role) {
    "owner" -> L10n.text("common.teams.owner")
    "admin" -> L10n.text("common.teams.admin")
    "member" -> L10n.text("common.teams.member")
    "viewer" -> L10n.text("common.teams.viewer")
    "contributor" -> L10n.text("common.teams.contributor")
    "maintainer" -> L10n.text("common.teams.maintainer")
    else -> L10n.text("common.teams.no_access")
}
private fun invitationLabel(value: String?) = when (value) {
    "pending" -> L10n.text("common.teams.pending")
    "accepted" -> L10n.text("common.teams.accepted")
    "revoked" -> L10n.text("common.teams.revoked")
    "expired" -> L10n.text("common.teams.expired")
    else -> L10n.text("common.teams.invitation_unavailable")
}
private val teamIdentifierKeyboard = KeyboardOptions(capitalization = KeyboardCapitalization.None, autoCorrectEnabled = false, keyboardType = KeyboardType.Ascii)
@Composable private fun RolePicker(value: String?, choices: List<String?>, enabled: Boolean, onChange: (String?) -> Unit) {
    var open by remember { mutableStateOf(false) }
    Box {
        TsSecondaryButton(teamRoleLabel(value), enabled = enabled, icon = ActionIcon.Disclosure.vector, onClick = { open = true })
        DropdownMenu(expanded = open, onDismissRequest = { open = false }) {
            choices.forEach { choice -> DropdownMenuItem(text = { Text(teamRoleLabel(choice)) }, onClick = { open = false; onChange(choice) }) }
        }
    }
}
private sealed interface ManagementEdit {
    data object Rename : ManagementEdit
    data object Invite : ManagementEdit
    data class Role(val member: JsonObject) : ManagementEdit
    data class Remove(val member: JsonObject) : ManagementEdit
    data class Invitation(val invitation: JsonObject, val renew: Boolean) : ManagementEdit
    data class Access(val repository: JsonObject, val member: JsonObject) : ManagementEdit
}

@Composable internal fun TeamManagementScreen(calls: TeamCalls, initial: JsonObject, onGone: () -> Unit = {}, onBack: (JsonObject) -> Unit) {
    val model = remember(calls, initial.teamString("id")) { TeamManagementModel(calls, initial) }
    val scope = rememberCoroutineScope()
    val colors = LocalTsColors.current
    var section by remember(model) { mutableStateOf("members") }
    var edit by remember(model) { mutableStateOf<ManagementEdit?>(null) }
    var lifecycle by remember(model) { mutableStateOf<TeamLifecycleEdit?>(null) }
    var accessRepository by remember(model) { mutableStateOf<JsonObject?>(null) }
    var accessMembers by remember(model) { mutableStateOf(TeamManagementPage()) }
    var accessBusy by remember(model) { mutableStateOf(false) }
    var accessError by remember(model) { mutableStateOf<String?>(null) }
    var accessGeneration by remember(model) { mutableLongStateOf(0) }
    suspend fun loadAccess(repository: JsonObject, more: Boolean) {
        if (accessBusy) return
        val generation = ++accessGeneration
        accessBusy = true
        try {
            val page = model.repositoryMembers(repository, if (more) accessMembers.next ?: return else 0)
            if (generation != accessGeneration || accessRepository?.teamString("id") != repository.teamString("id")) return
            accessMembers = TeamManagementPage(if (more) TeamCatalogPage.append(accessMembers.rows, page.rows) else page.rows, page.next, true)
            accessError = null
        } catch (cancelled: CancellationException) { throw cancelled }
        catch (failure: Exception) { if (generation == accessGeneration) accessError = managementFailure(failure) }
        finally { if (generation == accessGeneration) accessBusy = false }
    }
    LaunchedEffect(model, section) { model.refresh(section) }
    val access = accessRepository
    LazyColumn(Modifier.fillMaxSize().padding(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        item {
            TsSecondaryButton(L10n.text("common.back"), enabled = !model.busy, icon = ActionIcon.Back.vector,
                onClick = { if (accessRepository != null) { accessGeneration++; accessBusy = false; accessError = null; accessRepository = null; accessMembers = TeamManagementPage() } else onBack(model.organization) })
            Text(access?.teamString("name") ?: model.organization.teamString("name").orEmpty(), style = TsType.cardTitle, color = colors.textPrimary)
            if (model.verified && !model.active) Text(L10n.text("common.teams.organization_paused"), color = colors.textSecondary)
            model.error?.let { Text(if (it == "load_failed") L10n.text("common.teams.load_failed") else it, color = colors.danger) }
            accessError?.let { Text(it, color = colors.danger) }
            if (model.busy || accessBusy) CircularProgressIndicator()
            if (access == null) FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                TsSecondaryButton(L10n.text("common.teams.members"), enabled = !model.busy, icon = ActionIcon.Profile.vector, onClick = { section = "members" })
                TsSecondaryButton(L10n.text("common.teams.repositories"), enabled = !model.busy, icon = ActionIcon.Source.vector, onClick = { section = "repositories" })
                if (model.manager) TsSecondaryButton(L10n.text("common.teams.invitations"), enabled = !model.busy, icon = ActionIcon.Send.vector, onClick = { section = "invitations" })
                TsSecondaryButton(L10n.text("common.settings"), enabled = !model.busy, icon = ActionIcon.Settings.vector, onClick = { section = "settings" })
                TsSecondaryButton(L10n.text("common.refresh"), enabled = !model.busy, icon = ActionIcon.Refresh.vector, onClick = { scope.launch { model.refresh(section) } })
            }
        }
        if (access == null) item { TeamOwnershipNotice(calls, model) { lifecycle = it } }
        if (access == null && model.manager && section in setOf("members", "invitations")) item {
            TsAccentButton(L10n.text("common.teams.invite_member"), enabled = !model.busy, icon = ActionIcon.Create.vector, onClick = {
                scope.launch { if (!model.repositories.loaded) model.refresh("repositories"); if (model.repositories.loaded && model.manager) edit = ManagementEdit.Invite }
            })
        }
        if (access != null) {
            item { Text(L10n.text("common.teams.execution_separate"), color = colors.textSecondary) }
            items(accessMembers.rows, key = { it.teamString("id")!! }) { member ->
                TsCard(title = member.teamString("name").orEmpty(), subtitle = teamRoleLabel(member.teamString("role"))) {
                    if (member["eligible"] != JsonPrimitive(true)) Text(L10n.text("common.teams.needs_patron"), color = colors.textSecondary)
                    TsSecondaryButton(L10n.text("common.teams.manage_access"), enabled = !model.busy && !accessBusy && model.active,
                        icon = ActionIcon.Security.vector, onClick = { edit = ManagementEdit.Access(access, member) })
                }
            }
            if (accessMembers.next != null || accessError != null) item {
                TsSecondaryButton(L10n.text(if (accessError != null) "common.retry" else "common.teams.load_more"), enabled = !accessBusy,
                    icon = ActionIcon.More.vector, onClick = { scope.launch { loadAccess(access, accessMembers.loaded && accessMembers.next != null) } })
            }
        } else when (section) {
            "members" -> {
                items(model.members.rows, key = { it.teamString("id")!! }) { member ->
                    TsCard(title = member.teamString("name").orEmpty(), subtitle = teamRoleLabel(member.teamString("role"))) {
                        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                            Avatar(name = member.teamString("name").orEmpty(), decorative = true)
                            member.teamString("handle")?.let { Text("@$it", color = colors.textSecondary) }
                        }
                        if (member["eligible"] != JsonPrimitive(true)) Text(L10n.text("common.teams.needs_patron"), color = colors.textSecondary)
                        val other = member.teamString("id") != calls.person && member.teamString("role") != "owner"
                        FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                            if (model.owner && other) TsSecondaryButton(L10n.text("common.teams.change_role"), enabled = !model.busy, icon = ActionIcon.Edit.vector, onClick = { edit = ManagementEdit.Role(member) })
                            if (model.manager && other && (model.owner || member.teamString("role") == "member")) TsDangerButton(L10n.text("common.teams.remove_member"), enabled = !model.busy, icon = ActionIcon.Revoke.vector, onClick = { edit = ManagementEdit.Remove(member) })
                        }
                    }
                }
            }
            "repositories" -> items(model.repositories.rows, key = { it.teamString("id")!! }) { repository ->
                TsCard(title = repository.teamString("name").orEmpty(), subtitle = teamRoleLabel(repository.teamString("role"))) {
                    if (model.manager || repository.teamString("role") == "maintainer") TsSecondaryButton(L10n.text("common.teams.repository_access"), enabled = !model.busy,
                        icon = ActionIcon.Security.vector, onClick = { accessRepository = repository; accessMembers = TeamManagementPage(); scope.launch { loadAccess(repository, false) } })
                }
            }
            "settings" -> item {
                if (model.manager) TsSecondaryButton(L10n.text("common.teams.rename_organization"), enabled = !model.busy, icon = ActionIcon.Edit.vector, onClick = { edit = ManagementEdit.Rename })
                TeamLifecycleSettings(model) { selected ->
                    if (selected is TeamLifecycleEdit.Transfer && !model.members.loaded) scope.launch {
                        model.refresh("members"); if (model.currentOwner) lifecycle = TeamLifecycleEdit.Transfer(model.organization)
                    } else lifecycle = selected
                }
            }
            "invitations" -> items(model.invitations.rows, key = { it.teamString("id")!! }) { invitation ->
                TsCard(title = (invitation["recipient"] as? JsonObject)?.teamString("name") ?: L10n.text("common.teams.member"), subtitle = invitationLabel(invitation.teamString("state"))) {
                    Text(teamRoleLabel(invitation.teamString("role")), color = colors.textSecondary)
                    if (model.manager && invitation.teamString("state") in setOf("pending", "expired")) FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        TsSecondaryButton(L10n.text("common.teams.new_invitation_link"), enabled = !model.busy, icon = ActionIcon.Refresh.vector, onClick = { edit = ManagementEdit.Invitation(invitation, true) })
                        if (invitation.teamString("state") == "pending") TsDangerButton(L10n.text("common.teams.revoke_invitation"), enabled = !model.busy, icon = ActionIcon.Revoke.vector, onClick = { edit = ManagementEdit.Invitation(invitation, false) })
                    }
                }
            }
        }
        if (access == null && section != "settings") {
            val page = when (section) { "members" -> model.members; "repositories" -> model.repositories; else -> model.invitations }
            if (page.loaded && page.rows.isEmpty() && model.error == null && !model.busy) item {
                if (section == "invitations") Text(L10n.text("common.teams.no_invitations"), color = colors.textSecondary)
                else if (section == "repositories") {
                    Text(L10n.text("common.teams.no_repositories"), color = colors.textSecondary)
                    Text(if (model.manager) L10n.text("common.teams.no_repositories_mobile") else L10n.text("common.teams.no_repositories_member"), color = colors.textSecondary)
                }
            }
            if (page.next != null || model.error != null) item {
                TsSecondaryButton(L10n.text(if (model.error != null) "common.retry" else "common.teams.load_more"), enabled = !model.busy,
                    icon = ActionIcon.More.vector, onClick = { scope.launch { model.refresh(section, page.loaded && page.next != null) } })
            }
        }
    }
    lifecycle?.let { selected ->
        key(selected) { TeamLifecycleDialog(calls, model, selected, onDismiss = { lifecycle = null }, onDone = {
            lifecycle = null; scope.launch { model.refresh(section) }
        }, onGone = onGone) }
    }
    edit?.let { selected ->
        key(selected) {
            ManagementDialog(calls, model, selected, onDismiss = { edit = null }, onDone = {
                edit = null
                scope.launch { if (access != null) loadAccess(access, false) else model.refresh(section) }
            })
        }
    }
}

@Composable private fun ManagementDialog(calls: TeamCalls, model: TeamManagementModel, edit: ManagementEdit, onDismiss: () -> Unit, onDone: () -> Unit) {
    val scope = rememberCoroutineScope()
    val clipboard = LocalClipboard.current
    val focus = LocalFocusManager.current
    val keyboard = LocalSoftwareKeyboardController.current
    val colors = LocalTsColors.current
    var name by remember { mutableStateOf(model.organization.teamString("name").orEmpty()) }
    var handle by remember { mutableStateOf("") }
    var role by remember { mutableStateOf(when (edit) { is ManagementEdit.Role -> edit.member.teamString("role"); is ManagementEdit.Access -> edit.member.teamString("role"); else -> "member" }) }
    var assignments by remember { mutableStateOf<Map<String, String>>(emptyMap()) }
    var failure by remember { mutableStateOf<String?>(null) }
    var link by remember { mutableStateOf<String?>(null) }
    val title = when (edit) {
        ManagementEdit.Rename -> L10n.text("common.teams.rename_organization")
        ManagementEdit.Invite -> L10n.text("common.teams.invite_member")
        is ManagementEdit.Role -> L10n.text("common.teams.change_role")
        is ManagementEdit.Remove -> L10n.text("common.teams.remove_member")
        is ManagementEdit.Access -> L10n.text("common.teams.repository_access")
        is ManagementEdit.Invitation -> if (edit.renew) L10n.text("common.teams.new_invitation_link") else L10n.text("common.teams.revoke_invitation")
    }
    val valid = !model.busy && when (edit) {
        ManagementEdit.Rename -> model.manager && teamNameValid(name) && name.trim() != model.organization.teamString("name")
        ManagementEdit.Invite -> model.manager && teamHandleValid(handle)
        is ManagementEdit.Role -> model.owner && role != edit.member.teamString("role")
        is ManagementEdit.Remove -> model.manager
        is ManagementEdit.Access -> model.active && role != edit.member.teamString("role")
        is ManagementEdit.Invitation -> model.manager
    }
    suspend fun save() {
        failure = null
        try {
            val reply = when (edit) {
                ManagementEdit.Rename -> model.mutate("organizations.rename", model.rename(name))
                ManagementEdit.Invite -> model.mutate("invitations.create", model.invite(handle, role ?: "member", assignments))
                is ManagementEdit.Role -> model.mutate("members.role", model.memberRole(edit.member, role ?: "member"), user = edit.member.teamString("id"))
                is ManagementEdit.Remove -> model.mutate("members.remove", model.removeMember(edit.member), user = edit.member.teamString("id"))
                is ManagementEdit.Access -> model.mutate("repositories.access", model.access(edit.repository, edit.member, role), user = edit.member.teamString("id"), repository = edit.repository.teamString("id"))
                is ManagementEdit.Invitation -> model.mutate(if (edit.renew) "invitations.renew" else "invitations.revoke", buildJsonObject { put("expectedRevision", edit.invitation.teamRevision()) }, invitation = edit.invitation.teamString("id"))
            }
            if (edit == ManagementEdit.Invite || edit is ManagementEdit.Invitation && edit.renew) {
                val url = reply.teamString("invitationURL") ?: error("Missing invitation link")
                val uri = java.net.URI(url); val origin = java.net.URI(calls.origin ?: error("Missing account"))
                require(uri.scheme == origin.scheme && uri.rawAuthority == origin.rawAuthority && uri.userInfo == null)
                link = url
            } else onDone()
        } catch (cancelled: CancellationException) { throw cancelled }
        catch (error: Exception) { failure = managementFailure(error) }
    }
    AlertDialog(onDismissRequest = { if (!model.busy) onDismiss() }, title = { Text(if (link != null) L10n.text("common.teams.invitation_ready") else title) }, text = {
        Column(Modifier.verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            failure?.let { Text(it, color = colors.danger) }
            if (link != null) {
                Text(L10n.text("common.teams.invitation_send_detail")); Text(link.orEmpty()); Text(L10n.text("common.teams.invitation_expiry"))
                TsSecondaryButton(L10n.text("common.copy"), icon = ActionIcon.Copy.vector, onClick = { scope.launch { clipboard.setClipEntry(ClipEntry(android.content.ClipData.newPlainText("", link.orEmpty()))) } })
            } else when (edit) {
                ManagementEdit.Rename -> OutlinedTextField(name, { name = it }, modifier = Modifier.testTag("team.management.name"), enabled = !model.busy, label = { Text(L10n.text("common.teams.organization_name")) })
                ManagementEdit.Invite -> {
                    OutlinedTextField(handle, { handle = it }, enabled = !model.busy, keyboardOptions = teamIdentifierKeyboard, label = { Text(L10n.text("common.teams.tokenstat_handle")) })
                    RolePicker(role, if (model.owner) listOf("member", "admin") else listOf("member"), !model.busy) { role = it }
                    Text(L10n.text("common.teams.invite_repository_detail"))
                    model.repositories.rows.forEach { repository ->
                        val id = repository.teamString("id")!!
                        Text(repository.teamString("name").orEmpty())
                        RolePicker(assignments[id], listOf(null, "viewer", "contributor", "maintainer"), !model.busy && (assignments.size < 50 || id in assignments)) { selected ->
                            assignments = assignments.toMutableMap().apply { if (selected == null) remove(id) else put(id, selected) }
                        }
                    }
                    if (model.repositories.next != null) TsSecondaryButton(L10n.text("common.teams.load_more"), enabled = !model.busy, icon = ActionIcon.More.vector, onClick = { scope.launch { model.refresh("repositories", true) } })
                    Text(L10n.text("common.teams.execution_separate"))
                }
                is ManagementEdit.Role -> {
                    Text(edit.member.teamString("name").orEmpty())
                    RolePicker(role, listOf("member", "admin"), !model.busy) { role = it }
                    Text(if (role == "admin") L10n.text("common.teams.admin_detail") else L10n.text("common.teams.member_detail"))
                    Text(L10n.text("common.teams.role_content_separate"))
                }
                is ManagementEdit.Remove -> { Text(edit.member.teamString("name").orEmpty()); Text(L10n.text("common.teams.remove_confirmation_detail")) }
                is ManagementEdit.Access -> {
                    Text(edit.repository.teamString("name").orEmpty()); Text(edit.member.teamString("name").orEmpty())
                    RolePicker(role, listOf(null, "viewer", "contributor", "maintainer"), !model.busy) { role = it }
                    Text(L10n.text("common.teams.execution_separate"))
                    if ((role == null || role == "viewer") && edit.member.teamString("role") in setOf("contributor", "maintainer")) Text(L10n.text("common.teams.access_reduction_detail"))
                }
                is ManagementEdit.Invitation -> Text(if (edit.renew) L10n.text("common.teams.renew_invitation_detail") else L10n.text("common.teams.revoke_invitation_detail"))
            }
        }
    }, confirmButton = {
        if (link != null) TsAccentButton(L10n.text("common.done"), icon = ActionIcon.Done.vector, onClick = onDone)
        else TsAccentButton(if (edit == ManagementEdit.Invite || edit is ManagementEdit.Remove || edit is ManagementEdit.Invitation) title else L10n.text("common.save"), enabled = valid,
            icon = if (edit is ManagementEdit.Remove || edit is ManagementEdit.Invitation && !edit.renew) ActionIcon.Revoke.vector else ActionIcon.Save.vector, onClick = { focus.clearFocus(); keyboard?.hide(); scope.launch { save() } })
    }, dismissButton = { if (link == null) TsSecondaryButton(L10n.text("common.cancel"), enabled = !model.busy, icon = ActionIcon.Dismiss.vector, onClick = onDismiss) })
}

@Composable internal fun TeamOrganizationNameDialog(calls: TeamCalls, onDismiss: () -> Unit, onCreated: (JsonObject) -> Unit) {
    val scope = rememberCoroutineScope()
    val focus = LocalFocusManager.current
    val keyboard = LocalSoftwareKeyboardController.current
    var name by remember { mutableStateOf("") }; var slug by remember { mutableStateOf("") }
    var busy by remember { mutableStateOf(false) }; var failure by remember { mutableStateOf<String?>(null) }
    AlertDialog(onDismissRequest = { if (!busy) onDismiss() }, title = { Text(L10n.text("common.teams.create_organization")) }, text = {
        Column(Modifier.verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            Text(L10n.text("common.teams.legend_creator"))
            OutlinedTextField(name, { value -> if (slug.isEmpty() || slug == teamSuggestedSlug(name)) slug = teamSuggestedSlug(value); name = value }, modifier = Modifier.testTag("team.management.name"), enabled = !busy, label = { Text(L10n.text("common.teams.organization_name")) })
            OutlinedTextField(slug, { slug = it }, modifier = Modifier.testTag("team.management.slug"), enabled = !busy, keyboardOptions = teamIdentifierKeyboard, label = { Text(L10n.text("common.teams.organization_address")) })
            Text(L10n.text("common.teams.address_detail")); failure?.let { Text(it, color = LocalTsColors.current.danger) }
        }
    }, confirmButton = {
        TsAccentButton(L10n.text("common.teams.create_organization"), enabled = !busy && teamNameValid(name) && teamSlugValid(slug), icon = ActionIcon.Create.vector, onClick = {
            focus.clearFocus(); keyboard?.hide()
            scope.launch {
                busy = true; failure = null
                try {
                    val reply = calls.call("teams.directory", buildJsonObject { put("operation", "organizations.create"); put("input", buildJsonObject { put("name", name.trim()); put("slug", slug) }) })
                    val created = reply["organization"] as? JsonObject ?: error("Missing Team")
                    require(created.teamString("id")?.isNotBlank() == true && created.teamString("ownerId") == calls.person && created.teamString("role") == "owner")
                    onCreated(created)
                } catch (cancelled: CancellationException) { throw cancelled }
                catch (error: Exception) { failure = managementFailure(error) }
                finally { busy = false }
            }
        })
    }, dismissButton = { TsSecondaryButton(L10n.text("common.cancel"), enabled = !busy, icon = ActionIcon.Dismiss.vector, onClick = onDismiss) })
}
