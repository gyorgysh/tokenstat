// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.team

import ai.tokenstat.tokenstat.ui.components.*
import ai.tokenstat.tokenstat.ui.localization.L10n
import ai.tokenstat.tokenstat.ui.theme.LocalTsColors
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalClipboard
import androidx.compose.ui.platform.ClipEntry
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

@Composable internal fun TeamCommentComposer(model: TeamCommentModel, onPosted: suspend () -> Unit) {
    val scope = rememberCoroutineScope()
    val clipboard = LocalClipboard.current
    val colors = LocalTsColors.current
    LaunchedEffect(model) { model.restore() }
    DisposableEffect(model) { onDispose { model.leave() } }
    Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
        OutlinedTextField(model.text, model::edit, Modifier.fillMaxWidth(), readOnly = model.pending || model.busy || model.recoveredText != null,
            enabled = model.loaded, placeholder = { Text(L10n.text("common.teams.comment_placeholder")) })
        if (model.tooLong) Text(L10n.text("common.teams.comment_too_long"), color = colors.danger)
        model.error?.let { Text(commentMessage(it), color = colors.danger) }
        model.status?.let { Text(commentMessage(it), color = colors.textSecondary) }
        model.recoveredText?.let { Text(L10n.text("common.teams.unsaved_comment_copy") + "\n" + it, color = colors.textSecondary) }
        FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
            TsSecondaryButton(L10n.text(if (model.pending) "common.teams.send_same_comment" else "common.teams.post_comment"),
                icon = ActionIcon.Comment.vector, enabled = model.canSend, onClick = { scope.launch { model.send(); if (model.status == "comment_posted") onPosted() } })
            if (model.pending) TsSecondaryButton(L10n.text("common.teams.check_delivery"), icon = ActionIcon.Refresh.vector, enabled = !model.busy,
                onClick = { scope.launch { model.check(); if (model.status == "comment_posted") onPosted() } })
            if (model.text.isNotEmpty() || model.recoveredText != null) TsSecondaryButton(L10n.text("common.teams.copy_draft"), icon = ActionIcon.Copy.vector, onClick = {
                scope.launch { clipboard.setClipEntry(ClipEntry(android.content.ClipData.newPlainText("", model.recoveredText ?: model.text))) }
            })
            if (!model.loaded || model.error != null || model.recoveredText != null) TsSecondaryButton(L10n.text("common.teams.load_saved_draft"), icon = ActionIcon.Refresh.vector, enabled = !model.busy,
                onClick = { scope.launch { model.reload() } })
        }
    }
}

@Composable internal fun TeamCommentRecoveryList(storage: TeamCommentDraftStore, origin: String?, person: String?, onBack: () -> Unit) {
    val scope = rememberCoroutineScope()
    val clipboard = LocalClipboard.current
    val colors = LocalTsColors.current
    var page by remember(origin, person) { mutableStateOf<TeamCommentDraftPage?>(null) }
    var cursor by remember(origin, person) { mutableStateOf<String?>(null) }
    var error by remember(origin, person) { mutableStateOf<String?>(null) }
    var removing by remember(origin, person) { mutableStateOf<TeamCommentRecovery?>(null) }
    suspend fun load() {
        try {
            page = withContext(Dispatchers.IO) { storage.list(origin ?: throw TeamDraftFailure("account_changed"), person ?: throw TeamDraftFailure("account_changed"), cursor) }
            error = null
        } catch (cancelled: CancellationException) { throw cancelled }
        catch (e: Exception) { error = (e as? TeamDraftFailure)?.key ?: "comment_save_failed" }
    }
    LaunchedEffect(origin, person, cursor) { load() }
    Column(Modifier.fillMaxSize().padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        TsSecondaryButton(L10n.text("common.back"), icon = ActionIcon.Back.vector, onClick = onBack)
        Text(L10n.text("common.teams.comment_drafts"), style = TsType.cardTitle, color = colors.textPrimary)
        Text(L10n.text("common.teams.comment_drafts_detail"), color = colors.textSecondary)
        error?.let { Text(commentMessage(it), color = colors.danger) }
        if (page?.unreadable == true) Text(L10n.text("common.teams.comment_drafts_unreadable"), color = colors.warning)
        if (page?.entries?.isEmpty() == true) Text(L10n.text("common.teams.no_comment_drafts"), color = colors.textSecondary)
        LazyColumn(verticalArrangement = Arrangement.spacedBy(12.dp)) {
            items(page?.entries.orEmpty(), key = { it.target.toString() }) { entry ->
                val text = entry.unsaved?.text ?: entry.draft?.text.orEmpty()
                TsCard(title = entry.unsaved?.label ?: entry.draft?.label ?: L10n.text("common.teams.saved_comment_draft")) {
                    Text(text, color = colors.textPrimary, maxLines = 8)
                    if (entry.draft?.attempt != null) Text(L10n.text("common.teams.comment_unconfirmed"), color = colors.textSecondary)
                    TsSecondaryButton(L10n.text("common.teams.copy_draft"), icon = ActionIcon.Copy.vector, onClick = {
                        scope.launch { clipboard.setClipEntry(ClipEntry(android.content.ClipData.newPlainText("", text))) }
                    })
                    TsDangerButton(L10n.text("common.teams.remove_local_draft"), icon = ActionIcon.Delete.vector, onClick = { removing = entry })
                }
            }
            page?.next?.let { next -> item {
                TsSecondaryButton(L10n.text("common.teams.load_more"), icon = ActionIcon.Next.vector, onClick = { cursor = next })
            } }
        }
    }
    removing?.let { entry -> AlertDialog(onDismissRequest = { removing = null },
        title = { Text(L10n.text("common.teams.remove_local_draft")) }, text = { Text(L10n.text("common.teams.remove_local_draft_detail")) },
        confirmButton = { TsDangerButton(L10n.text("common.teams.remove_draft"), icon = ActionIcon.Delete.vector, onClick = {
            removing = null
            scope.launch {
                try { withContext(Dispatchers.IO) { storage.discard(entry) }; load() }
                catch (e: Exception) { error = (e as? TeamDraftFailure)?.key ?: "comment_save_failed" }
            }
        }) }, dismissButton = { TsSecondaryButton(L10n.text("common.cancel"), icon = ActionIcon.Dismiss.vector, onClick = { removing = null }) }) }
}

private fun commentMessage(key: String): String = when (key) {
    "comment_draft_changed" -> L10n.text("common.teams.comment_draft_changed")
    "comment_check_first" -> L10n.text("common.teams.comment_check_first")
    "comment_save_failed" -> L10n.text("common.teams.comment_save_failed")
    "comment_too_long" -> L10n.text("common.teams.comment_too_long")
    "comment_unconfirmed" -> L10n.text("common.teams.comment_unconfirmed")
    "comment_posted" -> L10n.text("common.teams.comment_posted")
    "comment_not_accepted" -> L10n.text("common.teams.comment_not_accepted")
    "account_changed" -> L10n.text("common.teams.account_changed")
    else -> L10n.text("common.teams.comment_save_failed")
}
