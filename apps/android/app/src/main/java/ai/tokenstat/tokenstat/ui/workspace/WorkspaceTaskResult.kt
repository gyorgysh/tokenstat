// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.workspace

import ai.tokenstat.tokenstat.ui.localization.L10n

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import ai.tokenstat.tokenstat.AppViewModel
import ai.tokenstat.tokenstat.ui.components.Banner
import ai.tokenstat.tokenstat.ui.components.BannerSeverity
import ai.tokenstat.tokenstat.ui.components.TsSecondaryButton
import ai.tokenstat.tokenstat.ui.components.TsType
import ai.tokenstat.tokenstat.ui.components.cardRadiusDp
import ai.tokenstat.tokenstat.ui.logic.TunnelCopy
import ai.tokenstat.tokenstat.ui.theme.LocalTsColors
import ai.tokenstat.tokenstat.ui.theme.Space
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put

/// Review Changes and History for the folder that produced a task result.
///
/// Ports `TaskResultWorkspaceLinks`: whole-surface rows in the shape of the
/// folder's own sections, so the destination reads as the folder rather than
/// a second run action. Compact layouts push the section and return here.
@Composable
fun TaskResultDialog(
    model: AppViewModel,
    peer: String,
    workspace: String,
    title: String,
    backend: String,
    column: String,
    folderName: String,
    hostLabel: String,
    onOpenSection: (String) -> Unit,
    onDismiss: () -> Unit,
) {
    var changeCount by remember { mutableStateOf<Int?>(null) }
    var folderMissing by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }

    LaunchedEffect(peer, workspace) {
        runCatching {
            model.workspaceSection(peer, "workspace.status", buildJsonObject { put("id", workspace) }) as? JsonObject
        }.onSuccess { folder ->
            val git = folder?.get("git") as? JsonObject
            changeCount = asObjects(git?.get("files")).size
            folderMissing = folder?.bol("exists") == false
            error = null
        }.onFailure { error = TunnelCopy.display(it.message ?: L10n.text("android.workspacetaskresult.the_request_failed.db4fb447"), hostLabel) }
    }

    Dialog(onDismissRequest = onDismiss, properties = DialogProperties(usePlatformDefaultWidth = false)) {
        // A sheet with a surface under it. Without one the title drew over
        // the dimmed tasks behind and the rows floated as loose cards.
        Surface(
            shape = RoundedCornerShape(20.dp),
            color = LocalTsColors.current.background,
            tonalElevation = 0.dp,
            shadowElevation = 12.dp,
            // Hug the content: this dialog is a fixed few rows, not a list,
            // so a tall sheet would be mostly empty surface.
            modifier = Modifier.fillMaxWidth(0.94f),
        ) {
        Column(
            Modifier
                .fillMaxWidth()
                .padding(Space.m),
            verticalArrangement = Arrangement.spacedBy(Space.m),
        ) {
            Column {
                Text(
                    title.ifBlank { L10n.text("android.workspacetaskresult.result.6e7d50e8") },
                    style = TextStyle(fontSize = 17.sp, fontWeight = FontWeight.SemiBold),
                    color = LocalTsColors.current.textPrimary,
                )
                val subtitle = listOfNotNull(
                    backend.takeIf { it.isNotBlank() },
                    column.takeIf { it.isNotBlank() },
                ).joinToString(" · ")
                if (subtitle.isNotBlank()) {
                    Text(subtitle, style = TextStyle(fontSize = 12.sp), color = LocalTsColors.current.textSecondary)
                }
            }
            if (error != null) Banner(error!!, BannerSeverity.DANGER)
            TaskResultLinks(
                folderName = folderName,
                hostName = hostLabel,
                changeCount = changeCount,
                folderMissing = folderMissing,
                workspaceEmpty = workspace.isBlank(),
                onOpenChanges = { onDismiss(); onOpenSection("Changes") },
                onOpenHistory = { onDismiss(); onOpenSection("History") },
            )
            TsSecondaryButton(label = L10n.text("common.close"), small = true, onClick = onDismiss)
        }
        }
    }
}

@Composable
private fun TaskResultLinks(
    folderName: String,
    hostName: String,
    changeCount: Int?,
    folderMissing: Boolean,
    workspaceEmpty: Boolean,
    onOpenChanges: () -> Unit,
    onOpenHistory: () -> Unit,
) {
    val folderLabel = folderName.ifBlank { L10n.text("android.workspacetaskresult.folder.74ccd433") }
    Column(verticalArrangement = Arrangement.spacedBy(Space.s)) {
        Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text(
                L10n.text("android.workspacetaskresult.this_folder.ab7db04c"),
                style = TextStyle(fontSize = 14.sp, fontWeight = FontWeight.SemiBold),
                color = LocalTsColors.current.textPrimary,
            )
            Text(
                listOfNotNull(folderLabel, hostName.takeIf { it.isNotBlank() }).joinToString(" · "),
                style = TextStyle(fontSize = 12.sp),
                color = LocalTsColors.current.textSecondary,
                maxLines = 2,
            )
        }
        val message = when {
            workspaceEmpty -> L10n.text("android.workspacetaskresult.this_task_has_no_folder_assign_one_to_revi.ec78820b")
            folderMissing -> if (hostName.isBlank()) {
                L10n.text("android.workspacetaskresult.this_folder_is_no_longer_available_on_the.be3071ed")
            } else {
                L10n.text("android.workspacetaskresult.this_folder_is_no_longer_available_on_0.70d7366a", "${hostName}")
            }
            else -> null
        }
        if (message != null) {
            Text(
                message,
                style = TextStyle(fontSize = 12.sp),
                color = LocalTsColors.current.textSecondary,
                modifier = Modifier
                    .fillMaxWidth()
                    .clip(RoundedCornerShape(cardRadiusDp))
                    .background(LocalTsColors.current.panel)
                    .padding(Space.m),
            )
        } else {
            val changesCaption = when (changeCount) {
                0 -> L10n.text("android.workspacetaskresult.working_tree_matches_the_last_commit.419b69e6")
                1 -> L10n.text("android.workspacetaskresult.1_file_to_review.0d600164")
                null -> L10n.text("android.workspacetaskresult.uncommitted_files_in_this_folder.9b817339")
                else -> L10n.text("android.workspacetaskresult.0_files_to_review.b2f93852", "${changeCount}")
            }
            TaskResultRow(L10n.text("android.workspacetaskresult.changes.bbd4b6a8"), changesCaption, changeCount, onOpenChanges, L10n.text("android.workspacetaskresult.opens_uncommitted_files_for_this_folder.9ca505db"))
            TaskResultRow(L10n.text("common.history"), L10n.text("android.workspacetaskresult.previous_commits_in_this_folder.cf1fcffb"), null, onOpenHistory, L10n.text("android.workspacetaskresult.opens_commits_for_this_folder.a55a945b"))
        }
    }
}

@Composable
private fun TaskResultRow(
    title: String,
    caption: String,
    count: Int?,
    onOpen: () -> Unit,
    hint: String,
) {
    Row(
        Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(cardRadiusDp))
            .background(LocalTsColors.current.panel)
            .clickable(onClick = onOpen)
            .padding(Space.m),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(Space.m),
    ) {
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text(
                title,
                style = TextStyle(fontSize = 15.sp, fontWeight = FontWeight.Medium),
                color = LocalTsColors.current.textPrimary,
            )
            Text(
                caption,
                style = TextStyle(fontSize = 12.sp),
                color = LocalTsColors.current.textSecondary,
                maxLines = 2,
            )
        }
        if (count != null && count > 0) {
            Text(count.toString(), style = TsType.numeric(14), color = LocalTsColors.current.textSecondary)
        }
    }
}
