// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.workspace

import ai.tokenstat.tokenstat.ui.localization.L10n

import androidx.activity.compose.BackHandler
import androidx.browser.customtabs.CustomTabsIntent
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowForward
import androidx.compose.material.icons.automirrored.filled.CallSplit
import androidx.compose.material.icons.automirrored.filled.Label
import androidx.compose.material.icons.filled.AutoAwesome
import androidx.compose.material.icons.filled.ChatBubbleOutline
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.Circle
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Commit
import androidx.compose.material.icons.filled.Description
import androidx.compose.material.icons.filled.Edit
import androidx.compose.material.icons.filled.Merge
import androidx.compose.material.icons.filled.MoreHoriz
import androidx.compose.material.icons.filled.People
import androidx.compose.material.icons.filled.Visibility
import androidx.compose.material.icons.outlined.CheckCircle
import androidx.compose.material.icons.outlined.WarningAmber
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
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
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.core.net.toUri
import ai.tokenstat.tokenstat.AppViewModel
import ai.tokenstat.tokenstat.ui.chrome.TabBarChrome
import ai.tokenstat.tokenstat.ui.components.ActionIcon
import ai.tokenstat.tokenstat.ui.components.EmptyState
import ai.tokenstat.tokenstat.ui.components.RelativeTimeText
import ai.tokenstat.tokenstat.ui.components.SkeletonBar
import ai.tokenstat.tokenstat.ui.components.TsAccentButton
import ai.tokenstat.tokenstat.ui.components.TsDangerButton
import ai.tokenstat.tokenstat.ui.components.TsSecondaryButton
import ai.tokenstat.tokenstat.ui.components.TsType
import ai.tokenstat.tokenstat.ui.components.cardPaddingDp
import ai.tokenstat.tokenstat.ui.components.cardRadiusDp
import ai.tokenstat.tokenstat.ui.logic.PullReview
import ai.tokenstat.tokenstat.ui.logic.TunnelCopy
import ai.tokenstat.tokenstat.ui.marks.Avatar
import ai.tokenstat.tokenstat.ui.marks.avatarTint
import ai.tokenstat.tokenstat.ui.theme.LocalTsColors
import ai.tokenstat.tokenstat.ui.theme.Space
import kotlinx.coroutines.launch
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonObjectBuilder
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.put

/// Which part of a pull request is on show. The same three the Apple client
/// has, in the same order and with the same words, so a person who knows one
/// phone knows the other.
internal enum class PullTab(val title: String) {
    Conversation(L10n.text("android.pulldetail.conversation.ccca1817")),
    Changes(L10n.text("android.pulldetail.changes.bbd4b6a8")),
    Checks(L10n.text("android.pulldetail.checks.de07d072")),
    ;

    val icon: ImageVector
        get() = when (this) {
            Conversation -> Icons.Default.ChatBubbleOutline
            Changes -> Icons.Default.Description
            Checks -> Icons.Default.CheckCircle
        }
}

/// One pull request as a full management page, port of `PullDetailView`.
///
/// Conversation is the default and the only tab loaded at open; the diff is
/// several hundred kilobytes on a Dependabot bump, so it is fetched the first
/// time Changes is opened and not before. The inspector and the actions panel
/// sit below the reading column, which is where the Apple layout puts them on
/// a phone.
@Composable
internal fun PullDetailPage(
    model: AppViewModel,
    peer: String,
    workspace: String,
    hostLabel: String,
    number: Long,
    modifier: Modifier = Modifier,
    /// The row that was tapped, so the loading page can already carry the
    /// title and the author instead of a bare spinner.
    summary: JsonObject? = null,
    onBack: () -> Unit,
) {
    val colors = LocalTsColors.current
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var detail by remember(number) { mutableStateOf<JsonObject?>(null) }
    var timeline by remember(number) { mutableStateOf<List<JsonObject>>(emptyList()) }
    var nextCursor by remember(number) { mutableStateOf<String?>(null) }
    var diffs by remember(number) { mutableStateOf<List<JsonObject>>(emptyList()) }
    var selectedPath by remember(number) { mutableStateOf<String?>(null) }
    var tab by remember(number) { mutableStateOf(PullTab.Conversation) }
    var error by remember(number) { mutableStateOf<String?>(null) }
    var timelineError by remember(number) { mutableStateOf<String?>(null) }
    var diffError by remember(number) { mutableStateOf<String?>(null) }
    var actionError by remember(number) { mutableStateOf<String?>(null) }
    var actionNotice by remember(number) { mutableStateOf<String?>(null) }
    var loading by remember(number) { mutableStateOf(true) }
    var loadingTimeline by remember(number) { mutableStateOf(false) }
    var loadingDiff by remember(number) { mutableStateOf(false) }
    var actionBusy by remember(number) { mutableStateOf(false) }
    var commentDraft by remember(number) { mutableStateOf("") }
    var reviewMode by remember(number) { mutableStateOf<String?>(null) }
    var reviewDraft by remember(number) { mutableStateOf("") }
    var mergeMethod by remember(number) { mutableStateOf("squash") }
    var checkoutBranch by remember(number) { mutableStateOf("") }
    var confirmingClose by remember(number) { mutableStateOf(false) }
    var confirmingMerge by remember(number) { mutableStateOf(false) }

    suspend fun loadTimeline(cursor: String? = null, append: Boolean = false) {
        if (loadingTimeline) return
        loadingTimeline = true
        runCatching {
            model.workspaceSection(peer, "pulls.timeline", buildJsonObject {
                put("workspaceId", workspace); put("number", number); put("refresh", false)
                if (cursor != null) put("cursor", cursor)
            })
        }.onSuccess { element ->
            val page = element as? JsonObject
            val fresh = asObjects(page?.get("events")).ifEmpty { asObjects(element) }
            timeline = if (append) timeline + fresh else fresh
            nextCursor = page?.str("nextCursor")
            timelineError = null
        }.onFailure {
            timelineError = TunnelCopy.display(it.message ?: L10n.text("android.pulldetail.the_request_failed.db4fb447"), hostLabel)
        }
        loadingTimeline = false
    }

    suspend fun loadDiff(refresh: Boolean = false) {
        if (loadingDiff || (diffs.isNotEmpty() && !refresh)) return
        loadingDiff = true
        runCatching {
            model.workspaceSection(peer, "pulls.diff", buildJsonObject {
                put("workspaceId", workspace); put("number", number); put("refresh", refresh)
            })
        }.onSuccess { element ->
            val obj = element as? JsonObject
            diffs = asObjects(element).ifEmpty { asObjects(obj?.get("diffs")) }.ifEmpty { asObjects(obj?.get("files")) }
            selectedPath = diffs.firstOrNull()?.str("path")
            diffError = null
        }.onFailure {
            diffError = TunnelCopy.display(it.message ?: L10n.text("android.pulldetail.the_request_failed.db4fb447"), hostLabel)
        }
        loadingDiff = false
    }

    suspend fun load(refresh: Boolean = false) {
        loading = true
        runCatching {
            model.workspaceSection(peer, "pulls.view", buildJsonObject {
                put("workspaceId", workspace); put("number", number); put("refresh", refresh)
            }) as? JsonObject
        }.onSuccess {
            val view = (it?.get("pull") as? JsonObject) ?: it
            detail = view
            error = null
            // The branch to check out is the one this pull request is on,
            // until the person types another.
            if (checkoutBranch.isBlank()) checkoutBranch = view?.str("headRef").orEmpty()
            loadTimeline()
            if (tab == PullTab.Changes) loadDiff(refresh = refresh)
        }.onFailure { error = TunnelCopy.display(it.message ?: L10n.text("android.pulldetail.the_request_failed.db4fb447"), hostLabel) }
        loading = false
    }
    LaunchedEffect(number) { load() }
    // Opening Changes is what pays for the diff, exactly as on the Apple
    // client: the bytes are the expensive part of this page.
    LaunchedEffect(tab) { if (tab == PullTab.Changes) loadDiff() }
    // Back belongs to the pull request first: it returns to the list, rather
    // than closing the whole section from under the person.
    BackHandler { onBack() }

    suspend fun act(label: String, method: String, params: JsonObjectBuilder.() -> Unit) {
        if (actionBusy) return
        actionBusy = true
        actionNotice = null
        try {
            runCatching {
                model.workspaceSection(peer, method, buildJsonObject {
                    put("workspaceId", workspace); put("number", number)
                    params()
                })
            }.onSuccess {
                actionError = null
                actionNotice = label
                load(refresh = true)
            }.onFailure {
                actionError = TunnelCopy.display(it.message ?: L10n.text("android.pulldetail.the_request_failed.db4fb447"), hostLabel)
            }
        } finally {
            actionBusy = false
        }
    }

    val view = detail
    Column(
        modifier
            .verticalScroll(rememberScrollState())
            .padding(bottom = TabBarChrome.contentBottomInset),
        verticalArrangement = Arrangement.spacedBy(Space.l),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(Space.s)) {
            TsSecondaryButton(label = L10n.text("android.pulldetail.pull_requests.d9e3f260"), icon = ActionIcon.Back.vector, small = true, onClick = onBack)
            Spacer(Modifier.weight(1f))
            view?.str("url")?.takeIf { it.isNotBlank() }?.let { url ->
                TsSecondaryButton(
                    label = L10n.text("android.pulldetail.open_on_github.03f69885"),
                    icon = ActionIcon.External.vector,
                    small = true,
                    onClick = { runCatching { CustomTabsIntent.Builder().build().launchUrl(context, url.toUri()) } },
                )
            }
            PullToolbarIconButton(
                icon = ActionIcon.Refresh.vector,
                description = L10n.text("android.pulldetail.refresh_pull_request.fc146ac9"),
                busy = loading,
                onClick = { scope.launch { load(refresh = true) } },
            )
        }
        if (error != null && view == null) {
            Column(verticalArrangement = Arrangement.spacedBy(Space.m)) {
                PullInlineError(error!!)
                TsAccentButton(
                    label = L10n.text("android.pulldetail.try_again.d8b8392e"),
                    icon = ActionIcon.Refresh.vector,
                    small = true,
                    onClick = { scope.launch { load(refresh = true) } },
                )
            }
        } else if (view != null) {
            PullHero(view, number)
            PullDetailTabs(selection = tab, checks = asObjects(view["checks"]).size) { tab = it }
            actionNotice?.let {
                PullNotice(it, tint = colors.success, icon = Icons.Outlined.CheckCircle) { actionNotice = null }
            }
            actionError?.let {
                PullNotice(it, tint = colors.warning, icon = Icons.Outlined.WarningAmber) { actionError = null }
            }
            when (tab) {
                PullTab.Conversation -> PullConversationTab(
                    view = view,
                    timeline = timeline,
                    nextCursor = nextCursor,
                    loadingTimeline = loadingTimeline,
                    timelineError = timelineError,
                    commentDraft = commentDraft,
                    onCommentDraft = { commentDraft = it },
                    busy = actionBusy,
                    onMore = { scope.launch { loadTimeline(nextCursor, append = true) } },
                    onComment = {
                        val body = commentDraft.trim()
                        if (body.isNotEmpty()) {
                            commentDraft = ""
                            scope.launch { act(L10n.text("android.pulldetail.comment_posted.f79769cc"), "pulls.comment") { put("body", body) } }
                        }
                    },
                )
                PullTab.Changes -> PullChangesTab(
                    diffs = diffs,
                    selectedPath = selectedPath,
                    onSelectPath = { selectedPath = it },
                    loading = loadingDiff,
                    error = diffError,
                )
                PullTab.Checks -> PullChecksTab(view)
            }
            PullInspectorCard(view)
            PullActionsPanel(
                view = view,
                busy = actionBusy,
                reviewMode = reviewMode,
                reviewDraft = reviewDraft,
                onReviewDraft = { reviewDraft = it },
                onBeginReview = { reviewMode = it; reviewDraft = ""; actionError = null },
                onCancelReview = { reviewMode = null; reviewDraft = "" },
                onApprove = { scope.launch { act(L10n.text("android.pulldetail.review_approved.0978fd61"), "pulls.review") { put("verdict", "approve"); put("body", "") } } },
                onSendReview = { mode ->
                    val body = reviewDraft.trim()
                    if (body.isNotEmpty()) {
                        reviewMode = null
                        reviewDraft = ""
                        val message = if (mode == "requestChanges") L10n.text("android.pulldetail.changes_requested.10a92a8a") else L10n.text("android.pulldetail.review_comment_posted.b23f0868")
                        scope.launch { act(message, "pulls.review") { put("verdict", mode); put("body", body) } }
                    }
                },
                onReady = { scope.launch { act(L10n.text("android.pulldetail.ready_for_review.75c2a5c8"), "pulls.ready") {} } },
                onClose = { confirmingClose = true },
                onReopen = { scope.launch { act(L10n.text("android.pulldetail.pull_request_reopened.03ed9cfc"), "pulls.reopen") {} } },
                mergeMethod = mergeMethod,
                onMergeMethod = { mergeMethod = it },
                onMerge = { confirmingMerge = true },
                checkoutBranch = checkoutBranch,
                onCheckoutBranch = { checkoutBranch = it },
                onCheckout = {
                    val branch = checkoutBranch.trim()
                    if (branch.isNotEmpty()) {
                        scope.launch { act(L10n.text("android.pulldetail.checked_out_0.d61914af", "${branch}"), "pulls.checkout") { put("branch", branch) } }
                    }
                },
            )
        } else {
            PullDetailSkeleton(summary = summary, number = number)
        }
    }
    if (confirmingClose) {
        AlertDialog(
            onDismissRequest = { confirmingClose = false },
            title = { Text(L10n.text("android.pulldetail.close_this_pull_request.54b5c0b1")) },
            text = { Text(L10n.text("android.pulldetail.other_people_will_see_it_as_closed_you_can.7b0cb552")) },
            confirmButton = {
                TextButton(onClick = {
                    confirmingClose = false
                    scope.launch { act(L10n.text("android.pulldetail.pull_request_closed.2babc563"), "pulls.close") {} }
                }) { Text(L10n.text("android.pulldetail.close_pull_request.672e174d")) }
            },
            dismissButton = { TextButton(onClick = { confirmingClose = false }) { Text(L10n.text("common.cancel")) } },
        )
    }
    if (confirmingMerge) {
        AlertDialog(
            onDismissRequest = { confirmingMerge = false },
            title = { Text(L10n.text("android.pulldetail.merge_this_pull_request.6ea40a2a")) },
            text = { Text(L10n.text("android.pulldetail.this_changes_the_shared_repository_and_can.ef54ace2")) },
            confirmButton = {
                TextButton(onClick = {
                    confirmingMerge = false
                    scope.launch { act(L10n.text("android.pulldetail.pull_request_merged.5f0f1f6d"), "pulls.merge") { put("mergeMethod", mergeMethod) } }
                }) { Text(L10n.text("android.pulldetail.merge_with_0.9456a9db", "${PullReview.mergeTitle(mergeMethod).lowercase()}")) }
            },
            dismissButton = { TextButton(onClick = { confirmingMerge = false }) { Text(L10n.text("common.cancel")) } },
        )
    }
}

/// Title, who opened it and when, then the state, the two branches and what
/// the change weighs. Accent-edged rather than hairline: it is the one card
/// on the page that says what this pull request *is*.
@Composable
private fun PullHero(view: JsonObject, number: Long) {
    val colors = LocalTsColors.current
    val shape = RoundedCornerShape(cardRadiusDp)
    val state = view.str("state").orEmpty()
    val draft = view.bol("draft")
    val author = view["author"] as? JsonObject
    val login = author?.str("login") ?: view.str("author").orEmpty()
    Column(
        Modifier
            .fillMaxWidth()
            .clip(shape)
            .background(colors.panel)
            .border(1.dp, colors.accent.copy(alpha = 0.18f), shape)
            .padding(cardPaddingDp),
        verticalArrangement = Arrangement.spacedBy(Space.m),
    ) {
        Row(horizontalArrangement = Arrangement.spacedBy(Space.m)) {
            PullStateMark(state = state, draft = draft)
            Column(verticalArrangement = Arrangement.spacedBy(Space.xs)) {
                Text(
                    view.str("title").orEmpty(),
                    style = TsType.title3.copy(fontWeight = FontWeight.SemiBold),
                    color = colors.textPrimary,
                )
                Row(
                    horizontalArrangement = Arrangement.spacedBy(Space.s),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Avatar(
                        name = login,
                        size = 22,
                        avatarUrl = author?.str("avatar"),
                        tint = avatarTint(login, colors),
                        decorative = true,
                    )
                    Text(
                        login,
                        style = TsType.footnote.copy(fontWeight = FontWeight.Medium),
                        color = colors.textPrimary,
                    )
                }
                Row(
                    horizontalArrangement = Arrangement.spacedBy(Space.s),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Text(L10n.text("android.pulldetail.opened_0.095c9540", "${number}"), style = TsType.footnote, color = colors.textSecondary)
                    pullEpochMillis(view.str("createdAt"))?.let {
                        Text("·", style = TsType.footnote, color = colors.textTertiary)
                        // The iPhone's abbreviated formatter writes "3d ago",
                        // which is what `compact` writes here; Android's
                        // `abbreviated` is the longer macOS phrasing.
                        RelativeTimeText(
                            epochMillis = it,
                            style = TsType.footnote,
                            color = colors.textSecondary,
                            compact = true,
                        )
                    }
                }
            }
        }
        Row(
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(Space.s),
        ) {
            Text(
                if (draft) L10n.text("android.pulldetail.draft.ebf12ef4") else state.replaceFirstChar(Char::uppercase),
                style = TsType.caption.copy(fontWeight = FontWeight.SemiBold),
                color = when {
                    state == "closed" -> colors.danger
                    state == "merged" -> colors.secondary
                    else -> colors.accent
                },
                maxLines = 1,
            )
            // The branches take whatever the counts leave, and truncate
            // rather than wrap: the row is the shape.
            Row(
                Modifier.weight(1f),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(Space.s),
            ) {
                PullBranchChip(view.str("headRef").orEmpty(), Modifier.weight(1f, fill = false))
                Icon(
                    Icons.AutoMirrored.Filled.ArrowForward,
                    contentDescription = L10n.text("android.pulldetail.into.6b847a0e"),
                    tint = colors.textTertiary,
                    modifier = Modifier.size(12.dp),
                )
                PullBranchChip(view.str("baseRef").orEmpty(), Modifier.weight(1f, fill = false))
            }
            view.long("additions")?.let {
                Text("+$it", style = TsType.numeric(12, FontWeight.SemiBold), color = colors.diffAdded, maxLines = 1)
            }
            view.long("deletions")?.let {
                Text("−$it", style = TsType.numeric(12, FontWeight.SemiBold), color = colors.diffRemoved, maxLines = 1)
            }
            view.long("changedFiles")?.let {
                Text(
                    L10n.text("android.pulldetail.0_files.fb42ce4d", "${it}"),
                    style = TsType.caption.copy(fontWeight = FontWeight.SemiBold),
                    color = colors.textSecondary,
                    maxLines = 1,
                )
            }
        }
    }
}

/// The tile the hero leads with: a branch, a merge or a draft pencil, in the
/// colour the state is written in.
@Composable
private fun PullStateMark(state: String, draft: Boolean) {
    val colors = LocalTsColors.current
    val tint = when {
        draft -> colors.stateIdle
        state == "closed" -> colors.danger
        state == "merged" -> colors.secondary
        else -> colors.accent
    }
    Box(
        Modifier
            .size(38.dp)
            .clip(RoundedCornerShape(11.dp))
            .background(tint.copy(alpha = 0.11f)),
        contentAlignment = Alignment.Center,
    ) {
        Icon(
            when {
                draft -> Icons.Default.Edit
                state == "merged" -> Icons.Default.Merge
                else -> Icons.AutoMirrored.Filled.CallSplit
            },
            contentDescription = null,
            tint = tint,
            modifier = Modifier.size(18.dp),
        )
    }
}

/// A branch name, in the face branch names are read in, on an accent-tinted
/// capsule. Truncates rather than wrapping: the row is the shape.
@Composable
private fun PullBranchChip(value: String, modifier: Modifier = Modifier) {
    val colors = LocalTsColors.current
    Text(
        value,
        style = TsType.mono(11, FontWeight.Medium),
        color = colors.textPrimary,
        maxLines = 1,
        overflow = TextOverflow.Ellipsis,
        modifier = modifier
            .clip(CircleShape)
            .background(colors.accent.copy(alpha = 0.08f))
            .border(1.dp, colors.accent.copy(alpha = 0.16f), CircleShape)
            .padding(horizontal = 9.dp, vertical = 5.dp),
    )
}

/// Conversation, Changes and Checks, the checks carrying their count. Port of
/// `DetailTabs`: pills in a bordered strip, the selected one on the accent's
/// soft tint.
@Composable
private fun PullDetailTabs(selection: PullTab, checks: Int, onSelect: (PullTab) -> Unit) {
    val colors = LocalTsColors.current
    val shape = RoundedCornerShape(12.dp)
    Box(
        Modifier
            .fillMaxWidth()
            .clip(shape)
            .background(colors.panel)
            .border(1.dp, colors.border, shape)
            .padding(3.dp),
    ) {
        Row(
            Modifier.horizontalScroll(rememberScrollState()),
            horizontalArrangement = Arrangement.spacedBy(3.dp),
        ) {
            PullTab.entries.forEach { tab ->
                val active = tab == selection
                Row(
                    Modifier
                        .clip(RoundedCornerShape(9.dp))
                        .background(if (active) colors.accentSoft else Color.Transparent)
                        .clickable(
                            indication = null,
                            interactionSource = remember { MutableInteractionSource() },
                        ) { onSelect(tab) }
                        .height(34.dp)
                        .padding(horizontal = Space.m)
                        .semantics { selected = active },
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(7.dp),
                ) {
                    Icon(
                        tab.icon,
                        contentDescription = null,
                        tint = if (active) colors.accent else colors.controlGlyph,
                        modifier = Modifier.size(15.dp),
                    )
                    Text(
                        tab.title,
                        style = TsType.caption.copy(fontWeight = if (active) FontWeight.SemiBold else FontWeight.Medium),
                        color = if (active) colors.accent else colors.controlGlyph,
                        maxLines = 1,
                    )
                    if (tab == PullTab.Checks && checks > 0) {
                        Text(
                            "$checks",
                            style = TsType.numeric(12, if (active) FontWeight.SemiBold else FontWeight.Medium),
                            color = colors.accent.copy(alpha = if (active) 1f else 0.48f),
                        )
                    }
                }
            }
        }
    }
}

/// The description, then everything that has happened since, then the box to
/// add to it.
@Composable
private fun PullConversationTab(
    view: JsonObject,
    timeline: List<JsonObject>,
    nextCursor: String?,
    loadingTimeline: Boolean,
    timelineError: String?,
    commentDraft: String,
    onCommentDraft: (String) -> Unit,
    busy: Boolean,
    onMore: () -> Unit,
    onComment: () -> Unit,
) {
    val colors = LocalTsColors.current
    val author = view["author"] as? JsonObject
    Column(verticalArrangement = Arrangement.spacedBy(Space.m)) {
        PullConversationCard(
            login = author?.str("login") ?: view.str("author").orEmpty(),
            avatarUrl = author?.str("avatar"),
            epochMillis = pullEpochMillis(view.str("createdAt")),
        ) {
            val body = view.str("body").orEmpty().trim()
            if (body.isEmpty()) {
                Text(L10n.text("android.pulldetail.no_description_was_added.68442d50"), style = TsType.footnote, color = colors.textTertiary)
            } else {
                MarkdownText(pullBodyMarkdown(body), TsType.chatBody, colors.textPrimary)
            }
        }
        timeline.forEach { event -> PullTimelineEntry(event) }
        if (loadingTimeline) {
            Text(L10n.text("android.pulldetail.loading_activity.a389c395"), style = TsType.footnote, color = colors.textSecondary)
        }
        timelineError?.let { PullInlineError(it) }
        if (nextCursor != null) {
            TsSecondaryButton(
                label = L10n.text("android.pulldetail.earlier_activity.2e9839ac"),
                icon = ActionIcon.More.vector,
                small = true,
                onClick = onMore,
                modifier = Modifier.fillMaxWidth(),
            )
        }
        PullCommentComposer(commentDraft, onCommentDraft, busy, onComment)
    }
}

/// One thing somebody wrote: who, when, a rule, then the words.
@Composable
private fun PullConversationCard(
    login: String,
    avatarUrl: String?,
    epochMillis: Long?,
    content: @Composable ColumnScope.() -> Unit,
) {
    val colors = LocalTsColors.current
    val shape = RoundedCornerShape(cardRadiusDp)
    Column(
        Modifier
            .fillMaxWidth()
            .clip(shape)
            .background(colors.panel)
            .border(1.dp, colors.border, shape)
            .padding(cardPaddingDp),
        verticalArrangement = Arrangement.spacedBy(Space.m),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(Space.s)) {
            Avatar(
                name = login,
                size = 24,
                avatarUrl = avatarUrl,
                tint = avatarTint(login, colors),
                decorative = true,
            )
            Text(
                login,
                style = TsType.footnote.copy(fontWeight = FontWeight.SemiBold),
                color = colors.textPrimary,
            )
            Spacer(Modifier.weight(1f))
            if (epochMillis != null) {
                RelativeTimeText(
                    epochMillis = epochMillis,
                    style = TsType.caption,
                    color = colors.textTertiary,
                    compact = true,
                )
            }
        }
        HorizontalDivider(thickness = 1.dp, color = colors.border)
        content()
    }
}

/// A comment or a review is a card; everything else on the timeline is one
/// line with a glyph, the way the Apple timeline draws it.
@Composable
private fun PullTimelineEntry(event: JsonObject) {
    val colors = LocalTsColors.current
    val kind = event.str("kind").orEmpty()
    val actor = event["actor"] as? JsonObject
    val login = actor?.str("login") ?: event.str("actor").orEmpty()
    val millis = pullEpochMillis(event.str("createdAt"))
    if (kind == "commented" || kind == "reviewed") {
        PullConversationCard(login = login, avatarUrl = actor?.str("avatar"), epochMillis = millis) {
            if (kind == "reviewed") {
                event.str("state")?.takeIf { it.isNotBlank() }?.let { state ->
                    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(Space.xs)) {
                        Icon(
                            if (state == "approved") ActionIcon.Approve.vector else Icons.Default.Visibility,
                            contentDescription = null,
                            tint = if (state == "approved") colors.success else colors.warning,
                            modifier = Modifier.size(14.dp),
                        )
                        Text(
                            state.replace('_', ' ').replaceFirstChar(Char::uppercase),
                            style = TsType.caption.copy(fontWeight = FontWeight.SemiBold),
                            color = if (state == "approved") colors.success else colors.warning,
                        )
                    }
                }
            }
            event.str("body")?.takeIf { it.isNotBlank() }?.let {
                MarkdownText(pullBodyMarkdown(it), TsType.chatBody, colors.textPrimary)
            }
        }
    } else {
        Row(
            Modifier.padding(horizontal = Space.s),
            horizontalArrangement = Arrangement.spacedBy(Space.m),
        ) {
            Box(
                Modifier
                    .size(28.dp)
                    .clip(CircleShape)
                    .background(colors.accentSoft),
                contentAlignment = Alignment.Center,
            ) {
                val named = kind in setOf("committed", "merged", "closed", "labeled", "unlabeled")
                Icon(
                    timelineIcon(kind),
                    contentDescription = null,
                    tint = colors.accent,
                    // The fallback is a dot, not a glyph, so it is drawn at
                    // dot size rather than shrunk to fit.
                    modifier = Modifier.size(if (named) 13.dp else 7.dp),
                )
            }
            Column(verticalArrangement = Arrangement.spacedBy(3.dp)) {
                Text(
                    timelineSentence(kind, login, event.str("subject")),
                    style = TsType.footnote,
                    color = colors.textPrimary,
                )
                if (millis != null) {
                    RelativeTimeText(
                        epochMillis = millis,
                        style = TsType.caption2,
                        color = colors.textTertiary,
                        compact = true,
                    )
                }
            }
        }
    }
}

/// Markdown in, a comment out. The gradient says this is the one card on the
/// page that writes rather than reads.
@Composable
private fun PullCommentComposer(
    text: String,
    onText: (String) -> Unit,
    busy: Boolean,
    onSend: () -> Unit,
) {
    val colors = LocalTsColors.current
    val shape = RoundedCornerShape(cardRadiusDp)
    Column(
        Modifier
            .fillMaxWidth()
            .clip(shape)
            .background(Brush.linearGradient(listOf(colors.accentSoft.copy(alpha = 0.72f), colors.panel)))
            .border(1.dp, colors.accent.copy(alpha = 0.18f), shape)
            .padding(cardPaddingDp),
        verticalArrangement = Arrangement.spacedBy(Space.m),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(Space.s)) {
            Icon(
                ActionIcon.Comment.vector,
                contentDescription = null,
                tint = colors.accent,
                modifier = Modifier.size(16.dp),
            )
            Text(
                L10n.text("android.pulldetail.join_the_conversation.a0a9b316"),
                style = TsType.footnote.copy(fontWeight = FontWeight.SemiBold),
                color = colors.textPrimary,
            )
        }
        OutlinedTextField(
            text,
            onText,
            modifier = Modifier.fillMaxWidth(),
            placeholder = { Text(L10n.text("android.pulldetail.write_a_comment.d21c3e2f")) },
            minLines = 3,
        )
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(
                L10n.text("android.pulldetail.markdown_is_supported.c08eb344"),
                style = TsType.caption2,
                color = colors.textTertiary,
                modifier = Modifier.weight(1f),
            )
            TsAccentButton(
                label = L10n.text("android.pulldetail.comment.44f5e3fb"),
                icon = ActionIcon.Comment.vector,
                small = true,
                enabled = text.trim().isNotEmpty() && !busy,
                onClick = onSend,
            )
        }
    }
}

/// The diff: one chip per file, then the file that is selected. Nothing is
/// fetched until this tab is opened, so its empty and loading states are its
/// own rather than the page's.
@Composable
private fun PullChangesTab(
    diffs: List<JsonObject>,
    selectedPath: String?,
    onSelectPath: (String) -> Unit,
    loading: Boolean,
    error: String?,
) {
    val colors = LocalTsColors.current
    Column(verticalArrangement = Arrangement.spacedBy(Space.m)) {
        when {
            loading -> PullContentSkeleton()
            error != null -> PullInlineError(error)
            diffs.isEmpty() -> EmptyState(
                Icons.Default.Description,
                L10n.text("android.pulldetail.no_text_changes.08722a9e"),
                L10n.text("android.pulldetail.this_pull_request_has_no_line_by_line_diff.680bf131"),
            )
            else -> {
                Row(
                    Modifier.horizontalScroll(rememberScrollState()),
                    horizontalArrangement = Arrangement.spacedBy(Space.xs),
                ) {
                    diffs.forEach { diff ->
                        val path = diff.str("path").orEmpty()
                        val active = path == selectedPath
                        Row(
                            Modifier
                                .clip(CircleShape)
                                .background(if (active) colors.accentSoft else colors.panel)
                                .border(
                                    1.dp,
                                    if (active) colors.accent.copy(alpha = 0.3f) else colors.border,
                                    CircleShape,
                                )
                                .clickable { onSelectPath(path) }
                                .padding(horizontal = 10.dp, vertical = 7.dp),
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.spacedBy(6.dp),
                        ) {
                            Icon(
                                Icons.Default.Description,
                                contentDescription = null,
                                tint = if (active) colors.accent else colors.textSecondary,
                                modifier = Modifier.size(13.dp),
                            )
                            Text(
                                path.substringAfterLast('/').ifBlank { path },
                                style = TsType.caption.copy(fontWeight = if (active) FontWeight.SemiBold else FontWeight.Medium),
                                color = if (active) colors.accent else colors.textSecondary,
                                maxLines = 1,
                            )
                        }
                    }
                }
                val diff = diffs.firstOrNull { it.str("path") == selectedPath } ?: diffs.first()
                val shape = RoundedCornerShape(cardRadiusDp)
                Column(
                    Modifier
                        .fillMaxWidth()
                        .clip(shape)
                        .background(colors.panel)
                        .border(1.dp, colors.border, shape),
                ) {
                    Text(
                        diff.str("path").orEmpty(),
                        style = TsType.mono(11, FontWeight.Medium),
                        color = colors.textPrimary,
                        modifier = Modifier
                            .fillMaxWidth()
                            .background(colors.accent.copy(alpha = 0.055f))
                            .padding(Space.m),
                    )
                    HunkDiffView(diff)
                }
            }
        }
    }
}

/// What the head commit reports: the headline first, then every run.
@Composable
private fun PullChecksTab(view: JsonObject) {
    val colors = LocalTsColors.current
    val checks = asObjects(view["checks"])
    val states = checks.map { it.str("state").orEmpty() }
    val passed = states.count { it == "passing" }
    val tint = when {
        states.contains("failing") -> colors.danger
        states.contains("pending") -> colors.warning
        else -> colors.success
    }
    val shape = RoundedCornerShape(cardRadiusDp)
    Column(verticalArrangement = Arrangement.spacedBy(Space.m)) {
        Row(
            Modifier
                .fillMaxWidth()
                .clip(shape)
                .background(colors.panel)
                .border(1.dp, colors.border, shape)
                .padding(cardPaddingDp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(Space.m),
        ) {
            Box(
                Modifier
                    .size(46.dp)
                    .clip(CircleShape)
                    .background(tint.copy(alpha = 0.11f)),
                contentAlignment = Alignment.Center,
            ) {
                Icon(
                    checksIcon(states),
                    contentDescription = null,
                    tint = tint,
                    modifier = Modifier.size(20.dp),
                )
            }
            Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
                Text(
                    checksHeadline(passed, checks.size),
                    style = TsType.subheadline.copy(fontWeight = FontWeight.SemiBold),
                    color = colors.textPrimary,
                )
                Text(checksMessage(states), style = TsType.caption, color = colors.textSecondary)
            }
        }
        checks.forEach { check -> PullCheckRow(check) }
    }
}

/// One check run: the mark, what ran, how long it took, and where to read it.
@Composable
private fun PullCheckRow(check: JsonObject) {
    val colors = LocalTsColors.current
    val context = LocalContext.current
    val state = check.str("state").orEmpty()
    val tint = when (state) {
        "passing" -> colors.success
        "failing" -> colors.danger
        else -> colors.warning
    }
    val shape = RoundedCornerShape(cardRadiusDp)
    Row(
        Modifier
            .fillMaxWidth()
            .clip(shape)
            .background(colors.panel)
            .border(1.dp, colors.border, shape)
            .padding(Space.m),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(Space.m),
    ) {
        Box(
            Modifier
                .size(30.dp)
                .clip(CircleShape)
                .background(tint.copy(alpha = 0.10f)),
            contentAlignment = Alignment.Center,
        ) {
            Icon(
                when (state) {
                    "passing" -> Icons.Default.Check
                    "failing" -> Icons.Default.Close
                    else -> Icons.Default.MoreHoriz
                },
                contentDescription = null,
                tint = tint,
                modifier = Modifier.size(14.dp),
            )
        }
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text(
                check.str("name") ?: L10n.text("android.pulldetail.check.9d60841e"),
                style = TsType.footnote.copy(fontWeight = FontWeight.Medium),
                color = colors.textPrimary,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            val workflow = check.str("workflow")?.takeIf { it.isNotBlank() }
            val duration = checkDurationText(check.str("startedAt"), check.str("completedAt"))
            val line = listOfNotNull(workflow, duration).joinToString(" · ")
            if (line.isNotEmpty()) {
                Text(line, style = TsType.caption, color = colors.textSecondary, maxLines = 1, overflow = TextOverflow.Ellipsis)
            }
        }
        Text(
            state.replaceFirstChar(Char::uppercase),
            style = TsType.caption.copy(fontWeight = FontWeight.SemiBold),
            color = tint,
            maxLines = 1,
        )
        check.str("url")?.takeIf { it.isNotBlank() }?.let { url ->
            Icon(
                ActionIcon.External.vector,
                contentDescription = L10n.text("android.pulldetail.open_check.130779b8"),
                tint = colors.accent,
                modifier = Modifier
                    .size(18.dp)
                    .clickable { runCatching { CustomTabsIntent.Builder().build().launchUrl(context, url.toUri()) } },
            )
        }
    }
}

/// Who is reviewing, who it is assigned to, what it is labelled, and whether
/// it can merge. Port of `PullInspector`; on a phone it reads under the
/// conversation rather than beside it.
@Composable
private fun PullInspectorCard(view: JsonObject) {
    val colors = LocalTsColors.current
    val shape = RoundedCornerShape(cardRadiusDp)
    val state = view.str("state").orEmpty()
    val decision = view.str("reviewDecision").orEmpty()
    val labels = (view["labels"] as? JsonArray)?.mapNotNull { (it as? JsonPrimitive)?.contentOrNull }.orEmpty()
    val assignees = asObjects(view["assignees"])
    val requests = asObjects(view["reviewRequests"])
    val reviews = asObjects(view["reviews"])
    Column(
        Modifier
            .fillMaxWidth()
            .clip(shape)
            .background(colors.panel)
            .border(1.dp, colors.border, shape)
            .padding(cardPaddingDp),
        verticalArrangement = Arrangement.spacedBy(Space.l),
    ) {
        PullInspectorSection(L10n.text("android.pulldetail.review.182e4992"), Icons.Default.Visibility) {
            val text = when {
                state != "open" -> state.replaceFirstChar(Char::uppercase)
                decision == "approved" -> L10n.text("android.pulldetail.approved.87b42e40")
                decision == "changes_requested" -> L10n.text("android.pulldetail.changes_requested.10a92a8a")
                view.bol("draft") -> L10n.text("android.pulldetail.draft.ebf12ef4")
                else -> L10n.text("android.pulldetail.review_pending.9834120e")
            }
            val tint = when (decision) {
                "approved" -> colors.success
                "changes_requested" -> colors.danger
                else -> colors.warning
            }
            PullInspectorValue(text, tint)
            reviews.forEach { review ->
                PullActorRow(
                    review["author"] as? JsonObject,
                    review.str("state")?.replace('_', ' ')?.replaceFirstChar(Char::uppercase),
                )
            }
            requests.forEach { PullActorRow(it, L10n.text("android.pulldetail.requested.2d9e2828")) }
        }
        if (assignees.isNotEmpty()) {
            PullInspectorSection(L10n.text("android.pulldetail.assignees.6549675b"), Icons.Default.People) {
                assignees.forEach { PullActorRow(it, null) }
            }
        }
        if (labels.isNotEmpty()) {
            PullInspectorSection(L10n.text("android.pulldetail.labels.47399b60"), Icons.AutoMirrored.Filled.Label) {
                labels.forEach { label ->
                    Text(
                        label,
                        style = TsType.caption2.copy(fontWeight = FontWeight.Medium),
                        color = colors.secondary,
                        modifier = Modifier
                            .clip(CircleShape)
                            .background(colors.secondary.copy(alpha = 0.10f))
                            .padding(horizontal = 8.dp, vertical = 4.dp),
                    )
                }
            }
        }
        if (state == "open") {
            PullInspectorSection(L10n.text("android.pulldetail.merge.fc2b737d"), Icons.Default.Merge) {
                val mergeable = view.str("mergeable") == "mergeable"
                PullInspectorValue(
                    if (mergeable) {
                        L10n.text("android.pulldetail.ready_to_merge.28f7384e")
                    } else {
                        view.str("mergeState").orEmpty().replace('_', ' ').replaceFirstChar(Char::uppercase)
                    },
                    if (mergeable) colors.success else colors.warning,
                )
            }
        }
    }
}

@Composable
private fun PullInspectorSection(title: String, icon: ImageVector, content: @Composable ColumnScope.() -> Unit) {
    val colors = LocalTsColors.current
    Column(Modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(Space.s)) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(Space.xs)) {
            Icon(icon, contentDescription = null, tint = colors.textTertiary, modifier = Modifier.size(12.dp))
            Text(title, style = TsType.caption2.copy(fontWeight = FontWeight.SemiBold), color = colors.textTertiary)
        }
        content()
    }
}

@Composable
private fun PullInspectorValue(text: String, tint: Color) {
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(Space.xs)) {
        Icon(Icons.Default.Circle, contentDescription = null, tint = tint, modifier = Modifier.size(8.dp))
        Text(text, style = TsType.caption.copy(fontWeight = FontWeight.Medium), color = tint)
    }
}

@Composable
private fun PullActorRow(actor: JsonObject?, note: String?) {
    val colors = LocalTsColors.current
    val login = actor?.str("login").orEmpty()
    if (login.isBlank()) return
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(Space.s)) {
        Avatar(name = login, size = 22, avatarUrl = actor?.str("avatar"), tint = avatarTint(login, colors), decorative = true)
        Column(verticalArrangement = Arrangement.spacedBy(1.dp)) {
            Text(login, style = TsType.caption.copy(fontWeight = FontWeight.Medium), color = colors.textPrimary)
            if (note != null) {
                Text(note, style = TsType.caption2, color = colors.textTertiary)
            }
        }
    }
}

/// Everything this pull request can be done to, each one a labelled press.
@Composable
private fun PullActionsPanel(
    view: JsonObject,
    busy: Boolean,
    reviewMode: String?,
    reviewDraft: String,
    onReviewDraft: (String) -> Unit,
    onBeginReview: (String) -> Unit,
    onCancelReview: () -> Unit,
    onApprove: () -> Unit,
    onSendReview: (String) -> Unit,
    onReady: () -> Unit,
    onClose: () -> Unit,
    onReopen: () -> Unit,
    mergeMethod: String,
    onMergeMethod: (String) -> Unit,
    onMerge: () -> Unit,
    checkoutBranch: String,
    onCheckoutBranch: (String) -> Unit,
    onCheckout: () -> Unit,
) {
    val colors = LocalTsColors.current
    val shape = RoundedCornerShape(cardRadiusDp)
    val state = view.str("state").orEmpty()
    Column(
        Modifier
            .fillMaxWidth()
            .clip(shape)
            .background(colors.panel)
            .border(1.dp, colors.border, shape)
            .padding(cardPaddingDp),
        verticalArrangement = Arrangement.spacedBy(Space.m),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(Space.xs)) {
            Icon(
                Icons.Default.AutoAwesome,
                contentDescription = null,
                tint = colors.textTertiary,
                modifier = Modifier.size(12.dp),
            )
            Text(L10n.text("android.pulldetail.actions.1ba13aa6"), style = TsType.caption2.copy(fontWeight = FontWeight.SemiBold), color = colors.textTertiary)
        }
        if (state == "open") {
            Column(verticalArrangement = Arrangement.spacedBy(Space.s)) {
                Text(L10n.text("android.pulldetail.review.aff0766a"), style = TsType.caption.copy(fontWeight = FontWeight.SemiBold), color = colors.textPrimary)
                TsSecondaryButton(label = L10n.text("android.pulldetail.approve.6007acbe"), icon = ActionIcon.Approve.vector, small = true, enabled = !busy, onClick = onApprove)
                TsSecondaryButton(label = L10n.text("android.pulldetail.request_changes.cb5d9f98"), icon = ActionIcon.Edit.vector, small = true, enabled = !busy, onClick = { onBeginReview("requestChanges") })
                TsSecondaryButton(label = L10n.text("android.pulldetail.comment_review.f8950d66"), icon = ActionIcon.Comment.vector, small = true, enabled = !busy, onClick = { onBeginReview("comment") })
                val mode = reviewMode
                if (mode != null) {
                    Column(
                        Modifier
                            .clip(RoundedCornerShape(10.dp))
                            .background(colors.accentSoft.copy(alpha = 0.58f))
                            .padding(Space.s),
                        verticalArrangement = Arrangement.spacedBy(Space.s),
                    ) {
                        OutlinedTextField(
                            reviewDraft,
                            onReviewDraft,
                            modifier = Modifier.fillMaxWidth(),
                            placeholder = { Text(PullReview.reviewPlaceholder(mode)) },
                            minLines = 3,
                        )
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            TsSecondaryButton(label = L10n.text("common.cancel"), icon = ActionIcon.Dismiss.vector, small = true, onClick = onCancelReview)
                            Spacer(Modifier.weight(1f))
                            TsAccentButton(
                                label = L10n.text("android.pulldetail.send_review.e61e3577"),
                                icon = ActionIcon.Send.vector,
                                small = true,
                                enabled = reviewDraft.trim().isNotEmpty() && !busy,
                                onClick = { onSendReview(mode) },
                            )
                        }
                    }
                }
            }
            if (view.bol("draft")) {
                TsAccentButton(label = L10n.text("android.pulldetail.ready_for_review.75c2a5c8"), icon = ActionIcon.Done.vector, small = true, enabled = !busy, onClick = onReady)
            }
            Column(verticalArrangement = Arrangement.spacedBy(Space.s)) {
                Text(L10n.text("android.pulldetail.merge_method.889b19c3"), style = TsType.caption.copy(fontWeight = FontWeight.SemiBold), color = colors.textPrimary)
                Row(horizontalArrangement = Arrangement.spacedBy(Space.s)) {
                    PullReview.MERGE_METHODS.forEach { method ->
                        if (method == mergeMethod) {
                            TsAccentButton(label = PullReview.mergeTitle(method), small = true, onClick = {})
                        } else {
                            TsSecondaryButton(label = PullReview.mergeTitle(method), small = true, onClick = { onMergeMethod(method) })
                        }
                    }
                }
                TsAccentButton(
                    label = L10n.text("android.pulldetail.merge_pull_request.4aa62232"),
                    icon = ActionIcon.Merge.vector,
                    small = true,
                    enabled = !view.bol("draft") && !busy,
                    onClick = onMerge,
                )
            }
            TsDangerButton(label = L10n.text("android.pulldetail.close_pull_request.672e174d"), icon = ActionIcon.Dismiss.vector, small = true, enabled = !busy, onClick = onClose)
        } else if (state == "closed") {
            TsAccentButton(label = L10n.text("android.pulldetail.reopen_pull_request.6126288e"), icon = ActionIcon.Reopen.vector, small = true, enabled = !busy, onClick = onReopen)
        }
        Column(verticalArrangement = Arrangement.spacedBy(Space.s)) {
            Text(L10n.text("android.pulldetail.local_checkout.416562be"), style = TsType.caption.copy(fontWeight = FontWeight.SemiBold), color = colors.textPrimary)
            OutlinedTextField(
                checkoutBranch,
                onCheckoutBranch,
                modifier = Modifier.fillMaxWidth(),
                placeholder = { Text(L10n.text("android.pulldetail.local_branch_name.a33a6eba")) },
                singleLine = true,
                textStyle = TsType.mono(12),
            )
            TsSecondaryButton(
                label = L10n.text("android.pulldetail.check_out_locally.433de9bf"),
                icon = ActionIcon.Checkout.vector,
                small = true,
                enabled = checkoutBranch.trim().isNotEmpty() && !busy,
                onClick = onCheckout,
            )
        }
    }
}

/// A round seat with one glyph in it, the port of `ToolbarIconButton`. The
/// glyph gives way to a spinner while the request it started is in flight.
@Composable
private fun PullToolbarIconButton(
    icon: ImageVector,
    description: String,
    busy: Boolean,
    onClick: () -> Unit,
) {
    val colors = LocalTsColors.current
    Box(
        Modifier
            .size(36.dp)
            .clip(CircleShape)
            .background(colors.controlSeat)
            .border(1.dp, colors.border.copy(alpha = 0.55f), CircleShape)
            .clickable(enabled = !busy, onClick = onClick),
        contentAlignment = Alignment.Center,
    ) {
        if (busy) {
            CircularProgressIndicator(
                Modifier.size(16.dp),
                strokeWidth = 2.dp,
                color = colors.accent,
            )
        } else {
            Icon(
                icon,
                contentDescription = description,
                tint = colors.controlGlyph,
                modifier = Modifier.size(16.dp),
            )
        }
    }
}

/// A success or a refusal, above the content it belongs to, with a way to put
/// it away. Port of `actionBanner`.
@Composable
private fun PullNotice(message: String, tint: Color, icon: ImageVector, onDismiss: () -> Unit) {
    val shape = RoundedCornerShape(cardRadiusDp)
    Row(
        Modifier
            .fillMaxWidth()
            .clip(shape)
            .background(tint.copy(alpha = 0.09f))
            .border(1.dp, tint.copy(alpha = 0.16f), shape)
            .padding(horizontal = Space.m, vertical = Space.s),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(Space.s),
    ) {
        Icon(icon, contentDescription = null, tint = tint, modifier = Modifier.size(16.dp))
        Text(
            message,
            style = TsType.footnote.copy(fontWeight = FontWeight.Medium),
            color = tint,
            modifier = Modifier.weight(1f),
        )
        Icon(
            ActionIcon.Dismiss.vector,
            contentDescription = L10n.text("android.pulldetail.dismiss.48845bff"),
            tint = tint,
            modifier = Modifier
                .size(16.dp)
                .clickable(onClick = onDismiss),
        )
    }
}

@Composable
private fun PullInlineError(message: String) {
    val colors = LocalTsColors.current
    Row(
        Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(cardRadiusDp))
            .background(colors.warning.copy(alpha = 0.09f))
            .padding(Space.m),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(Space.s),
    ) {
        Icon(
            Icons.Outlined.WarningAmber,
            contentDescription = null,
            tint = colors.warning,
            modifier = Modifier.size(16.dp),
        )
        Text(message, style = TsType.footnote, color = colors.warning)
    }
}

/// The cold page, shaped like the page that replaces it: the title is already
/// known from the row that was tapped, so only what has to be fetched is a
/// bar.
@Composable
private fun PullDetailSkeleton(summary: JsonObject?, number: Long) {
    val colors = LocalTsColors.current
    val shape = RoundedCornerShape(cardRadiusDp)
    Column(verticalArrangement = Arrangement.spacedBy(Space.l)) {
        Column(
            Modifier
                .fillMaxWidth()
                .clip(shape)
                .background(colors.panel)
                .border(1.dp, colors.border, shape)
                .padding(cardPaddingDp),
            verticalArrangement = Arrangement.spacedBy(Space.m),
        ) {
            Row(horizontalArrangement = Arrangement.spacedBy(Space.m)) {
                Box(Modifier.size(38.dp).clip(RoundedCornerShape(11.dp)).background(colors.border))
                Column(verticalArrangement = Arrangement.spacedBy(Space.s)) {
                    Text(
                        summary?.str("title").orEmpty(),
                        style = TsType.title3.copy(fontWeight = FontWeight.SemiBold),
                        color = colors.textPrimary,
                    )
                    Text(
                        "#$number · ${summary?.str("author").orEmpty()}",
                        style = TsType.footnote,
                        color = colors.textSecondary,
                    )
                    Text(L10n.text("android.pulldetail.loading_conversation.5eb1e4a3"), style = TsType.caption, color = colors.textSecondary)
                }
            }
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(Space.s)) {
                Box(Modifier.width(126.dp)) { SkeletonBar(height = 22.dp) }
                Box(Modifier.width(18.dp)) { SkeletonBar(height = 9.dp) }
                Box(Modifier.width(96.dp)) { SkeletonBar(height = 22.dp) }
            }
        }
        Row(
            Modifier
                .fillMaxWidth()
                .clip(RoundedCornerShape(12.dp))
                .background(colors.panel)
                .border(1.dp, colors.border, RoundedCornerShape(12.dp))
                .padding(3.dp),
            horizontalArrangement = Arrangement.spacedBy(Space.s),
        ) {
            Box(Modifier.width(92.dp)) { SkeletonBar(height = 28.dp) }
            Box(Modifier.width(72.dp)) { SkeletonBar(height = 28.dp) }
            Box(Modifier.width(68.dp)) { SkeletonBar(height = 28.dp) }
        }
        PullContentSkeleton()
    }
}

@Composable
private fun PullContentSkeleton() {
    val colors = LocalTsColors.current
    val shape = RoundedCornerShape(cardRadiusDp)
    Column(
        Modifier
            .fillMaxWidth()
            .clip(shape)
            .background(colors.panel)
            .border(1.dp, colors.border, shape)
            .padding(cardPaddingDp),
        verticalArrangement = Arrangement.spacedBy(Space.m),
    ) {
        Box(Modifier.fillMaxWidth(0.5f)) { SkeletonBar(height = 18.dp) }
        Box(Modifier.fillMaxWidth(0.34f)) { SkeletonBar() }
        listOf(1f, 1f, 1f, 0.4f).forEachIndexed { index, fraction ->
            Box(Modifier.fillMaxWidth(fraction)) { SkeletonBar(phaseMillis = index * 80) }
        }
    }
}

/// GitHub stamps every date as ISO 8601 in UTC. Null rather than a number
/// when one is missing or malformed: a row without a date should say nothing
/// rather than say 1970.
internal fun pullEpochMillis(iso: String?): Long? {
    val text = iso?.trim()?.takeIf { it.isNotEmpty() } ?: return null
    return runCatching { java.time.Instant.parse(text).toEpochMilli() }.getOrNull()
}

/// How long a check run took, word for word with `PullCheck.durationText`.
internal fun checkDurationText(startedAt: String?, completedAt: String?): String? {
    val started = pullEpochMillis(startedAt) ?: return null
    val completed = pullEpochMillis(completedAt) ?: return null
    val seconds = ((completed - started).coerceAtLeast(0) + 500) / 1000
    if (seconds < 60) return "${seconds}s"
    val minutes = seconds / 60
    if (minutes < 60) return "${minutes}m ${seconds % 60}s"
    return "${minutes / 60}h ${minutes % 60}m"
}

/// "dependabot opened the pull request", from the event kinds the host
/// decoder keeps. Unknown kinds get the neutral sentence rather than the raw
/// word, which is what the Apple timeline does.
internal fun timelineSentence(kind: String, actor: String, subject: String?): String {
    val verb = when (kind) {
        "committed" -> L10n.text("android.pulldetail.committed.cc962289")
        "labeled" -> L10n.text("android.pulldetail.added_a_label.d94d0d1f")
        "unlabeled" -> L10n.text("android.pulldetail.removed_a_label.9b424566")
        "assigned" -> L10n.text("android.pulldetail.assigned.2ebb9294")
        "unassigned" -> L10n.text("android.pulldetail.unassigned.2f23e841")
        "reviewRequested" -> L10n.text("android.pulldetail.requested_a_review.366ef14e")
        "forcePushed" -> L10n.text("android.pulldetail.force_pushed.13045511")
        "renamed" -> L10n.text("android.pulldetail.renamed_the_pull_request.03cbfb8e")
        "readyForReview" -> L10n.text("android.pulldetail.marked_this_ready_for_review.9851474a")
        "closed" -> L10n.text("android.pulldetail.closed_the_pull_request.0ee2b89d")
        "reopened" -> L10n.text("android.pulldetail.reopened_the_pull_request.7a38a97b")
        "merged" -> L10n.text("android.pulldetail.merged_the_pull_request.e32d2898")
        else -> L10n.text("android.pulldetail.updated_the_pull_request.b58c4a83")
    }
    val suffix = subject?.takeIf { it.isNotBlank() }?.let { " · $it" }.orEmpty()
    return "$actor $verb$suffix"
}

/// "3 of 31 checks passed", or the sentence for a head commit that publishes
/// no check suite at all.
internal fun checksHeadline(passed: Int, total: Int): String =
    if (total == 0) L10n.text("android.pulldetail.no_checks_reported.8454518f") else L10n.text("android.pulldetail.0_of_1_checks_passed.17ecc810", "${passed}", "${total}")

internal fun checksMessage(states: List<String>): String = when {
    states.isEmpty() -> L10n.text("android.pulldetail.the_head_commit_does_not_publish_a_check_s.3a467ede")
    states.contains("failing") -> L10n.text("android.pulldetail.something_needs_attention_before_this_is_r.1400a527")
    states.contains("pending") -> L10n.text("android.pulldetail.the_remaining_work_is_still_running.1c81cb2a")
    else -> L10n.text("android.pulldetail.everything_reported_by_the_head_commit_is.6083342c")
}

private fun checksIcon(states: List<String>): ImageVector = when {
    states.contains("failing") -> Icons.Default.Close
    states.contains("pending") -> Icons.Default.MoreHoriz
    else -> Icons.Default.Check
}

private fun timelineIcon(kind: String): ImageVector = when (kind) {
    "committed" -> Icons.Default.Commit
    "merged" -> Icons.Default.Merge
    "closed" -> Icons.Default.Close
    "labeled", "unlabeled" -> Icons.AutoMirrored.Filled.Label
    else -> Icons.Default.Circle
}

/// Pull bodies are markdown with raw HTML mixed in: a Dependabot release note
/// is mostly `<details>`, `<h3>`, `<li>` and `<a>`. Stripping the tags loses
/// the structure, so turn the block HTML into the markdown it stands for and
/// let the renderer read it as prose. Port of `convertHTMLBlocks`.
internal fun pullBodyMarkdown(body: String): String {
    var text = body.replace(Regex("<!--.*?-->", RegexOption.DOT_MATCHES_ALL), "")
    text = anchorRegex.replace(text) { match ->
        val href = match.groupValues[1].trim()
        val label = match.groupValues[2].replace(tagRegex, "").trim().replace(Regex("\\s+"), " ")
        when {
            label.isEmpty() -> href
            // Only a real web address becomes a link. Anything else keeps its
            // words and loses its destination, which is the safe way round.
            !href.startsWith("http://", true) && !href.startsWith("https://", true) -> label
            label.contains('[') || label.contains(']') -> "$label ($href)"
            else -> "[$label]($href)"
        }
    }
    text = text
        .replace(Regex("(?i)<br\\s*/?>"), "\n")
        .replace(Regex("(?i)</?(?:em|i)>"), "*")
        .replace(Regex("(?i)</?(?:strong|b)>"), "**")
        .replace(Regex("(?i)</?code>"), "`")
        .replace(Regex("(?i)<summary[^>]*>"), "\n\n### ")
        .replace(Regex("(?i)</summary\\s*>"), "\n\n")
        .replace(Regex("(?i)<h([1-6])[^>]*>")) { "\n\n" + "#".repeat(it.groupValues[1].toInt()) + " " }
        .replace(Regex("(?i)</h[1-6]\\s*>"), "\n\n")
        .replace(Regex("(?i)<li[^>]*>"), "\n- ")
        .replace(Regex("(?i)</li\\s*>"), "\n")
        .replace(Regex("(?i)</?p[^>]*>"), "\n\n")
        .replace(Regex("(?i)</?(?:ul|ol|dl)[^>]*>"), "\n")
        .replace(tagRegex, "")
        .replace("&nbsp;", " ")
        .replace("&amp;", "&")
        .replace("&lt;", "<")
        .replace("&gt;", ">")
        .replace("&quot;", "\"")
        .replace("&#39;", "'")
    // Source indentation beside a tag is not content. One blank line between
    // blocks: compact on screen, still enough for the parser to end one block
    // before the next begins.
    return text
        .lines()
        .joinToString("\n") { it.trim() }
        .replace(Regex("\n{3,}"), "\n\n")
        // Consecutive `<li>` rows are one list, not eighty-one one-row lists
        // separated by card-sized paragraph spacing.
        .replace(Regex("\n{2,}(?=- )"), "\n")
        .trim()
}

private val anchorRegex = Regex(
    "<a\\s[^>]*href=\"([^\"]*)\"[^>]*>(.*?)</a>",
    setOf(RegexOption.IGNORE_CASE, RegexOption.DOT_MATCHES_ALL),
)

/// Only things actually shaped like a tag. `<https://example.com>` is an
/// autolink and `a < b` is prose, and neither is markup.
private val tagRegex = Regex("</?[A-Za-z][A-Za-z0-9-]*(?:\\s[^<>]*)?/?>")
