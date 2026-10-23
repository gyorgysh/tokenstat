// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.team

import ai.tokenstat.tokenstat.core.CoreFailure
import ai.tokenstat.tokenstat.ui.components.*
import ai.tokenstat.tokenstat.ui.localization.L10n
import ai.tokenstat.tokenstat.ui.theme.LocalTsColors
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.selection.toggleable
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.launch
import kotlinx.serialization.json.*

internal sealed interface TeamLifecycleEdit {
    data class Transfer(val organization: JsonObject) : TeamLifecycleEdit
    data class Delete(val organization: JsonObject) : TeamLifecycleEdit
    data class Leave(val organization: JsonObject) : TeamLifecycleEdit
    data class Decision(val request: JsonObject, val cancelling: Boolean) : TeamLifecycleEdit
}

@Composable internal fun TeamOwnershipNotice(calls: TeamCalls, model: TeamManagementModel, onEdit: (TeamLifecycleEdit) -> Unit) {
    val request = model.ownershipRequest ?: return
    val recipient = request.teamString("toUserId") == calls.person
    val sender = model.currentOwner && request.teamString("fromUserId") == calls.person
    if (!recipient && !sender) return
    TsCard(title = L10n.text("common.teams.ownership_request")) {
        Text(if (request["current"] == JsonPrimitive(true)) { if (recipient) L10n.text("common.teams.ownership_accept_detail") else L10n.text("common.teams.ownership_pending") } else L10n.text("common.teams.ownership_stale"))
        if (recipient) TsSecondaryButton(L10n.text("common.teams.review_ownership"), enabled = !model.busy && model.verified && request.teamString("requestId")?.isNotBlank() == true && request["current"] == JsonPrimitive(true),
            icon = ActionIcon.Preview.vector, onClick = { onEdit(TeamLifecycleEdit.Decision(request, false)) })
        if (sender) TsSecondaryButton(L10n.text("common.teams.cancel_ownership_request"), enabled = !model.busy && request.teamString("requestId")?.isNotBlank() == true, icon = ActionIcon.Revoke.vector,
            onClick = { onEdit(TeamLifecycleEdit.Decision(request, true)) })
    }
}
@Composable internal fun TeamLifecycleSettings(model: TeamManagementModel, onEdit: (TeamLifecycleEdit) -> Unit) {
    Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Text(L10n.text("common.teams.organization_settings"), style = TsType.cardTitle)
        if (model.currentOwner) {
            Text(if (model.active) L10n.text("common.teams.owner_detail") else L10n.text("common.teams.owner_plan_recovery"))
            TsSecondaryButton(L10n.text("common.teams.transfer_ownership"), enabled = !model.busy, icon = ActionIcon.Move.vector,
                onClick = { onEdit(TeamLifecycleEdit.Transfer(model.organization)) })
            TsDangerButton(L10n.text("common.teams.delete_organization"), enabled = !model.busy, icon = ActionIcon.Delete.vector,
                onClick = { onEdit(TeamLifecycleEdit.Delete(model.organization)) })
        } else if (model.verified && model.role in setOf("member", "admin")) {
            Text(L10n.text("common.teams.leave_detail"))
            TsDangerButton(L10n.text("common.teams.leave_organization"), enabled = !model.busy, icon = ActionIcon.SignOut.vector,
                onClick = { onEdit(TeamLifecycleEdit.Leave(model.organization)) })
        }
    }
}
@Composable internal fun TeamLifecycleDialog(calls: TeamCalls, model: TeamManagementModel, edit: TeamLifecycleEdit, onDismiss: () -> Unit, onDone: () -> Unit, onGone: () -> Unit) {
    val scope = rememberCoroutineScope()
    var confirmed by remember(edit) { mutableStateOf(false) }
    var confirmation by remember(edit) { mutableStateOf("") }
    var successor by remember(edit) { mutableStateOf<String?>(null) }
    var choosing by remember { mutableStateOf(false) }
    var failure by remember { mutableStateOf<String?>(null) }
    val candidates = model.members.rows.filter { it.teamString("id") != model.organization.teamString("ownerId") && it["ownershipEligible"] == JsonPrimitive(true) }
    val title = when (edit) {
        is TeamLifecycleEdit.Transfer -> L10n.text("common.teams.transfer_ownership")
        is TeamLifecycleEdit.Delete -> L10n.text("common.teams.delete_organization")
        is TeamLifecycleEdit.Leave -> L10n.text("common.teams.leave_organization")
        is TeamLifecycleEdit.Decision -> if (edit.cancelling) L10n.text("common.teams.cancel_ownership_request") else L10n.text("common.teams.accept_ownership")
    }
    val ready = !model.busy && when (edit) {
        is TeamLifecycleEdit.Transfer -> confirmed && model.currentOwner && candidates.any { it.teamString("id") == successor }
        is TeamLifecycleEdit.Delete -> model.currentOwner && confirmation == edit.organization.teamString("name")
        is TeamLifecycleEdit.Leave -> confirmed && model.verified && model.role in setOf("member", "admin")
        is TeamLifecycleEdit.Decision -> confirmed && model.verified && edit.request.teamString("requestId")?.isNotBlank() == true && edit.request == model.ownershipRequest && (edit.cancelling && model.currentOwner || !edit.cancelling && edit.request.teamString("toUserId") == calls.person && edit.request["current"] == JsonPrimitive(true))
    }
    suspend fun save() {
        failure = null
        try {
            when (edit) {
                is TeamLifecycleEdit.Transfer -> model.mutate("ownership.request", model.transfer(candidates.single { it.teamString("id") == successor }, edit.organization))
                is TeamLifecycleEdit.Delete -> model.mutate("organizations.delete", model.deleteOrganization(confirmation, edit.organization))
                is TeamLifecycleEdit.Leave -> model.mutate("members.remove", model.leave(edit.organization), user = calls.person)
                is TeamLifecycleEdit.Decision -> model.mutate(if (edit.cancelling) "ownership.cancel" else "ownership.accept", model.ownershipDecision(edit.request, edit.cancelling))
            }
            if (edit is TeamLifecycleEdit.Delete || edit is TeamLifecycleEdit.Leave) onGone() else onDone()
        } catch (cancelled: CancellationException) { throw cancelled }
        catch (error: Exception) { failure = if (error is CoreFailure) error.message else L10n.text("common.teams.load_failed") }
    }
    AlertDialog(onDismissRequest = { if (!model.busy) onDismiss() }, title = { Text(title) }, text = {
        Column(Modifier.verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            Text(model.organization.teamString("name").orEmpty(), style = TsType.cardTitle)
            failure?.let { Text(it, color = LocalTsColors.current.danger) }
            when (edit) {
                is TeamLifecycleEdit.Transfer -> {
                    Text(L10n.text("common.teams.transfer_detail"))
                    Box {
                        TsSecondaryButton(candidates.firstOrNull { it.teamString("id") == successor }?.teamString("name") ?: L10n.text("common.teams.choose_member"), enabled = !model.busy,
                            icon = ActionIcon.Disclosure.vector, onClick = { choosing = true })
                        DropdownMenu(expanded = choosing, onDismissRequest = { choosing = false }) {
                            candidates.forEach { person -> DropdownMenuItem(text = { Text(person.teamString("name").orEmpty()) }, onClick = { successor = person.teamString("id"); confirmed = false; choosing = false }) }
                        }
                    }
                    if (candidates.isEmpty()) Text(L10n.text("common.teams.no_eligible_owner"))
                    if (model.members.next != null) TsSecondaryButton(L10n.text("common.teams.load_more"), enabled = !model.busy, icon = ActionIcon.More.vector, onClick = { scope.launch { model.refresh("members", true) } })
                    Text(L10n.text("common.teams.transfer_confirmation_detail"))
                }
                is TeamLifecycleEdit.Delete -> {
                    Text(L10n.text("common.teams.delete_confirmation_detail"))
                    Text(L10n.text("common.teams.type_name_to_delete", edit.organization.teamString("name").orEmpty()))
                    OutlinedTextField(confirmation, { confirmation = it }, modifier = Modifier.testTag("team.organization.delete_confirmation"), enabled = !model.busy)
                }
                is TeamLifecycleEdit.Leave -> Text(L10n.text("common.teams.leave_confirmation_detail"))
                is TeamLifecycleEdit.Decision -> Text(if (edit.cancelling) L10n.text("common.teams.cancel_ownership_detail") else L10n.text("common.teams.accept_ownership_confirmation"))
            }
            if (edit !is TeamLifecycleEdit.Delete) Row(Modifier.fillMaxWidth().toggleable(value = confirmed, enabled = !model.busy, role = Role.Checkbox, onValueChange = { confirmed = it }), verticalAlignment = Alignment.CenterVertically) {
                Checkbox(checked = confirmed, onCheckedChange = null, enabled = !model.busy)
                Text(if (edit is TeamLifecycleEdit.Transfer) L10n.text("common.teams.transfer_confirm") else L10n.text("common.teams.confirm_understood"))
            }
        }
    }, confirmButton = {
        if (edit is TeamLifecycleEdit.Delete || edit is TeamLifecycleEdit.Leave) TsDangerButton(title, enabled = ready, icon = ActionIcon.Delete.vector, onClick = { scope.launch { save() } })
        else TsAccentButton(if (edit is TeamLifecycleEdit.Transfer) L10n.text("common.teams.send_ownership_request") else title, enabled = ready, icon = ActionIcon.Approve.vector, onClick = { scope.launch { save() } })
    }, dismissButton = { TsSecondaryButton(L10n.text("common.cancel"), enabled = !model.busy, icon = ActionIcon.Dismiss.vector, onClick = onDismiss) })
}
