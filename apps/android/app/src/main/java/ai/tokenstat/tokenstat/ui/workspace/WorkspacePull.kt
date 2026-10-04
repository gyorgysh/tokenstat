// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.workspace

import ai.tokenstat.tokenstat.AppViewModel
import ai.tokenstat.tokenstat.ui.chrome.TabBarChrome
import ai.tokenstat.tokenstat.ui.components.ActionIcon
import ai.tokenstat.tokenstat.ui.components.Banner
import ai.tokenstat.tokenstat.ui.components.BannerSeverity
import ai.tokenstat.tokenstat.ui.components.TsAccentButton
import ai.tokenstat.tokenstat.ui.components.TsSecondaryButton
import ai.tokenstat.tokenstat.ui.localization.L10n
import ai.tokenstat.tokenstat.ui.logic.HostContracts
import ai.tokenstat.tokenstat.ui.logic.TunnelCopy
import ai.tokenstat.tokenstat.ui.theme.LocalTsColors
import ai.tokenstat.tokenstat.ui.theme.Space
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Text
import androidx.compose.material3.Icon
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.Alignment
import androidx.compose.ui.unit.dp
import androidx.compose.foundation.layout.size
import androidx.compose.ui.platform.LocalUriHandler
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.sp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import kotlinx.coroutines.launch
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put

/// Pull beside Push. Drawing it reads nothing remote: the dialog it opens is
/// what fetches, because a person pressed it. Port of GitPullView.swift.
@Composable
fun PullButton(
    model: AppViewModel,
    peer: String,
    workspace: String,
    folderName: String,
    hostLabel: String,
    incoming: Int,
    protocol: Long?,
    onPulled: () -> Unit,
) {
    if (!HostContracts.supportsReviewedPull(protocol)) return
    var presenting by remember { mutableStateOf(false) }
    TsSecondaryButton(
        label = if (incoming > 0) L10n.text("android.gitpull.pull_count", "$incoming") else L10n.text("android.gitpull.pull"),
        icon = ActionIcon.Download.vector,
        small = true,
        onClick = { presenting = true },
    )
    if (presenting) {
        PullSheet(model, peer, workspace, folderName, hostLabel, onDismiss = { presenting = false }, onPulled = onPulled)
    }
}

private fun JsonObject.count(key: String): Long = get(key)?.jsonPrimitive?.contentOrNull?.toLongOrNull() ?: 0L

@Composable
private fun PullSheet(
    model: AppViewModel,
    peer: String,
    workspace: String,
    folderName: String,
    hostLabel: String,
    onDismiss: () -> Unit,
    onPulled: () -> Unit,
) {
    val scope = rememberCoroutineScope()
    val colors = LocalTsColors.current
    var review by remember { mutableStateOf<JsonObject?>(null) }
    var outcome by remember { mutableStateOf<JsonObject?>(null) }
    var working by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }

    suspend fun check() {
        working = true
        error = null
        outcome = null
        try {
            runCatching {
                model.workspaceSection(peer, "workspace.pullReview", buildJsonObject { put("id", workspace) }) as? JsonObject
            }.onSuccess {
                review = it
                // The fetch moved ahead and behind, so the folder's numbers move too.
                onPulled()
            }.onFailure {
                review = null
                error = TunnelCopy.display(it.message ?: L10n.text("android.gitpull.failed"), hostLabel)
            }
        } finally {
            working = false
        }
    }

    suspend fun pull(reviewed: JsonObject) {
        working = true
        error = null
        try {
            runCatching {
                model.workspaceSection(peer, "workspace.pullReviewed", buildJsonObject {
                    put("id", workspace)
                    put("review", reviewed)
                }) as? JsonObject
            }.onSuccess {
                outcome = it
                onPulled()
            }.onFailure {
                error = TunnelCopy.display(it.message ?: L10n.text("android.gitpull.failed"), hostLabel)
            }
        } finally {
            working = false
        }
    }

    LaunchedEffect(Unit) { check() }

    val state = review?.str("state")
    val incoming = review?.count("incoming") ?: 0L
    val outgoing = review?.count("outgoing") ?: 0L
    val pulled = outcome?.bol("ok") == true

    Dialog(onDismissRequest = onDismiss, properties = DialogProperties(usePlatformDefaultWidth = false)) {
        Column(
            Modifier
                .fillMaxWidth()
                .padding(Space.m)
                .verticalScroll(rememberScrollState()).padding(bottom = TabBarChrome.contentBottomInset),
            verticalArrangement = Arrangement.spacedBy(Space.m),
        ) {
            Column {
                Text(L10n.text("android.gitpull.title"), style = TextStyle(fontSize = 17.sp, fontWeight = FontWeight.SemiBold), color = colors.textPrimary)
                val subtitle = listOfNotNull(folderName.takeIf { it.isNotBlank() }, hostLabel.takeIf { it.isNotBlank() }).joinToString(" · ")
                if (subtitle.isNotBlank()) Text(subtitle, style = TextStyle(fontSize = 12.sp), color = colors.textSecondary)
            }
            review?.let { shown ->
                Column(verticalArrangement = Arrangement.spacedBy(Space.xs)) {
                    Text((shown.str("branch") ?: "").removePrefix("refs/heads/"), style = TextStyle(fontSize = 16.sp, fontWeight = FontWeight.SemiBold), color = colors.textPrimary)
                    val source = (shown.str("remote") ?: "") + "/" + (shown.str("remoteRef") ?: "").removePrefix("refs/heads/")
                    Text(L10n.text("android.gitpull.from", source), style = TextStyle(fontSize = 14.sp), color = colors.textSecondary)
                    if (outcome == null) {
                        val summary = when (state) {
                            "upToDate" -> L10n.text("android.gitpull.up_to_date")
                            "ahead" -> L10n.text("android.gitpull.ahead")
                            "fastForward" -> if (incoming == 1L) L10n.text("android.gitpull.incoming.one", "1") else L10n.text("android.gitpull.incoming.other", "$incoming")
                            "diverged" -> L10n.text("android.gitpull.diverged", "$incoming", "$outgoing")
                            else -> L10n.text("android.gitpull.missing")
                        }
                        Text(summary, style = TextStyle(fontSize = 14.sp), color = if (state == "diverged" || state == "missing") colors.warning else colors.textPrimary)
                    }
                }
            }
            outcome?.str("message")?.let { Banner(it, if (pulled) BannerSeverity.SUCCESS else BannerSeverity.DANGER) }
            error?.let { Banner(it, BannerSeverity.DANGER) }
            if (working) {
                Text(if (review == null) L10n.text("android.gitpull.checking") else L10n.text("android.gitpull.pulling"), style = TextStyle(fontSize = 14.sp), color = colors.textSecondary)
            }
            Text(L10n.text("android.gitpull.help"), style = TextStyle(fontSize = 12.sp), color = colors.textSecondary)
            Row(horizontalArrangement = Arrangement.spacedBy(Space.s)) {
                TsSecondaryButton(label = L10n.text("common.close"), small = true, onClick = onDismiss, modifier = Modifier.weight(1f))
                val reviewed = review
                when {
                    pulled || state == "upToDate" ->
                        TsAccentButton(label = L10n.text("common.done"), small = true, modifier = Modifier.weight(1f), onClick = onDismiss)
                    reviewed != null && state == "fastForward" && outcome == null ->
                        TsAccentButton(
                            label = if (incoming == 1L) L10n.text("android.gitpull.pull_commits.one", "1") else L10n.text("android.gitpull.pull_commits.other", "$incoming"),
                            small = true,
                            enabled = !working,
                            modifier = Modifier.weight(1f),
                            onClick = { scope.launch { pull(reviewed) } },
                        )
                    else ->
                        TsAccentButton(
                            label = L10n.text("android.gitpull.check_again"),
                            small = true,
                            enabled = !working,
                            modifier = Modifier.weight(1f),
                            onClick = { scope.launch { check() } },
                        )
                }
            }
        }
    }
}

/// The branch's pull request, or the way to open one, beside Pull and Push.
@Composable
fun BranchPullButton(
    model: AppViewModel,
    peer: String,
    workspace: String,
    branch: String?,
    folderName: String,
    hostLabel: String,
    protocol: Long?,
) {
    if (!HostContracts.supportsReviewedPull(protocol)) return
    val uri = LocalUriHandler.current
    var answer by remember(peer, workspace, branch) { mutableStateOf<JsonObject?>(null) }
    var creating by remember { mutableStateOf(false) }
    val scope = rememberCoroutineScope()
    suspend fun load(refresh: Boolean) {
        answer = null
        val loaded = runCatching {
            model.workspaceSection(peer, "pulls.branch", buildJsonObject {
                put("workspaceId", workspace)
                put("branch", branch.orEmpty())
                put("refresh", refresh)
            }) as? JsonObject
        }.getOrNull()
        currentCoroutineContext().ensureActive()
        answer = loaded
    }
    LaunchedEffect(peer, workspace, branch) { load(refresh = false) }
    val pull = answer?.get("pull") as? JsonObject
    if (pull != null) {
        TsSecondaryButton(
            label = L10n.text("android.branchpull.number", pull.str("number") ?: ""),
            icon = ActionIcon.External.vector,
            small = true,
            onClick = { pull.str("url")?.takeIf { it.startsWith("https://") }?.let { runCatching { uri.openUri(it) } } },
        )
    } else if (answer?.bol("connected") == true && answer?.str("branch") != null) {
        TsSecondaryButton(
            label = L10n.text("android.branchpull.create"),
            icon = ActionIcon.Merge.vector,
            small = true,
            onClick = { creating = true },
        )
    }
    if (creating) {
        PullCreateDialog(model, peer, workspace, protocol, folderName, hostLabel,
            onDismiss = { creating = false },
            onCreated = { scope.launch { load(refresh = true) } })
    }
}

/// A cached state mark on a conversation row. Drawing it never asks the forge.
@Composable
fun BranchPullBadge(pull: JsonObject) {
    val colors = LocalTsColors.current
    val state = branchPullState(pull)
    val tint = when (pull.str("state")) {
        "merged" -> colors.secondary
        "closed" -> colors.danger
        else -> if (pull.bol("draft")) colors.stateIdle else colors.accent
    }
    Icon(ActionIcon.Merge.vector,
        L10n.text("android.branchpull.help", state, pull.str("number").orEmpty(), pull.str("title").orEmpty()),
        tint = tint, modifier = Modifier.size(14.dp))
}

private fun branchPullState(pull: JsonObject): String = when (pull.str("state")) {
    "merged" -> L10n.text("android.branchpull.merged")
    "closed" -> L10n.text("android.branchpull.closed")
    else -> if (pull.bol("draft")) L10n.text("android.branchpull.draft") else L10n.text("android.branchpull.open")
}

/// The project's current changes and pull request, above the composer.
@Composable
fun ChatGitStrip(model: AppViewModel, peer: String, workspace: String, chat: JsonObject?,
    protocol: Long?, owner: Any?, offline: Boolean, running: Boolean, onReview: () -> Unit) {
    var git by remember(owner, chat?.str("id")) { mutableStateOf<JsonObject?>(null) }
    var pull by remember(owner, chat?.str("id")) { mutableStateOf<JsonObject?>(null) }
    var wasRunning by remember(owner, chat?.str("id")) { mutableStateOf(false) }
    val uri = LocalUriHandler.current
    LaunchedEffect(owner, chat?.str("id"), peer, workspace, chat?.str("branch"), running, offline, protocol) {
        val finished = wasRunning && !running
        wasRunning = running
        git = null
        pull = null
        if (offline) return@LaunchedEffect
        val status = runCatching {
            model.workspaceSection(peer, "workspace.status", buildJsonObject { put("id", workspace) }) as? JsonObject
        }.getOrNull()
        currentCoroutineContext().ensureActive()
        git = status?.get("git") as? JsonObject
        val branch = git?.str("branch") ?: return@LaunchedEffect
        if (running || !HostContracts.supportsReviewedPull(protocol)) return@LaunchedEffect
        val answer = runCatching {
            model.workspaceSection(peer, "pulls.branch", buildJsonObject {
                put("workspaceId", workspace)
                put("branch", branch)
                put("refresh", finished)
            }) as? JsonObject
        }.getOrNull()
        currentCoroutineContext().ensureActive()
        pull = answer?.get("pull") as? JsonObject
    }
    val files = git?.get("files") as? kotlinx.serialization.json.JsonArray
    if (files.isNullOrEmpty() && pull == null) return
    androidx.compose.foundation.layout.FlowRow(Modifier.fillMaxWidth(),
        horizontalArrangement = Arrangement.spacedBy(Space.s), verticalArrangement = Arrangement.spacedBy(Space.xs)) {
        if (!files.isNullOrEmpty()) {
            TsSecondaryButton(label = if (files.size == 1) L10n.text("android.chatchanges.files_changed.one", "1")
                else L10n.text("android.chatchanges.files_changed.other", "${files.size}"),
                icon = ActionIcon.Preview.vector, small = true, onClick = onReview)
        }
        pull?.let { request ->
            TsSecondaryButton(label = L10n.text("android.branchpull.chip", request.str("number").orEmpty(), branchPullState(request)),
                icon = ActionIcon.Merge.vector, small = true, onClick = {
                    request.str("url")?.takeIf { it.startsWith("https://") }?.let { runCatching { uri.openUri(it) } }
                })
        }
    }
}
