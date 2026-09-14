// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.workspace

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Difference
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import ai.tokenstat.tokenstat.AppViewModel
import ai.tokenstat.tokenstat.ui.components.Banner
import ai.tokenstat.tokenstat.ui.components.BannerSeverity
import ai.tokenstat.tokenstat.ui.components.BrandCheckbox
import ai.tokenstat.tokenstat.ui.components.EmptyState
import ai.tokenstat.tokenstat.ui.components.TsAccentButton
import ai.tokenstat.tokenstat.ui.components.TsSecondaryButton
import ai.tokenstat.tokenstat.ui.components.TsType
import ai.tokenstat.tokenstat.ui.components.cardRadiusDp
import ai.tokenstat.tokenstat.ui.logic.ChangeKinds
import ai.tokenstat.tokenstat.ui.logic.FileSelection
import ai.tokenstat.tokenstat.ui.logic.HostContracts
import ai.tokenstat.tokenstat.ui.logic.TunnelCopy
import ai.tokenstat.tokenstat.ui.marks.EmptyArt
import ai.tokenstat.tokenstat.ui.marks.EmptyArtKind
import ai.tokenstat.tokenstat.ui.theme.LocalTsColors
import ai.tokenstat.tokenstat.ui.theme.Space
import kotlinx.coroutines.launch
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put

/// What is uncommitted in this folder, as the host last reported it.
///
/// Ports `ClientWorkspaceChangesView`: tapping a file opens its diff,
/// selection stays local until the reviewed content is submitted, the footer
/// counts "N of M selected", and push rides below the fold. The file list
/// itself is a fresh read, so a file written while it is open shows up here.
@Composable
fun ChangesSection(
    model: AppViewModel,
    peer: String,
    workspace: String,
    modifier: Modifier = Modifier,
    folderName: String = "",
    hostLabel: String = "",
    protocol: Long? = null,
    onChanged: () -> Unit = {},
) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val state = remember(peer, workspace) { CommitUiState(peer, workspace) }
    var showingComposer by remember { mutableStateOf(false) }
    var showingReviewAll by remember { mutableStateOf(false) }
    var diffPath by remember { mutableStateOf<String?>(null) }
    var editPath by remember { mutableStateOf<String?>(null) }

    suspend fun load() {
        state.restore(context)
        state.loadStatus(model, hostLabel)
        if (state.operationId != null) {
            state.checkOutcome(model, hostLabel, context)
            if (state.outcomeState == "succeeded") onChanged()
        }
    }
    LaunchedEffect(peer, workspace) { load() }

    val files = state.files
    val allPaths = files.mapNotNull { it.str("path") }.toSet()

    Column(modifier, verticalArrangement = Arrangement.spacedBy(Space.s)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(
                state.branch ?: "Changes",
                style = TextStyle(fontSize = 14.sp, fontWeight = FontWeight.SemiBold),
                color = LocalTsColors.current.textPrimary,
                modifier = Modifier.weight(1f),
            )
            if (files.size > 1) {
                TextButton(
                    enabled = state.loaded,
                    onClick = { showingReviewAll = true },
                ) { Text("Review all", color = LocalTsColors.current.accent) }
            }
            if (files.isNotEmpty()) {
                TextButton(
                    enabled = state.loaded && !state.working && state.operationId == null,
                    onClick = { state.selectAll() },
                ) {
                    Text(
                        if (state.selection == allPaths) "Deselect all" else "Select all",
                        color = LocalTsColors.current.accent,
                    )
                }
            }
        }
        if (state.error != null) Banner(state.error!!, BannerSeverity.DANGER)
        if (state.loaded && files.isEmpty() && state.error == null) {
            EmptyState(
                Icons.Default.Difference,
                "Nothing to commit",
                "Every file in this folder matches the last commit.",
                art = { EmptyArt(EmptyArtKind.Changes) },
            )
        }
        if (files.isNotEmpty()) {
            AutoCommitCard(
                model = model,
                peer = peer,
                workspace = workspace,
                folderName = folderName,
                hostLabel = hostLabel,
            )
            LazyColumn(verticalArrangement = Arrangement.spacedBy(Space.xs)) {
                items(files, key = { it.str("path") ?: it.hashCode().toString() }) { file ->
                    val path = file.str("path") ?: return@items
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        BrandCheckbox(
                            checked = state.selection.contains(path),
                            onToggle = { state.select(path) },
                            label = "Select $path",
                            modifier = Modifier.weight(0.001f),
                        )
                        ChangedFileRow(
                            file = file,
                            modifier = Modifier.weight(1f),
                            onOpen = { diffPath = path },
                        )
                    }
                }
            }
        }
        if (files.isNotEmpty() || state.operationId != null) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(
                    FileSelection.label(state.selection.size, files.size),
                    style = TextStyle(fontSize = 12.sp),
                    color = LocalTsColors.current.textSecondary,
                    modifier = Modifier.weight(1f),
                )
                TsSecondaryButton(
                    label = if (state.operationId == null) "Review and commit" else "Check commit",
                    small = true,
                    enabled = state.loaded && (state.selection.isNotEmpty() || state.operationId != null),
                    onClick = { showingComposer = true },
                )
            }
        }
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(
                state.branch ?: "Current branch",
                style = TextStyle(fontSize = 12.sp),
                color = LocalTsColors.current.textSecondary,
                modifier = Modifier.weight(1f),
            )
            PushButton(
                model = model,
                peer = peer,
                workspace = workspace,
                folderName = folderName,
                hostLabel = hostLabel,
                outgoing = state.ahead,
                protocol = protocol,
                onPushed = { scope.launch { load() } },
            )
        }
        BranchRow(
            model = model,
            peer = peer,
            workspace = workspace,
            hostLabel = hostLabel,
            branch = state.branch,
            isRepo = state.isRepo,
            onChanged = { scope.launch { load() } },
        )
    }
    if (showingComposer) {
        CommitComposerDialog(
            model = model,
            state = state,
            folderName = folderName,
            hostLabel = hostLabel,
            supportsSelectedCommit = HostContracts.supportsSelectedCommit(protocol),
            onDismiss = { showingComposer = false },
            onCommitted = {
                scope.launch { load() }
                onChanged()
            },
        )
    }
    if (showingReviewAll) {
        ReviewAllDialog(
            model = model,
            peer = peer,
            workspace = workspace,
            hostLabel = hostLabel,
            files = files,
            onDismiss = { showingReviewAll = false },
            onOpenFile = { path ->
                showingReviewAll = false
                diffPath = path
            },
        )
    }
    val open = diffPath
    if (open != null) {
        FileDiffDialog(
            model = model,
            peer = peer,
            workspace = workspace,
            hostLabel = hostLabel,
            path = open,
            onEdit = { editPath = open },
            onDismiss = { diffPath = null },
        )
    }
    val editing = editPath
    if (editing != null) {
        ai.tokenstat.tokenstat.ui.editor.EditorDialog(
            model = model,
            peer = peer,
            workspace = workspace,
            folderName = folderName,
            hostLabel = hostLabel,
            initial = listOf(ai.tokenstat.tokenstat.ui.editor.EditorOpen(editing)),
            onSavedFile = { scope.launch { load() } },
            onDismiss = { editPath = null },
        )
    }
}

/// One changed file, and the way into its diff: name, directory, kind word,
/// and added/removed counts in the diff pair.
@Composable
private fun ChangedFileRow(file: JsonObject, modifier: Modifier = Modifier, onOpen: () -> Unit) {
    val path = file.str("path") ?: ""
    val name = path.substringAfterLast('/')
    val directory = path.substringBeforeLast('/', "")
    val kind = file.str("kind") ?: ""
    val added = file.get("added")?.jsonPrimitive?.intOrNull
    val removed = file.get("removed")?.jsonPrimitive?.intOrNull
    Row(
        modifier
            .clip(RoundedCornerShape(cardRadiusDp))
            .background(LocalTsColors.current.panel)
            .clickable(onClick = onOpen)
            .padding(Space.m),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(Space.s),
    ) {
        Column(Modifier.weight(1f)) {
            Text(
                name.ifBlank { path },
                style = TextStyle(fontSize = 14.sp),
                color = LocalTsColors.current.textPrimary,
                maxLines = 1,
            )
            if (directory.isNotEmpty()) {
                Text(
                    directory,
                    style = TextStyle(fontSize = 11.sp),
                    color = LocalTsColors.current.textSecondary,
                    maxLines = 1,
                )
            }
            if (kind.isNotBlank()) {
                Text(
                    ChangeKinds.label(kind),
                    style = TextStyle(fontSize = 11.sp, fontWeight = FontWeight.Medium),
                    color = LocalTsColors.current.accent,
                )
            }
        }
        if ((added ?: 0) > 0) {
            Text(
                "+$added",
                style = TsType.numeric(12),
                color = LocalTsColors.current.diffAdded,
            )
        }
        if ((removed ?: 0) > 0) {
            Text(
                "−$removed",
                style = TsType.numeric(12),
                color = LocalTsColors.current.diffRemoved,
            )
        }
    }
}

/// One file's current working-copy diff, read from the owning machine.
/// Renders hunk rows (one gutter, marker carries the side) like
/// `ClientDiffView`; binary and empty states use Apple's words.
@Composable
fun FileDiffDialog(
    model: AppViewModel,
    peer: String,
    workspace: String,
    hostLabel: String,
    path: String,
    onEdit: (() -> Unit)? = null,
    onDismiss: () -> Unit,
) {
    var diff by remember(path) { mutableStateOf<JsonObject?>(null) }
    var error by remember(path) { mutableStateOf<String?>(null) }
    var loading by remember(path) { mutableStateOf(true) }
    LaunchedEffect(path) {
        runCatching {
            model.workspaceSection(peer, "workspace.diff", buildJsonObject {
                put("id", workspace); put("path", path)
            }) as? JsonObject
        }.onSuccess { diff = it; error = null }
            .onFailure { error = TunnelCopy.display(it.message ?: "The request failed.", hostLabel) }
        loading = false
    }
    Dialog(onDismissRequest = onDismiss, properties = DialogProperties(usePlatformDefaultWidth = false)) {
        Column(
            Modifier
                .fillMaxWidth()
                .padding(Space.m)
                .verticalScroll(rememberScrollState()),
            verticalArrangement = Arrangement.spacedBy(Space.s),
        ) {
            Text(path, style = TsType.mono(13), color = LocalTsColors.current.textPrimary)
            if (error != null) Banner(error!!, BannerSeverity.DANGER)
            if (loading) {
                Text("Loading…", color = LocalTsColors.current.textSecondary)
            } else if (diff != null) {
                HunkDiffView(diff!!)
            } else if (error == null) {
                Text("That file is not in this folder any more.", color = LocalTsColors.current.textSecondary)
            }
            Row(horizontalArrangement = Arrangement.spacedBy(Space.s)) {
                if (onEdit != null && diff != null && !diff!!.bol("binary")) {
                    TsAccentButton(label = "Edit", small = true, onClick = { onDismiss(); onEdit() })
                }
                TsSecondaryButton(label = "Close", small = true, onClick = onDismiss)
            }
        }
    }
}

/// Hunk rows from a host `FileDiff`: hunk headers, then numbered lines with
/// the `+`/`−` marker carrying which side the line is on. Caps at 2000
/// lines like the Apple diff, saying so out loud.
@Composable
fun HunkDiffView(diff: JsonObject, maxLines: Int = 2000) {
    val colors = LocalTsColors.current
    if (diff.bol("binary")) {
        Text(
            "This is a binary file. There is nothing to show line by line.",
            color = colors.textSecondary,
        )
        return
    }
    val hunks = asObjects(diff["hunks"])
    if (hunks.isEmpty()) {
        Text(
            if (diff.bol("untracked")) "This file is not tracked yet and is empty."
            else "No changes against HEAD.",
            color = colors.textSecondary,
        )
        return
    }
    val total = hunks.sumOf { asObjects(it["lines"]).size }
    val shown = hunks.takeLines(maxLines)
    Column(verticalArrangement = Arrangement.spacedBy(1.dp)) {
        shown.forEach { hunk ->
            hunk.str("header")?.let {
                Text(
                    it,
                    style = TsType.mono(11),
                    color = colors.textTertiary,
                    maxLines = 1,
                    modifier = Modifier
                        .fillMaxWidth()
                        .background(colors.panel)
                        .padding(horizontal = Space.s, vertical = 6.dp),
                )
            }
            asObjects(hunk["lines"]).forEach { line ->
                val kind = line.str("kind") ?: "context"
                val number = line.get("newLine")?.jsonPrimitive?.intOrNull
                    ?: line.get("new_line")?.jsonPrimitive?.intOrNull
                    ?: line.get("oldLine")?.jsonPrimitive?.intOrNull
                    ?: line.get("old_line")?.jsonPrimitive?.intOrNull
                val marker = when (kind.lowercase()) {
                    "added" -> "+"
                    "removed" -> "−"
                    else -> " "
                }
                val tint = when (kind.lowercase()) {
                    "added" -> colors.diffAdded
                    "removed" -> colors.diffRemoved
                    else -> colors.textPrimary
                }
                val wash = when (kind.lowercase()) {
                    "added" -> colors.diffAdded.copy(alpha = 0.12f)
                    "removed" -> colors.diffRemoved.copy(alpha = 0.12f)
                    else -> androidx.compose.ui.graphics.Color.Transparent
                }
                Row(
                    Modifier
                        .fillMaxWidth()
                        .background(wash)
                        .padding(horizontal = Space.s, vertical = 1.dp),
                ) {
                    Text(
                        number?.toString() ?: "·",
                        style = TsType.mono(11),
                        color = colors.textTertiary,
                        modifier = Modifier.padding(end = Space.xs),
                    )
                    Text(marker, style = TsType.mono(11), color = tint, modifier = Modifier.padding(end = Space.xs))
                    Text(
                        line.str("text")?.ifBlank { " " } ?: " ",
                        style = TsType.mono(11),
                        color = tint,
                        maxLines = 4,
                    )
                }
            }
        }
        if (total > maxLines) {
            Text(
                "Showing the first $maxLines of $total lines.",
                style = TextStyle(fontSize = 12.sp),
                color = colors.textSecondary,
            )
        }
    }
}

private fun List<JsonObject>.takeLines(max: Int): List<JsonObject> {
    var left = max
    return mapNotNull { hunk ->
        if (left <= 0) return@mapNotNull null
        val lines = asObjects(hunk["lines"]).take(left)
        left -= lines.size
        buildJsonObject {
            hunk.str("header")?.let { put("header", it) }
            put("lines", JsonArray(lines.map { it as JsonElement }))
        }
    }
}
