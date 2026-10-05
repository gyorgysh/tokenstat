// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.workspace

import ai.tokenstat.tokenstat.ui.localization.L10n

import androidx.compose.material3.Icon
import ai.tokenstat.tokenstat.ui.components.ActionIcon

import ai.tokenstat.tokenstat.ui.chrome.TabBarChrome
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
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
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import ai.tokenstat.tokenstat.AppViewModel
import ai.tokenstat.tokenstat.ui.components.Banner
import ai.tokenstat.tokenstat.ui.components.BannerSeverity
import ai.tokenstat.tokenstat.ui.components.BrandCheckDisc
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

    val editingTop = editPath
    if (editingTop != null) {
        WorkspaceFileEditorPage(
            model = model,
            peer = peer,
            workspace = workspace,
            folderName = folderName,
            hostLabel = hostLabel,
            path = editingTop,
            modifier = modifier,
            onClose = { editPath = null },
            onSavedFile = { scope.launch { load() } },
        )
        return
    }
    val diffTop = diffPath
    if (diffTop != null) {
        FileDiffPage(
            model = model,
            peer = peer,
            workspace = workspace,
            hostLabel = hostLabel,
            path = diffTop,
            modifier = modifier,
            onBack = { diffPath = null },
            onEdit = { editPath = diffTop },
        )
        return
    }
    if (showingReviewAll) {
        ReviewAllPage(
            model = model,
            peer = peer,
            workspace = workspace,
            hostLabel = hostLabel,
            files = files,
            modifier = modifier,
            onBack = { showingReviewAll = false },
            onOpenFile = { path ->
                showingReviewAll = false
                diffPath = path
            },
        )
        return
    }

    // The bar floats over this screen, so the docked rows reserve its height
    // rather than sliding under it. The list takes what is left.
    Column(
        modifier.padding(bottom = TabBarChrome.contentBottomInset),
        verticalArrangement = Arrangement.spacedBy(Space.s),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(
                state.branch ?: L10n.text("android.workspacechanges.changes.bbd4b6a8"),
                style = TextStyle(fontSize = 14.sp, fontWeight = FontWeight.SemiBold),
                color = LocalTsColors.current.textPrimary,
                modifier = Modifier.weight(1f),
            )
            if (files.size > 1) {
                TextButton(
                    enabled = state.loaded,
                    onClick = { showingReviewAll = true },
                ) { Text(L10n.text("android.workspacechanges.review_all.d05163fa"), color = LocalTsColors.current.accent) }
            }
            if (files.isNotEmpty()) {
                TextButton(
                    enabled = state.loaded && !state.working && state.operationId == null,
                    onClick = { state.selectAll() },
                ) {
                    Text(
                        if (state.selection == allPaths) L10n.text("android.workspacechanges.deselect_all.96754949") else L10n.text("android.workspacechanges.select_all.1fc9a387"),
                        color = LocalTsColors.current.accent,
                    )
                }
            }
        }
        if (state.error != null) Banner(state.error!!, BannerSeverity.DANGER)
        if (state.loaded && files.isEmpty() && state.error == null) {
            EmptyState(
                Icons.Default.Difference,
                L10n.text("android.workspacechanges.nothing_to_commit.f377a9f6"),
                L10n.text("android.workspacechanges.every_file_in_this_folder_matches_the_last.fffbaf63"),
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
            // Weighted, so the selection count, Review and commit, and Push
            // sit on the bottom edge the way the iPhone docks them. Unweighted
            // the list took its natural height and pushed all three past the
            // end of a ninety-six file scroll: the doc comment above called
            // that "push rides below the fold", which is a bug with a
            // sentence in front of it.
            LazyColumn(
                Modifier.weight(1f),
                contentPadding = PaddingValues(bottom = Space.xs),
                verticalArrangement = Arrangement.spacedBy(Space.xs),
            ) {
                items(files, key = { it.str("path") ?: it.hashCode().toString() }) { file ->
                    val path = file.str("path") ?: return@items
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        // A bare disc: the file row carries the name, and the
                        // disc carries its own touch target because tapping
                        // the row opens the diff instead.
                        val picked = state.selection.contains(path)
                        Box(
                            Modifier
                                .size(44.dp)
                                .clickable(role = Role.Checkbox, onClick = { state.select(path) })
                                .semantics { contentDescription = L10n.text("android.workspacechanges.select_0_1.028ca175", "${path}", "${if (picked) "on" else "off"}") },
                            contentAlignment = Alignment.Center,
                        ) {
                            BrandCheckDisc(on = picked)
                        }
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
                    label = if (state.operationId == null) L10n.text("android.workspacechanges.review_and_commit.96f097b7") else L10n.text("android.workspacechanges.check_commit.d65b2b26"),
                    small = true,
                    enabled = state.loaded && (state.selection.isNotEmpty() || state.operationId != null),
                    onClick = { showingComposer = true },
                )
            }
        }
        Text(
            state.branch ?: L10n.text("android.workspacechanges.current_branch.7c5b2da1"),
            style = TextStyle(fontSize = 12.sp),
            color = LocalTsColors.current.textSecondary,
            maxLines = 1,
        )
        // Bring commits in, send them out, and the pull request they belong
        // to. Pull and Push share the available width and touch size.
        GitTransferActions(
            pull = { actionModifier ->
                PullButton(
                    model = model,
                    peer = peer,
                    workspace = workspace,
                    folderName = folderName,
                    hostLabel = hostLabel,
                    incoming = state.behind,
                    protocol = protocol,
                    modifier = actionModifier,
                    onPulled = { scope.launch { load() } },
                )
            },
            push = { actionModifier ->
                PushButton(
                    model = model,
                    peer = peer,
                    workspace = workspace,
                    folderName = folderName,
                    hostLabel = hostLabel,
                    outgoing = state.ahead,
                    protocol = protocol,
                    modifier = actionModifier,
                    onPushed = { scope.launch { load() } },
                )
            },
        )
        BranchPullButton(
            model = model,
            peer = peer,
            workspace = workspace,
            branch = state.branch,
            folderName = folderName,
            hostLabel = hostLabel,
            protocol = protocol,
            modifier = Modifier.fillMaxWidth(),
        )
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
                overflow = TextOverflow.Ellipsis,
            )
            if (directory.isNotEmpty()) {
                Text(
                    middleTruncate(directory, maxChars = 40),
                    style = TextStyle(fontSize = 11.sp),
                    color = LocalTsColors.current.textSecondary,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
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
        // The row opens the diff, so it says so. Every other row in the app
        // that pushes somewhere carries this chevron.
        Icon(
            ActionIcon.Disclosure.vector,
            null,
            tint = LocalTsColors.current.textTertiary,
            modifier = Modifier.size(16.dp),
        )
    }
}

/// One file's current working-copy diff as a full page, read from the owning
/// machine. Renders hunk rows (one gutter, marker carries the side) like
/// `ClientDiffView`; binary and empty states use Apple's words.
@Composable
fun FileDiffPage(
    model: AppViewModel,
    peer: String,
    workspace: String,
    hostLabel: String,
    path: String,
    modifier: Modifier = Modifier,
    onEdit: (() -> Unit)? = null,
    onBack: () -> Unit,
) {
    val scope = rememberCoroutineScope()
    var diff by remember(path) { mutableStateOf<JsonObject?>(null) }
    var error by remember(path) { mutableStateOf<String?>(null) }
    var loading by remember(path) { mutableStateOf(true) }
    suspend fun load() {
        loading = true
        runCatching {
            model.workspaceSection(peer, "workspace.diff", buildJsonObject {
                put("id", workspace); put("path", path)
            }) as? JsonObject
        }.onSuccess { diff = it; error = null }
            .onFailure { error = TunnelCopy.display(it.message ?: L10n.text("android.workspacechanges.the_request_failed.db4fb447"), hostLabel) }
        loading = false
    }
    LaunchedEffect(path) { load() }
    DiffDocumentView(diffs = listOfNotNull(diff), modifier = modifier, fileHeaders = false) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            TextButton(onClick = onBack, modifier = Modifier.weight(1f)) {
                Text(L10n.text("android.workspacechanges.changes.47127cfb"), modifier = Modifier.fillMaxWidth())
            }
            if (onEdit != null && diff != null && diff!!.bol("binary") != true) {
                TsAccentButton(label = L10n.text("common.edit"), small = true, onClick = onEdit)
            }
        }
        Text(path, style = TsType.mono(13), color = LocalTsColors.current.textPrimary)
        if (error != null) {
            StickyErrorCard(
                message = error!!,
                onRetry = { scope.launch { load() } },
                onDismiss = { error = null },
            )
        }
        if (loading) {
            Text(L10n.text("android.workspacechanges.loading.ba3bbbe1"), color = LocalTsColors.current.textSecondary)
        } else if (diff == null && error == null) {
            Text(L10n.text("android.workspacechanges.that_file_is_not_in_this_folder_any_more.da5bd527"), color = LocalTsColors.current.textSecondary)
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
            L10n.text("android.workspacechanges.this_is_a_binary_file_there_is_nothing_to.6573d54c"),
            color = colors.textSecondary,
        )
        return
    }
    val hunks = asObjects(diff["hunks"])
    if (hunks.isEmpty()) {
        Text(
            if (diff.bol("untracked")) L10n.text("android.workspacechanges.this_file_is_not_tracked_yet_and_is_empty.7354c94b")
            else L10n.text("android.workspacechanges.no_changes_against_head.84a982f2"),
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
                    overflow = TextOverflow.Ellipsis,
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
                L10n.text("android.workspacechanges.showing_the_first_0_of_1_lines.348d454c", "${maxLines}", "${total}"),
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
