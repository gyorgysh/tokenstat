// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.team

import ai.tokenstat.tokenstat.ui.components.*
import ai.tokenstat.tokenstat.ui.localization.L10n
import ai.tokenstat.tokenstat.ui.theme.LocalTsColors
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.launch
import kotlinx.serialization.json.*

@Composable internal fun TeamInboxScreen(calls: TeamCalls, onBack: () -> Unit, onJoined: (JsonObject) -> Unit) {
    val model = remember(calls) { TeamInboxModel(calls) }
    val scope = rememberCoroutineScope()
    val colors = LocalTsColors.current
    LaunchedEffect(model) { model.load() }
    LazyColumn(Modifier.fillMaxSize().padding(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        item {
            TsSecondaryButton(L10n.text("common.back"), enabled = !model.joining, icon = ActionIcon.Back.vector, onClick = onBack)
            Text(L10n.text("common.teams.invitations_for_you"), style = TsType.cardTitle, color = colors.textPrimary)
            Text(L10n.text("common.teams.inbox_detail"), color = colors.textSecondary)
            TsSecondaryButton(L10n.text("common.refresh"), enabled = !model.busy, icon = ActionIcon.Refresh.vector, onClick = { scope.launch { model.load() } })
            if (model.selected == null) model.error?.let { Text(if (it == "load_failed") L10n.text("common.teams.load_failed") else it, color = colors.danger) }
            if (model.busy) CircularProgressIndicator()
            if (model.page.loaded && model.page.rows.isEmpty()) Text(L10n.text("common.teams.no_invitations"), color = colors.textSecondary)
        }
        items(model.page.rows, key = { it.teamString("id")!! }) { invitation ->
            TsCard(title = invitation.teamString("organizationName") ?: L10n.text("common.teams.title"), subtitle = teamRoleLabel(invitation.teamString("role"))) {
                TsSecondaryButton(L10n.text("common.teams.review_invitation"), enabled = !model.busy, icon = ActionIcon.Preview.vector,
                    onClick = { scope.launch { model.review(invitation.teamString("id")!!) } })
            }
        }
        if (model.page.next != null) item {
            TsSecondaryButton(L10n.text("common.teams.load_more"), enabled = !model.busy, icon = ActionIcon.More.vector, onClick = { scope.launch { model.load(true) } })
        }
    }
    if (model.selected != null) AlertDialog(onDismissRequest = model::close, title = {
        Text((model.preview?.get("invitation") as? JsonObject)?.teamString("organizationName") ?: L10n.text("common.teams.review_invitation"))
    }, text = {
        Column(Modifier.verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            model.error?.let { Text(if (it == "load_failed") L10n.text("common.teams.load_failed") else it, color = colors.danger) }
            if (model.busy || model.joining) CircularProgressIndicator()
            model.preview?.let { preview ->
                Text(teamRoleLabel(preview["invitation"]!!.jsonObject.teamString("role")), style = TsType.cardTitle)
                if (preview["available"] == JsonPrimitive(true)) {
                    val access = preview["repositoryAccess"]!!.jsonArray
                    if (access.isEmpty()) Text(L10n.text("common.teams.join_no_repository_access"))
                    access.forEach { row ->
                        Text(row.jsonObject.teamString("name").orEmpty(), style = TsType.cardTitle)
                        Text(teamRoleLabel(row.jsonObject.teamString("role")))
                    }
                    Text(L10n.text("common.teams.execution_separate")); Text(L10n.text("common.teams.join_content_detail"))
                } else Text(if (preview.teamString("unavailableReason") == "organization_paused") L10n.text("common.teams.organization_paused") else L10n.text("common.teams.invitation_unavailable"))
                if (preview["eligible"] != JsonPrimitive(true)) Text(L10n.text("common.teams.patron_invitation"))
            }
        }
    }, confirmButton = {
        TsAccentButton(L10n.text("common.teams.join_organization"), enabled = model.canJoin, icon = ActionIcon.Approve.vector,
            onClick = { scope.launch { model.accept()?.let(onJoined) } })
    }, dismissButton = {
        TsSecondaryButton(L10n.text("common.cancel"), enabled = !model.joining, icon = ActionIcon.Dismiss.vector, onClick = model::close)
        if (model.preview == null && model.error != null) TsSecondaryButton(L10n.text("common.retry"), enabled = !model.busy, icon = ActionIcon.Refresh.vector,
            onClick = { model.selected?.let { id -> scope.launch { model.review(id) } } })
    })
}
