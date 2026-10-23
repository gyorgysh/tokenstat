// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.team

import ai.tokenstat.tokenstat.ui.components.*
import ai.tokenstat.tokenstat.ui.localization.L10n
import ai.tokenstat.tokenstat.ui.theme.LocalTsColors
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.launch
import kotlinx.serialization.json.JsonObject

@Composable internal fun TeamProjectsScreen(model: TeamProjectsModel, onBack: () -> Unit, onOpen: (JsonObject) -> Unit) {
    val scope = rememberCoroutineScope()
    val colors = LocalTsColors.current
    LaunchedEffect(model) { if (!model.organizations.loaded) model.loadOrganizations() }
    LazyColumn(Modifier.fillMaxSize().padding(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        item {
            TsSecondaryButton(L10n.text("common.back"), icon = ActionIcon.Back.vector, onClick = onBack)
            Text(L10n.text("common.teams.shared_projects"), style = TsType.cardTitle, color = colors.textPrimary)
            Text(L10n.text("common.teams.shared_projects_detail"), color = colors.textSecondary)
            TsSecondaryButton(L10n.text("common.refresh"), enabled = !model.organizationBusy, icon = ActionIcon.Refresh.vector, onClick = { scope.launch { model.loadOrganizations() } })
            model.organizationError?.let { Text(it, color = colors.danger) }
            if (model.organizationBusy) CircularProgressIndicator()
            if (model.organizations.loaded && model.organizations.rows.isEmpty()) Text(L10n.text("common.teams.no_shared_projects"), color = colors.textSecondary)
        }
        model.organizations.rows.forEach { organization ->
            val id = organization.teamString("id")!!
            val page = model.projects[id] ?: TeamManagementPage()
            item(key = "team:$id") {
                LaunchedEffect(model, id, model.revision) { if (!page.loaded) model.loadProjects(id) }
                Text(organization.teamString("name").orEmpty(), style = TsType.cardTitle, color = colors.textPrimary)
                model.errors[id]?.let { Text(it, color = colors.danger) }
                if (id in model.loading) CircularProgressIndicator()
                if (page.loaded && page.rows.isEmpty() && page.next == null) Text(L10n.text("common.teams.no_shared_projects"), color = colors.textSecondary)
            }
            items(page.rows, key = { "project:$id:${it.teamString("id")}" }) { repository ->
                TsCard(title = repository.teamString("name").orEmpty(), subtitle = teamRoleLabel(repository.teamString("role")), modifier = Modifier.testTag("team.project.$id.${repository.teamString("id")}")) {
                    Text(L10n.text("common.teams.shared_with_you"), color = colors.textSecondary)
                    TsSecondaryButton(L10n.text("common.teams.open_shared_project"), icon = ActionIcon.Connect.vector, onClick = { onOpen(repository) })
                }
            }
            if (page.next != null || model.errors[id] != null) item(key = "more:$id") {
                TsSecondaryButton(L10n.text(if (model.errors[id] != null) "common.retry" else "common.teams.load_more"), enabled = id !in model.loading && !model.organizationBusy,
                    icon = ActionIcon.More.vector, onClick = { scope.launch { model.loadProjects(id, page.loaded && page.next != null) } })
            }
        }
        if (model.organizations.next != null) item {
            TsSecondaryButton(L10n.text("common.teams.more_organizations"), enabled = !model.organizationBusy, icon = ActionIcon.More.vector, onClick = { scope.launch { model.loadOrganizations(true) } })
        }
    }
}
