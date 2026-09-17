// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.workspace

import ai.tokenstat.tokenstat.ui.components.ActionIcon
import ai.tokenstat.tokenstat.ui.components.TsSecondaryButton

import ai.tokenstat.tokenstat.ui.chrome.TabBarChrome
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ArrowUpward
import androidx.compose.material.icons.filled.History
import androidx.compose.material3.Icon
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
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import ai.tokenstat.tokenstat.AppViewModel
import ai.tokenstat.tokenstat.ui.components.Banner
import ai.tokenstat.tokenstat.ui.components.BannerSeverity
import ai.tokenstat.tokenstat.ui.components.CommitTagPills
import ai.tokenstat.tokenstat.ui.components.EmptyState
import ai.tokenstat.tokenstat.ui.components.RelativeTimeText
import ai.tokenstat.tokenstat.ui.components.TsType
import ai.tokenstat.tokenstat.ui.components.cardRadiusDp
import ai.tokenstat.tokenstat.ui.logic.TunnelCopy
import ai.tokenstat.tokenstat.ui.marks.EmptyArt
import ai.tokenstat.tokenstat.ui.marks.EmptyArtKind
import ai.tokenstat.tokenstat.ui.theme.LocalTsColors
import ai.tokenstat.tokenstat.ui.theme.Space
import kotlinx.coroutines.launch
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.longOrNull
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put

/// Previous commits in this folder, newest first.
///
/// Ports `ClientWorkspaceHistoryView`: read-only browsing of what landed.
/// `workspace.log` is empty both when the folder is not a repository and
/// when it has no commits yet, so status is asked as well and each draws a
/// different picture.
@Composable
fun HistorySection(
    model: AppViewModel,
    peer: String,
    workspace: String,
    modifier: Modifier = Modifier,
    folderName: String = "",
    hostLabel: String = "",
) {
    val scope = rememberCoroutineScope()
    var commits by remember { mutableStateOf<List<JsonObject>>(emptyList()) }
    var exists by remember { mutableStateOf(true) }
    var isRepo by remember { mutableStateOf(true) }
    var error by remember { mutableStateOf<String?>(null) }
    var loaded by remember { mutableStateOf(false) }
    var openId by remember { mutableStateOf<String?>(null) }

    suspend fun load() {
        runCatching {
            model.workspaceSection(peer, "workspace.log", buildJsonObject { put("id", workspace) })
        }.onSuccess { element ->
            commits = asObjects(element)
            error = null
        }.onFailure { error = TunnelCopy.display(it.message ?: "The request failed.", hostLabel) }
        runCatching {
            model.workspaceSection(peer, "workspace.status", buildJsonObject { put("id", workspace) }) as? JsonObject
        }.onSuccess { folder ->
            exists = folder?.bol("exists") ?: true
            isRepo = (folder?.get("git") as? JsonObject)?.bol("isRepo") ?: true
        }
        loaded = true
    }
    LaunchedEffect(peer, workspace) { load() }

    val place = hostLabel.ifBlank { "the computer" }

    val opened = openId
    if (opened != null) {
        val commit = commits.firstOrNull { it.str("id") == opened }
        if (commit != null) {
            CommitDetailPage(
                model = model,
                peer = peer,
                workspace = workspace,
                hostLabel = hostLabel,
                commit = commit,
                modifier = modifier,
                onBack = { openId = null },
            )
            return
        }
    }

    Column(modifier, verticalArrangement = Arrangement.spacedBy(Space.s)) {
        // No second "History": the pushed header above already names the
        // section, and repeating it cost a row for nothing.
        Row(
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.End,
            modifier = Modifier.fillMaxWidth(),
        ) {
            TsSecondaryButton(
                label = "Refresh",
                icon = ActionIcon.Refresh.vector,
                small = true,
                onClick = { scope.launch { load() } },
            )
        }
        if (error != null) Banner(error!!, BannerSeverity.DANGER)
        if (!exists) {
            EmptyState(
                Icons.Default.History,
                "Folder missing",
                "This folder is no longer on $place.",
                art = { EmptyArt(EmptyArtKind.History) },
            )
        } else if (loaded && !isRepo && error == null) {
            EmptyState(
                Icons.Default.History,
                "Not a git repository",
                "This folder has no commits to browse. Make it a repository on $place and they will appear here.",
                art = { EmptyArt(EmptyArtKind.History) },
            )
        } else if (loaded && commits.isEmpty() && error == null) {
            EmptyState(
                Icons.Default.History,
                "No commits yet",
                "Commit selected files in Changes and the result will appear here.",
                art = { EmptyArt(EmptyArtKind.History) },
            )
        } else {
            LazyColumn(contentPadding = PaddingValues(bottom = TabBarChrome.contentBottomInset), verticalArrangement = Arrangement.spacedBy(Space.s)) {
                items(commits, key = { it.str("id") ?: it.hashCode().toString() }) { commit ->
                    CommitRow(commit, onOpen = { openId = commit.str("id") })
                }
            }
        }
    }
}

private fun shortId(id: String): String = id.take(7)

@Composable
private fun CommitRow(commit: JsonObject, onOpen: () -> Unit) {
    val subject = commit.str("subject") ?: ""
    val author = commit.str("author") ?: ""
    val timestamp = commit.get("timestamp")?.jsonPrimitive?.longOrNull ?: 0L
    val id = commit.str("id") ?: ""
    val tags = (commit["tags"] as? kotlinx.serialization.json.JsonArray)
        ?.mapNotNull { it.jsonPrimitive.contentOrNull } ?: emptyList()
    val unpushed = commit.bol("unpushed")
    Row(
        Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(cardRadiusDp))
            .background(LocalTsColors.current.panel)
            .clickable(onClick = onOpen)
            .padding(Space.m),
        verticalAlignment = Alignment.Top,
        horizontalArrangement = Arrangement.spacedBy(Space.s),
    ) {
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(3.dp)) {
            Text(
                subject,
                style = TextStyle(fontSize = 14.sp, fontWeight = FontWeight.Medium),
                color = LocalTsColors.current.textPrimary,
                maxLines = 2,
            )
            CommitTagPills(tags)
            Row(horizontalArrangement = Arrangement.spacedBy(5.dp), verticalAlignment = Alignment.CenterVertically) {
                Text(author, style = TextStyle(fontSize = 12.sp), color = LocalTsColors.current.textSecondary, maxLines = 1)
                Text("·", style = TextStyle(fontSize = 12.sp), color = LocalTsColors.current.textSecondary)
                if (timestamp > 0) {
                    RelativeTimeText(
                        timestamp * 1000,
                        style = TextStyle(fontSize = 12.sp),
                        color = LocalTsColors.current.textSecondary,
                    )
                }
                Text("·", style = TextStyle(fontSize = 12.sp), color = LocalTsColors.current.textSecondary)
                Text(shortId(id), style = TsType.mono(12), color = LocalTsColors.current.textSecondary)
                if (unpushed) {
                    Icon(Icons.Default.ArrowUpward, "Not pushed yet", tint = LocalTsColors.current.accent)
                }
            }
        }
    }
}

/// One commit as a full page: what it says, then every file it changed.
@Composable
private fun CommitDetailPage(
    model: AppViewModel,
    peer: String,
    workspace: String,
    hostLabel: String,
    commit: JsonObject,
    modifier: Modifier = Modifier,
    onBack: () -> Unit,
) {
    val scope = rememberCoroutineScope()
    var detail by remember(commit) { mutableStateOf<JsonObject?>(null) }
    var error by remember(commit) { mutableStateOf<String?>(null) }
    var loaded by remember(commit) { mutableStateOf(false) }

    suspend fun load() {
        runCatching {
            model.workspaceSection(peer, "workspace.show", buildJsonObject {
                put("id", workspace); put("path", commit.str("id") ?: "")
            }) as? JsonObject
        }.onSuccess { detail = it; error = null }
            .onFailure { error = TunnelCopy.display(it.message ?: "The request failed.", hostLabel) }
        loaded = true
    }
    LaunchedEffect(commit) { load() }

    val id = commit.str("id") ?: ""
    val subject = detail?.str("subject") ?: commit.str("subject") ?: ""
    val body = detail?.str("body") ?: ""
    val author = detail?.str("author") ?: commit.str("author") ?: ""
    val timestamp = detail?.get("timestamp")?.jsonPrimitive?.longOrNull
        ?: commit.get("timestamp")?.jsonPrimitive?.longOrNull ?: 0L
    val tags = (detail?.get("tags") as? kotlinx.serialization.json.JsonArray)
        ?.mapNotNull { it.jsonPrimitive.contentOrNull }
        ?: (commit["tags"] as? kotlinx.serialization.json.JsonArray)?.mapNotNull { it.jsonPrimitive.contentOrNull }
        ?: emptyList()
    val parents = (detail?.get("parents") as? kotlinx.serialization.json.JsonArray)?.size ?: 0
    val isMerge = parents >= 2
    val files = detail?.let { asObjects(it["files"]) } ?: emptyList()
    val diffs = detail?.let { asObjects(it["diffs"]) } ?: emptyList()
    val added = detail?.get("added")?.jsonPrimitive?.longOrNull ?: 0L
    val removed = detail?.get("removed")?.jsonPrimitive?.longOrNull ?: 0L

    Column(
        modifier.verticalScroll(rememberScrollState()).padding(bottom = TabBarChrome.contentBottomInset),
        verticalArrangement = Arrangement.spacedBy(Space.s),
    ) {
            TextButton(onClick = onBack, modifier = Modifier.fillMaxWidth()) {
                Text("← History", modifier = Modifier.fillMaxWidth())
            }
            Text(shortId(id), style = TsType.mono(13), color = LocalTsColors.current.textSecondary)
            if (error != null) {
                StickyErrorCard(
                    message = error!!,
                    onRetry = { scope.launch { load() } },
                    onDismiss = { error = null },
                )
            }
            Column(
                Modifier
                    .fillMaxWidth()
                    .clip(RoundedCornerShape(cardRadiusDp))
                    .background(LocalTsColors.current.panel)
                    .padding(Space.m),
                verticalArrangement = Arrangement.spacedBy(Space.s),
            ) {
                Text(subject, style = TextStyle(fontSize = 16.sp, fontWeight = FontWeight.SemiBold), color = LocalTsColors.current.textPrimary)
                if (body.isNotEmpty()) {
                    Text(body, style = TextStyle(fontSize = 14.sp), color = LocalTsColors.current.textSecondary)
                }
                CommitTagPills(tags)
                Row(horizontalArrangement = Arrangement.spacedBy(Space.s), verticalAlignment = Alignment.CenterVertically) {
                    Text(author, style = TextStyle(fontSize = 12.sp), color = LocalTsColors.current.textSecondary, maxLines = 1)
                    if (timestamp > 0) {
                        RelativeTimeText(timestamp * 1000, style = TextStyle(fontSize = 12.sp), color = LocalTsColors.current.textTertiary)
                    }
                    Text(shortId(id), style = TsType.mono(12), color = LocalTsColors.current.textTertiary)
                    if (isMerge) {
                        Text("merge", style = TextStyle(fontSize = 12.sp, fontWeight = FontWeight.Medium), color = LocalTsColors.current.textSecondary)
                    }
                }
                if (detail != null) {
                    Row(horizontalArrangement = Arrangement.spacedBy(Space.s)) {
                        if (added > 0) Text("+$added", style = TsType.numeric(12), color = LocalTsColors.current.diffAdded)
                        if (removed > 0) Text("−$removed", style = TsType.numeric(12), color = LocalTsColors.current.diffRemoved)
                        Text(
                            "${files.size} file${if (files.size == 1) "" else "s"}",
                            style = TextStyle(fontSize = 12.sp),
                            color = LocalTsColors.current.textSecondary,
                        )
                    }
                }
            }
            if (!loaded) {
                Text("Loading…", color = LocalTsColors.current.textSecondary)
            } else if (detail != null) {
                if (diffs.isEmpty()) {
                    EmptyState(
                        Icons.Default.History,
                        if (isMerge) "A merge with no patch of its own" else "No files in this commit",
                        if (isMerge) "The changes live on the parents." else "This commit changed no files.",
                        art = { EmptyArt(EmptyArtKind.History) },
                    )
                } else {
                    diffs.forEach { diff ->
                        val path = diff.str("path") ?: ""
                        Column(
                            Modifier
                                .fillMaxWidth()
                                .clip(RoundedCornerShape(cardRadiusDp))
                                .background(LocalTsColors.current.panel)
                                .padding(Space.m),
                            verticalArrangement = Arrangement.spacedBy(Space.xs),
                        ) {
                            Text(
                                path.substringAfterLast('/').ifBlank { path },
                                style = TextStyle(fontSize = 14.sp, fontWeight = FontWeight.Medium),
                                color = LocalTsColors.current.textPrimary,
                                maxLines = 1,
                            )
                            if (path.contains('/')) {
                                Text(path, style = TextStyle(fontSize = 11.sp), color = LocalTsColors.current.textSecondary, maxLines = 1)
                            }
                            if (diff.bol("binary")) {
                                Text(
                                    "This is a binary file. There is nothing to show line by line.",
                                    style = TextStyle(fontSize = 12.sp),
                                    color = LocalTsColors.current.textSecondary,
                                )
                            } else if (asObjects(diff["hunks"]).isEmpty()) {
                                Text(
                                    "No line changes in this file.",
                                    style = TextStyle(fontSize = 12.sp),
                                    color = LocalTsColors.current.textSecondary,
                                )
                            } else {
                                HunkDiffView(diff)
                            }
                        }
                    }
                }
            }
    }
}
