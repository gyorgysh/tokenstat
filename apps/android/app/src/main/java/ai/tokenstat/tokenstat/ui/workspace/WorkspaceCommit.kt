// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.workspace

import ai.tokenstat.tokenstat.ui.localization.L10n

import ai.tokenstat.tokenstat.ui.chrome.TabBarChrome
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Surface
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.OutlinedTextField
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
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import ai.tokenstat.tokenstat.AppViewModel
import ai.tokenstat.tokenstat.ui.components.Banner
import ai.tokenstat.tokenstat.ui.components.BannerSeverity
import ai.tokenstat.tokenstat.ui.components.TsAccentButton
import ai.tokenstat.tokenstat.ui.components.TsSecondaryButton
import ai.tokenstat.tokenstat.ui.components.TsType
import ai.tokenstat.tokenstat.ui.components.cardRadiusDp
import ai.tokenstat.tokenstat.ui.logic.CommitDraft
import ai.tokenstat.tokenstat.ui.logic.HostContracts
import ai.tokenstat.tokenstat.ui.logic.OperationState
import ai.tokenstat.tokenstat.ui.logic.PushLabel
import ai.tokenstat.tokenstat.ui.logic.ReviewClip
import ai.tokenstat.tokenstat.ui.logic.TunnelCopy
import ai.tokenstat.tokenstat.ui.theme.LocalTsColors
import ai.tokenstat.tokenstat.ui.theme.Space
import kotlinx.coroutines.launch
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put

/// The review composer: title, description, the frozen selection with a
/// reviewed diff per file, then Commit. Ports `GitCommitComposer` on the
/// phone (focused composer, files as pushed rows).
///
/// The draft (title, details, selection, submitted operation) is preserved
/// across restarts. Reopening with a submission reconciles that record
/// before another commit is allowed.
@Composable
fun CommitComposerDialog(
    model: AppViewModel,
    state: CommitUiState,
    folderName: String,
    hostLabel: String,
    supportsSelectedCommit: Boolean,
    onDismiss: () -> Unit,
    onCommitted: () -> Unit,
) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()

    LaunchedEffect(state.operationId) {
        state.restore(context)
        if (state.review == null && state.operationId == null) {
            state.prepareReview(model, hostLabel, supportsSelectedCommit)
        }
    }

    val review = state.review
    val submitted = state.operationId != null
    val outcomeState = state.outcomeState
    val contextLine = listOfNotNull(
        folderName.takeIf { it.isNotBlank() },
        review?.str("branch")?.removePrefix("refs/heads/"),
        hostLabel.takeIf { it.isNotBlank() },
    ).joinToString(" · ")
    val reviewPaths = review?.let { reviewPathsOf(it) } ?: emptyList()
    val outcomeMessage = state.outcome?.str("message")

    Dialog(onDismissRequest = onDismiss, properties = DialogProperties(usePlatformDefaultWidth = false)) {
        Column(
            Modifier
                .fillMaxWidth()
                .padding(Space.m)
                .verticalScroll(rememberScrollState()).padding(bottom = TabBarChrome.contentBottomInset),
            verticalArrangement = Arrangement.spacedBy(Space.m),
        ) {
            Column {
                Text(
                    L10n.text("android.workspacecommit.review_and_commit.96f097b7"),
                    style = TextStyle(fontSize = 17.sp, fontWeight = FontWeight.SemiBold),
                    color = LocalTsColors.current.textPrimary,
                )
                if (contextLine.isNotBlank()) {
                    Text(contextLine, style = TextStyle(fontSize = 12.sp), color = LocalTsColors.current.textSecondary)
                }
            }
            if (state.error != null) Banner(state.error!!, BannerSeverity.DANGER)
            if (outcomeMessage != null) {
                Banner(
                    outcomeMessage,
                    if (outcomeState == "succeeded") BannerSeverity.SUCCESS else BannerSeverity.DANGER,
                )
            }
            if (CommitDraft.messageTooLong(state.title, state.details)) {
                Banner(L10n.text("android.workspacecommit.shorten_the_commit_message_to_128_kib_or_l.ffe20f8c"), BannerSeverity.DANGER)
            }
            Column(verticalArrangement = Arrangement.spacedBy(Space.s)) {
                Text(L10n.text("android.workspacecommit.commit_title.30459372"), style = TextStyle(fontSize = 14.sp, fontWeight = FontWeight.SemiBold), color = LocalTsColors.current.textPrimary)
                OutlinedTextField(
                    state.title,
                    { state.title = it; scope.launch { state.save(context) } },
                    modifier = Modifier.fillMaxWidth(),
                    placeholder = { Text(L10n.text("android.workspacecommit.describe_the_change.beaee364")) },
                    enabled = state.loaded && !state.working && !submitted,
                    maxLines = 3,
                )
                Text(L10n.text("android.workspacecommit.description_optional.f6cbe2f0"), style = TextStyle(fontSize = 12.sp), color = LocalTsColors.current.textSecondary)
                OutlinedTextField(
                    state.details,
                    { state.details = it; scope.launch { state.save(context) } },
                    modifier = Modifier.fillMaxWidth(),
                    minLines = 4,
                    enabled = state.loaded && !state.working && !submitted,
                )
            }
            if (review != null) {
                val count = reviewPaths.size
                Text(
                    L10n.text("android.workspacecommit.0_selected_1.3a4c3bb6", "${count}", "${if (count == 1) L10n.text("android.workspacecommit.file.3b9c358f") else L10n.text("android.workspacecommit.files.3d7db37d")}"),
                    style = TextStyle(fontSize = 14.sp, fontWeight = FontWeight.SemiBold),
                    color = LocalTsColors.current.textPrimary,
                )
                reviewPaths.forEach { path ->
                    ReviewedFileRow(model, state.peer, state.workspace, hostLabel, review, path)
                }
            } else if (state.working) {
                Text(L10n.text("android.workspacecommit.preparing_review.6cafe23d"), color = LocalTsColors.current.textSecondary)
            }
            Row(horizontalArrangement = Arrangement.spacedBy(Space.s)) {
                TsSecondaryButton(label = L10n.text("common.close"), small = true, onClick = onDismiss, modifier = Modifier.weight(1f))
                if (submitted) {
                    TsAccentButton(
                        label = if (state.canRetry) L10n.text("android.workspacecommit.retry_same_submission.3dbca561") else L10n.text("android.workspacecommit.check_outcome.9200a2fd"),
                        small = true,
                        enabled = !state.working,
                        modifier = Modifier.weight(2f),
                        onClick = {
                            scope.launch {
                                if (state.canRetry) state.retry(model, hostLabel, context)
                                else state.checkOutcome(model, hostLabel, context)
                                if (state.outcomeState == "succeeded") {
                                    onCommitted()
                                    onDismiss()
                                }
                            }
                        },
                    )
                } else if (outcomeState == "succeeded") {
                    TsAccentButton(label = L10n.text("common.done"), small = true, modifier = Modifier.weight(2f), onClick = onDismiss)
                } else if (review == null) {
                    TsAccentButton(
                        label = L10n.text("android.workspacecommit.review_selected_files.fb340554"),
                        small = true,
                        enabled = !state.working,
                        modifier = Modifier.weight(2f),
                        onClick = { scope.launch { state.prepareReview(model, hostLabel, supportsSelectedCommit) } },
                    )
                } else {
                    val count = reviewPaths.size
                    TsAccentButton(
                        label = L10n.text("android.workspacecommit.commit_0_1.ed71a626", "${count}", "${if (count == 1) L10n.text("android.workspacecommit.file.3b9c358f") else L10n.text("android.workspacecommit.files.3d7db37d")}"),
                        small = true,
                        enabled = state.canCommit,
                        modifier = Modifier.weight(2f),
                        onClick = {
                            scope.launch {
                                state.submit(model, hostLabel, context)
                                if (state.outcomeState == "succeeded") {
                                    onCommitted()
                                    onDismiss()
                                }
                            }
                        },
                    )
                }
            }
        }
    }
}

private fun reviewPathsOf(review: JsonObject): List<String> =
    (review["includedPaths"] as? JsonArray)?.mapNotNull {
        it.jsonPrimitive.contentOrNull
    } ?: emptyList()

/// One reviewed file: its path, and the immutable diff frozen for this
/// submission, even if the worktree moved since.
@Composable
private fun ReviewedFileRow(
    model: AppViewModel,
    peer: String,
    workspace: String,
    hostLabel: String,
    review: JsonObject,
    path: String,
) {
    val scope = rememberCoroutineScope()
    var open by remember(path) { mutableStateOf(false) }
    var diff by remember(path) { mutableStateOf<JsonObject?>(null) }
    var error by remember(path) { mutableStateOf<String?>(null) }
    var loading by remember(path) { mutableStateOf(false) }

    suspend fun load() {
        loading = true
        runCatching {
            model.workspaceSection(peer, "workspace.commitReviewDiff", buildJsonObject {
                put("id", workspace)
                put("review", review)
                put("path", path)
            }) as? JsonObject
        }.onSuccess { diff = it; error = null }
            .onFailure { error = TunnelCopy.display(it.message ?: L10n.text("android.workspacecommit.the_request_failed.db4fb447"), hostLabel) }
        loading = false
    }

    Column(
        Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(cardRadiusDp))
            .background(LocalTsColors.current.panel)
            .clickable {
                open = !open
                if (open && diff == null && !loading) scope.launch { load() }
            }
            .padding(Space.s),
    ) {
        Text(path, style = TextStyle(fontSize = 14.sp), color = LocalTsColors.current.textPrimary, maxLines = 2)
        if (open) {
            if (loading) Text(L10n.text("android.workspacecommit.reading_reviewed_changes.9c829fac"), style = TextStyle(fontSize = 12.sp), color = LocalTsColors.current.textSecondary)
            else if (error != null) Banner(error!!, BannerSeverity.DANGER)
            else if (diff != null) {
                if (diff!!.bol("binary")) {
                    Text(
                        L10n.text("android.workspacecommit.binary_file_included_in_this_reviewed_sele.7b9e8582"),
                        style = TextStyle(fontSize = 12.sp),
                        color = LocalTsColors.current.textSecondary,
                    )
                } else {
                    HunkDiffView(diff!!, maxLines = 2000)
                }
            }
        }
    }
}

/// Push control and sheet, porting `GitPushControl` and `GitPushView`.
///
/// Loading restores the persisted operation identity; it never pushes.
/// After a lost response the outcome is checked before another push, and
/// only a missing receipt allows retrying the same submission. A finished
/// push clears the submission.
@Composable
fun PushButton(
    model: AppViewModel,
    peer: String,
    workspace: String,
    folderName: String,
    hostLabel: String,
    outgoing: Int,
    protocol: Long?,
    onPushed: () -> Unit,
) {
    var presenting by remember { mutableStateOf(false) }
    var submitted by remember { mutableStateOf<String?>(null) }
    val context = LocalContext.current
    LaunchedEffect(peer, workspace) {
        val prefs = context.getSharedPreferences("tokenstat.push.v1", android.content.Context.MODE_PRIVATE)
        submitted = prefs.getString("$peer|$workspace|operationId", null)
    }
    TsSecondaryButton(
        label = PushLabel.label(submitted != null, outgoing.toLong()),
        small = true,
        onClick = { presenting = true },
    )
    if (presenting) {
        PushSheet(
            model = model,
            peer = peer,
            workspace = workspace,
            folderName = folderName,
            hostLabel = hostLabel,
            supportsReviewedPush = HostContracts.supportsReviewedPush(protocol),
            initialOperationId = submitted,
            onOperationId = { opId ->
                submitted = opId
                context.getSharedPreferences("tokenstat.push.v1", android.content.Context.MODE_PRIVATE)
                    .edit().putString(L10n.text("android.workspacecommit.0_1_operationid.e339e779", "${peer}", "${workspace}"), opId).apply()
            },
            onDismiss = { presenting = false },
            onPushed = onPushed,
        )
    }
}

@Composable
private fun PushSheet(
    model: AppViewModel,
    peer: String,
    workspace: String,
    folderName: String,
    hostLabel: String,
    supportsReviewedPush: Boolean,
    initialOperationId: String?,
    onOperationId: (String?) -> Unit,
    onDismiss: () -> Unit,
    onPushed: () -> Unit,
) {
    val scope = rememberCoroutineScope()
    var review by remember { mutableStateOf<JsonObject?>(null) }
    var operationId by remember { mutableStateOf(initialOperationId) }
    var outcome by remember { mutableStateOf<JsonObject?>(null) }
    var canRetry by remember { mutableStateOf(false) }
    var working by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }

    suspend fun prepare() {
        if (working || operationId != null) return
        working = true
        try {
            if (!supportsReviewedPush) {
                error = L10n.text("android.workspacecommit.update_this_computer_s_tokenstat_to_review.8147f2b4")
                return
            }
            runCatching {
                model.workspaceSection(peer, "workspace.pushReview", buildJsonObject { put("id", workspace) }) as? JsonObject
            }.onSuccess { review = it; outcome = null; error = null }
                .onFailure { error = TunnelCopy.display(it.message ?: L10n.text("android.workspacecommit.the_request_failed.db4fb447"), hostLabel) }
        } finally {
            working = false
        }
    }

    suspend fun send(retry: Boolean) {
        val frozen = review ?: return
        val opId = operationId ?: run {
            val fresh = java.util.UUID.randomUUID().toString()
            operationId = fresh
            onOperationId(fresh)
            fresh
        }
        canRetry = false
        working = true
        try {
            runCatching {
                model.workspaceSection(peer, "workspace.pushReviewed", buildJsonObject {
                    put("id", workspace)
                    put("operationId", opId)
                    put("review", frozen)
                    put("retry", retry)
                }) as? JsonObject
            }.onSuccess { receipt ->
                if (receipt != null && receipt.str("operationId") == opId && receipt.get("review") == frozen) {
                    outcome = receipt
                    error = null
                    canRetry = receipt.bol("retryAllowed")
                    val state = receipt.str("state") ?: ""
                    if (state == "succeeded" || state == "failed") {
                        operationId = null
                        review = null
                        onOperationId(null)
                        if (state == "succeeded") onPushed()
                    }
                }
            }.onFailure {
                error = L10n.text("android.workspacecommit.the_push_outcome_has_not_been_confirmed_ch.128c6a9f", "${TunnelCopy.display(it.message ?: L10n.text("android.workspacecommit.the_request_failed.db4fb447"), hostLabel)}")
            }
        } finally {
            working = false
        }
    }

    suspend fun checkOutcome() {
        val opId = operationId ?: return
        if (working) return
        working = true
        try {
            val receipt = runCatching {
                model.workspaceSection(peer, "workspace.pushReceipt", buildJsonObject {
                    put("id", workspace); put("operationId", opId)
                }) as? JsonObject
            }.getOrNull()
            if (receipt != null) {
                val state = receipt.str("state") ?: ""
                if (state == "succeeded" || state == "failed") {
                    outcome = receipt
                    error = null
                    canRetry = receipt.bol("retryAllowed")
                    operationId = null
                    review = null
                    onOperationId(null)
                    if (state == "succeeded") onPushed()
                } else {
                    val recovered = runCatching {
                        model.workspaceSection(peer, "workspace.pushRecover", buildJsonObject {
                            put("id", workspace); put("operationId", opId)
                        }) as? JsonObject
                    }.getOrNull()
                    if (recovered != null) {
                        outcome = recovered
                        error = null
                        val recoveredState = recovered.str("state") ?: ""
                        canRetry = recovered.bol("retryAllowed")
                        if (recoveredState == "succeeded" || recoveredState == "failed") {
                            operationId = null
                            review = null
                            onOperationId(null)
                            if (recoveredState == "succeeded") onPushed()
                        }
                    }
                }
            } else {
                canRetry = true
                error = L10n.text("android.workspacecommit.this_computer_has_no_receipt_for_the_submi.cadba34a")
            }
        } catch (e: Exception) {
            error = TunnelCopy.display(e.message ?: L10n.text("android.workspacecommit.the_request_failed.db4fb447"), hostLabel)
        } finally {
            working = false
        }
    }

    LaunchedEffect(Unit) { prepare() }

    val shown = review ?: outcome?.get("review") as? JsonObject
    val outcomeState = outcome?.str("state")
    val submitted = operationId != null

    Dialog(onDismissRequest = onDismiss, properties = DialogProperties(usePlatformDefaultWidth = false)) {
        Column(
            Modifier
                .fillMaxWidth()
                .padding(Space.m)
                .verticalScroll(rememberScrollState()).padding(bottom = TabBarChrome.contentBottomInset),
            verticalArrangement = Arrangement.spacedBy(Space.m),
        ) {
            Column {
                Text(
                    L10n.text("android.workspacecommit.push_branch.97deb7c0"),
                    style = TextStyle(fontSize = 17.sp, fontWeight = FontWeight.SemiBold),
                    color = LocalTsColors.current.textPrimary,
                )
                val subtitle = listOfNotNull(folderName.takeIf { it.isNotBlank() }, hostLabel.takeIf { it.isNotBlank() })
                    .joinToString(" · ")
                if (subtitle.isNotBlank()) {
                    Text(subtitle, style = TextStyle(fontSize = 12.sp), color = LocalTsColors.current.textSecondary)
                }
            }
            if (shown != null) {
                Column(verticalArrangement = Arrangement.spacedBy(Space.xs)) {
                    Text(
                        (shown.str("branch") ?: "").removePrefix("refs/heads/"),
                        style = TextStyle(fontSize = 16.sp, fontWeight = FontWeight.SemiBold),
                        color = LocalTsColors.current.textPrimary,
                    )
                    val remote = shown.str("remote") ?: ""
                    val remoteRef = (shown.str("remoteRef") ?: "").removePrefix("refs/heads/")
                    if (remote.isNotBlank()) {
                        Text(L10n.text("android.workspacecommit.to_0_1.cbcce59b", "${remote}", "${remoteRef}"), style = TextStyle(fontSize = 14.sp), color = LocalTsColors.current.textSecondary)
                    }
                    (shown.str("head") ?: "").take(10).takeIf { it.isNotBlank() }?.let {
                        Text(it, style = TsType.mono(12), color = LocalTsColors.current.textSecondary)
                    }
                    val head = shown.str("head")
                    val remoteHead = shown.str("remoteHead")
                    val outgoing = shown.get("outgoing")?.jsonPrimitive?.contentOrNull?.toLongOrNull()
                    when {
                        remoteHead == head -> Text(L10n.text("android.workspacecommit.this_branch_is_up_to_date.01b49ce3"), style = TextStyle(fontSize = 14.sp), color = LocalTsColors.current.accent)
                        outgoing == 0L -> Text(L10n.text("android.workspacecommit.no_outgoing_commits_the_remote_branch_is_a.7072ceca"), style = TextStyle(fontSize = 14.sp), color = LocalTsColors.current.textPrimary)
                        remoteHead == null -> Text(L10n.text("android.workspacecommit.publish_this_branch_to_0.e623bfa9", "${remote}"), style = TextStyle(fontSize = 14.sp), color = LocalTsColors.current.textPrimary)
                        outgoing != null -> Text(L10n.text("android.workspacecommit.0_1_to_push.190b18e2", "${outgoing}", "${if (outgoing == 1L) L10n.text("android.workspacecommit.commit.9505cacb") else L10n.text("android.workspacecommit.commits.02686016")}"), style = TextStyle(fontSize = 14.sp), color = LocalTsColors.current.textPrimary)
                        else -> Text(L10n.text("android.workspacecommit.the_computer_will_check_whether_the_remote.2c0a07ce"), style = TextStyle(fontSize = 14.sp), color = LocalTsColors.current.textPrimary)
                    }
                    if (shown.bol("setUpstream")) {
                        Text(
                            L10n.text("android.workspacecommit.this_will_also_set_the_branch_s_tracking_d.95dfeac0"),
                            style = TextStyle(fontSize = 12.sp),
                            color = LocalTsColors.current.textSecondary,
                        )
                    }
                }
            }
            outcome?.str("message")?.let {
                Banner(it, if (outcomeState == "succeeded") BannerSeverity.SUCCESS else BannerSeverity.DANGER)
            }
            if (error != null) Banner(error!!, BannerSeverity.DANGER)
            if (working) {
                Text(
                    if (submitted) L10n.text("android.workspacecommit.checking_push.00fa6ce0") else L10n.text("android.workspacecommit.checking_the_branch.3733503a"),
                    style = TextStyle(fontSize = 14.sp),
                    color = LocalTsColors.current.textSecondary,
                )
            }
            Row(horizontalArrangement = Arrangement.spacedBy(Space.s)) {
                TsSecondaryButton(label = L10n.text("common.close"), small = true, onClick = onDismiss, modifier = Modifier.weight(1f))
                if (submitted) {
                    if (canRetry) {
                        TsSecondaryButton(
                            label = L10n.text("android.workspacecommit.retry_same_push.d4ab8f02"),
                            small = true,
                            enabled = !working,
                            modifier = Modifier.weight(1f),
                            onClick = { scope.launch { send(retry = true) } },
                        )
                    }
                    TsAccentButton(
                        label = L10n.text("android.workspacecommit.check_outcome.9200a2fd"),
                        small = true,
                        enabled = !working,
                        modifier = Modifier.weight(1f),
                        onClick = { scope.launch { checkOutcome() } },
                    )
                } else if (outcomeState == "succeeded" || shown?.let { it.str("remoteHead") == it.str("head") } == true || shown?.get("outgoing")?.jsonPrimitive?.contentOrNull == "0") {
                    TsAccentButton(label = L10n.text("common.done"), small = true, modifier = Modifier.weight(1f), onClick = onDismiss)
                } else if (review != null) {
                    TsAccentButton(
                        label = if (review!!.str("remoteHead") == null) L10n.text("android.workspacecommit.publish_branch.e1f5968c") else L10n.text("android.workspacecommit.push_branch.97deb7c0"),
                        small = true,
                        enabled = !working,
                        modifier = Modifier.weight(1f),
                        onClick = { scope.launch { send(retry = false) } },
                    )
                } else {
                    TsAccentButton(
                        label = L10n.text("android.workspacecommit.check_branch.8128e71f"),
                        small = true,
                        enabled = !working,
                        modifier = Modifier.weight(1f),
                        onClick = { scope.launch { prepare() } },
                    )
                }
            }
        }
    }
}

/// The branch this folder is on, and the way to switch it. One selector per
/// folder, drawn under the push row like the Apple folder header.
@Composable
fun BranchRow(
    model: AppViewModel,
    peer: String,
    workspace: String,
    hostLabel: String,
    branch: String?,
    isRepo: Boolean,
    onChanged: () -> Unit,
    /// Ahead, behind and the diff stat, when there is anything waiting. The
    /// Apple folder header carries them on this row rather than making you
    /// open Changes to find out whether there is anything to open it for.
    stats: String? = null,
) {
    var showing by remember { mutableStateOf(false) }
    if (!isRepo) return
    Row(
        Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(10.dp))
            .background(LocalTsColors.current.accent.copy(alpha = 0.09f))
            .clickable { showing = true }
            .padding(horizontal = Space.s, vertical = 7.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(Space.xs),
    ) {
        Text(
            L10n.text("android.workspacecommit.branch_0.e742d863", "${branch ?: L10n.text("android.workspacecommit.detached.88e34e4c")}"),
            style = TextStyle(fontSize = 12.sp),
            color = LocalTsColors.current.accent,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
        )
        Text(
            stats.orEmpty(),
            style = TextStyle(fontSize = 12.sp),
            color = LocalTsColors.current.accent.copy(alpha = 0.75f),
            modifier = Modifier.weight(1f),
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
        )
        Text(L10n.text("android.workspacecommit.switch.39921a74"), style = TextStyle(fontSize = 12.sp), color = LocalTsColors.current.accent)
    }
    if (showing) {
        BranchDialog(
            model = model,
            peer = peer,
            workspace = workspace,
            hostLabel = hostLabel,
            current = branch,
            onDismiss = { showing = false },
            onChanged = { showing = false; onChanged() },
        )
    }
}

@Composable
private fun BranchDialog(
    model: AppViewModel,
    peer: String,
    workspace: String,
    hostLabel: String,
    current: String?,
    onDismiss: () -> Unit,
    onChanged: () -> Unit,
) {
    val scope = rememberCoroutineScope()
    var branches by remember { mutableStateOf<List<JsonObject>>(emptyList()) }
    var error by remember { mutableStateOf<String?>(null) }
    var loading by remember { mutableStateOf(true) }
    var working by remember { mutableStateOf(false) }
    var newName by remember { mutableStateOf("") }

    suspend fun load() {
        loading = true
        runCatching {
            model.workspaceSection(peer, "workspace.branches", buildJsonObject { put("id", workspace) })
        }.onSuccess {
            branches = asObjects(it)
            error = null
        }.onFailure { error = TunnelCopy.display(it.message ?: L10n.text("android.workspacecommit.the_request_failed.db4fb447"), hostLabel) }
        loading = false
    }
    LaunchedEffect(Unit) { load() }

    fun checkout(name: String) {
        working = true
        scope.launch {
            runCatching {
                model.workspaceSection(peer, "workspace.checkout", buildJsonObject {
                    put("id", workspace); put("branch", name)
                })
            }.onSuccess { onChanged() }
                .onFailure { error = TunnelCopy.display(it.message ?: L10n.text("android.workspacecommit.the_request_failed.db4fb447"), hostLabel) }
            working = false
        }
    }

    fun create(name: String) {
        val clean = name.trim()
        if (clean.isEmpty()) return
        working = true
        scope.launch {
            runCatching {
                model.workspaceSection(peer, "workspace.createBranch", buildJsonObject {
                    put("id", workspace); put("branch", clean)
                })
            }.onSuccess { onChanged() }
                .onFailure { error = TunnelCopy.display(it.message ?: L10n.text("android.workspacecommit.the_request_failed.db4fb447"), hostLabel) }
            working = false
        }
    }

    Dialog(onDismissRequest = onDismiss, properties = DialogProperties(usePlatformDefaultWidth = false)) {
        // A sheet with a surface under it. Without one the title drew over
        // the dimmed screen behind, the rows floated as loose cards, and the
        // create row landed on top of the tab bar.
        Surface(
            shape = RoundedCornerShape(20.dp),
            color = LocalTsColors.current.background,
            tonalElevation = 0.dp,
            shadowElevation = 12.dp,
            modifier = Modifier
                .fillMaxWidth(0.94f)
                .fillMaxHeight(0.86f),
        ) {
        Column(
            Modifier
                .fillMaxWidth()
                .padding(Space.m),
            verticalArrangement = Arrangement.spacedBy(Space.s),
        ) {
            Text(L10n.text("android.workspacecommit.switch_branch.5051902c"), style = TextStyle(fontSize = 17.sp, fontWeight = FontWeight.SemiBold), color = LocalTsColors.current.textPrimary)
            if (error != null) Banner(error!!, BannerSeverity.DANGER)
            if (loading) {
                Text(L10n.text("android.workspacecommit.loading.ba3bbbe1"), color = LocalTsColors.current.textSecondary)
            } else {
                // The list scrolls itself; scrolling the dialog Column too
                // would measure it with infinite height and crash.
                LazyColumn(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(Space.xs)) {
                    items(branches, key = { it.str("name") ?: it.hashCode().toString() }) { branchRow ->
                        val name = branchRow.str("name") ?: return@items
                        val isCurrent = branchRow.bol("current") || name == current
                        Row(
                            Modifier
                                .fillMaxWidth()
                                .clip(RoundedCornerShape(cardRadiusDp))
                                .background(LocalTsColors.current.panel)
                                .clickable(enabled = !isCurrent && !working) { checkout(name) }
                                .padding(Space.m),
                            verticalAlignment = Alignment.CenterVertically,
                        ) {
                            Column(Modifier.weight(1f)) {
                                Text(name, style = TsType.mono(13), color = LocalTsColors.current.textPrimary, maxLines = 1)
                                branchRow.str("upstream")?.takeIf { it.isNotBlank() }?.let {
                                    Text(it, style = TextStyle(fontSize = 11.sp), color = LocalTsColors.current.textSecondary, maxLines = 1)
                                }
                            }
                            if (isCurrent) {
                                Text(L10n.text("android.workspacecommit.current.e0d1b682"), style = TextStyle(fontSize = 11.sp, fontWeight = FontWeight.Medium), color = LocalTsColors.current.accent)
                            }
                        }
                    }
                }
            }
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(Space.s)) {
                OutlinedTextField(
                    newName,
                    { newName = it },
                    modifier = Modifier.weight(1f),
                    placeholder = { Text(L10n.text("android.workspacecommit.new_branch_name.514cee61")) },
                    singleLine = true,
                )
                TsAccentButton(label = L10n.text("android.workspacecommit.create.4759498a"), small = true, enabled = newName.trim().isNotEmpty() && !working, onClick = { create(newName) })
            }
            TsSecondaryButton(label = L10n.text("common.close"), small = true, onClick = onDismiss)
        }
        }
    }
}

/// Every changed file's diff on one screen, for the final read before a
/// commit. Bounded twice: at most twenty files, sixty lines each, with a
/// Full diff link per file for the rest.
@Composable
fun ReviewAllPage(
    model: AppViewModel,
    peer: String,
    workspace: String,
    hostLabel: String,
    files: List<JsonObject>,
    modifier: Modifier = Modifier,
    onBack: () -> Unit,
    onOpenFile: (String) -> Unit,
) {
    val shown = files.take(ReviewClip.MAX_FILES)
    val leftover = (files.size - shown.size).coerceAtLeast(0)
    var diffs by remember { mutableStateOf<Map<String, JsonObject>>(emptyMap()) }
    var failures by remember { mutableStateOf(0) }
    var loaded by remember { mutableStateOf(false) }
    LaunchedEffect(files) {
        val fresh = mutableMapOf<String, JsonObject>()
        var missed = 0
        for (file in shown) {
            val path = file.str("path") ?: continue
            runCatching {
                model.workspaceSection(peer, "workspace.diff", buildJsonObject {
                    put("id", workspace); put("path", path)
                }) as? JsonObject
            }.onSuccess { if (it != null) fresh[path] = it else missed += 1 }
                .onFailure { missed += 1 }
        }
        diffs = fresh
        failures = missed
        loaded = true
    }
    Column(
        modifier.verticalScroll(rememberScrollState()).padding(bottom = TabBarChrome.contentBottomInset),
        verticalArrangement = Arrangement.spacedBy(Space.m),
    ) {
            TextButton(onClick = onBack, modifier = Modifier.fillMaxWidth()) {
                Text(L10n.text("android.workspacecommit.changes.47127cfb"), modifier = Modifier.fillMaxWidth())
            }
            Text(L10n.text("android.workspacecommit.review_all.d05163fa"), style = TextStyle(fontSize = 17.sp, fontWeight = FontWeight.SemiBold), color = LocalTsColors.current.textPrimary)
            if (!loaded) {
                Text(L10n.text("android.workspacecommit.loading.ba3bbbe1"), color = LocalTsColors.current.textSecondary)
            } else {
                if (failures > 0) {
                    Text(
                        ReviewClip.failureLine(failures),
                        style = TextStyle(fontSize = 12.sp),
                        color = LocalTsColors.current.textSecondary,
                    )
                }
                shown.forEach { file ->
                    val path = file.str("path") ?: return@forEach
                    val name = path.substringAfterLast('/')
                    Column(
                        Modifier
                            .fillMaxWidth()
                            .clip(RoundedCornerShape(cardRadiusDp))
                            .background(LocalTsColors.current.panel)
                            .padding(Space.m),
                        verticalArrangement = Arrangement.spacedBy(Space.s),
                    ) {
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Text(
                                name.ifBlank { path },
                                style = TextStyle(fontSize = 14.sp, fontWeight = FontWeight.SemiBold),
                                color = LocalTsColors.current.textPrimary,
                                modifier = Modifier.weight(1f),
                                maxLines = 1,
                                overflow = TextOverflow.Ellipsis,
                            )
                            (file.str("kind") ?: "").takeIf { it.isNotBlank() }?.let {
                                Text(it, style = TextStyle(fontSize = 11.sp, fontWeight = FontWeight.Medium), color = LocalTsColors.current.accent)
                            }
                        }
                        val diff = diffs[path]
                        if (diff != null) {
                            if (diff.bol("binary")) {
                                Text(
                                    L10n.text("android.workspacecommit.a_binary_file_there_is_nothing_to_show_lin.d8a6c19c"),
                                    style = TextStyle(fontSize = 12.sp),
                                    color = LocalTsColors.current.textSecondary,
                                )
                            } else {
                                val total = asObjects(diff["hunks"]).sumOf { asObjects(it["lines"]).size }
                                HunkDiffView(diff, maxLines = ReviewClip.LINES_PER_FILE)
                                if (total > ReviewClip.LINES_PER_FILE) {
                                    Text(
                                        ReviewClip.leftoverLine(total, ReviewClip.LINES_PER_FILE),
                                        style = TextStyle(fontSize = 12.sp),
                                        color = LocalTsColors.current.textSecondary,
                                    )
                                }
                            }
                        } else {
                            Text(L10n.text("android.workspacecommit.still_loading.fa2e3194"), style = TextStyle(fontSize = 12.sp), color = LocalTsColors.current.textTertiary)
                        }
                        Text(
                            L10n.text("android.workspacecommit.full_diff.79eeb065"),
                            style = TextStyle(fontSize = 14.sp, fontWeight = FontWeight.Medium),
                            color = LocalTsColors.current.accent,
                            modifier = Modifier.clickable { onOpenFile(path) },
                        )
                    }
                }
                if (leftover > 0) {
                    Text(
                        ReviewClip.leftoverFilesLine(leftover),
                        style = TextStyle(fontSize = 12.sp),
                        color = LocalTsColors.current.textSecondary,
                    )
                }
            }
    }
}
