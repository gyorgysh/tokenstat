// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.workspace

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
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
        }.onFailure { error = TunnelCopy.display(it.message ?: "The request failed.", hostLabel) }
    }

    Dialog(onDismissRequest = onDismiss, properties = DialogProperties(usePlatformDefaultWidth = false)) {
        Column(
            Modifier
                .fillMaxWidth()
                .padding(Space.m),
            verticalArrangement = Arrangement.spacedBy(Space.m),
        ) {
            Column {
                Text(
                    title.ifBlank { "Result" },
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
            TsSecondaryButton(label = "Close", small = true, onClick = onDismiss)
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
    val folderLabel = folderName.ifBlank { "Folder" }
    Column(verticalArrangement = Arrangement.spacedBy(Space.s)) {
        Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text(
                "This folder",
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
            workspaceEmpty -> "This task has no folder. Assign one to review files and history."
            folderMissing -> if (hostName.isBlank()) {
                "This folder is no longer available on the connected computer."
            } else {
                "This folder is no longer available on $hostName."
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
                0 -> "Working tree matches the last commit"
                1 -> "1 file to review"
                null -> "Uncommitted files in this folder"
                else -> "$changeCount files to review"
            }
            TaskResultRow("Changes", changesCaption, changeCount, onOpenChanges, "Opens uncommitted files for this folder")
            TaskResultRow("History", "Previous commits in this folder", null, onOpenHistory, "Opens commits for this folder")
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
