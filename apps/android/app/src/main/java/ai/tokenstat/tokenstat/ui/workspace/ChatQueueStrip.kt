// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.workspace

import ai.tokenstat.tokenstat.ui.localization.L10n

import ai.tokenstat.tokenstat.ui.components.ActionIcon
import ai.tokenstat.tokenstat.ui.components.TsAccentButton
import ai.tokenstat.tokenstat.ui.components.TsDangerButton
import ai.tokenstat.tokenstat.ui.components.TsSecondaryButton
import ai.tokenstat.tokenstat.ui.components.TsType
import ai.tokenstat.tokenstat.ui.logic.ChatDelivery
import ai.tokenstat.tokenstat.ui.logic.ChatOutboxRules
import ai.tokenstat.tokenstat.ui.logic.QueuedMessage
import ai.tokenstat.tokenstat.ui.theme.LocalTsColors
import ai.tokenstat.tokenstat.ui.theme.Space
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.KeyboardArrowDown
import androidx.compose.material.icons.filled.KeyboardArrowUp
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp

/// Messages waiting for the open turn to finish, sitting above the composer.
/// Port of `ChatQueueStrip.swift`.
///
/// The host will not take a second send until this turn ends, so the next
/// prompt waits here. One waiting message stays on the strip, where it can
/// still be edited, dropped or sent now. Two or more open from View pending,
/// so the list does not cover the transcript.
@Composable
fun ChatQueueStrip(
    items: List<QueuedMessage>,
    paused: Boolean,
    offline: Boolean,
    onChange: (QueuedMessage, String) -> Unit,
    onRemove: (QueuedMessage) -> Unit,
    onSendNow: (QueuedMessage) -> Unit,
    onMove: (Int, Int) -> Unit,
) {
    if (items.isEmpty()) return
    val colors = LocalTsColors.current
    var showingQueue by remember { mutableStateOf(false) }
    // A queue that emptied while its list was open has nothing left to show.
    LaunchedEffect(items.isEmpty()) { if (items.isEmpty()) showingQueue = false }
    val shape = RoundedCornerShape(16.dp)
    Column(
        Modifier
            .fillMaxWidth()
            .clip(shape)
            .background(colors.accentSoft)
            .border(1.dp, colors.accent.copy(alpha = 0.35f), shape)
            .padding(Space.s),
        verticalArrangement = Arrangement.spacedBy(Space.s),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(
                ChatOutboxRules.title(items, paused, offline),
                style = TsType.caption.copy(fontWeight = FontWeight.Medium),
                color = colors.accent,
                maxLines = 2,
                modifier = Modifier.weight(1f),
            )
            if (items.size > 1) {
                TsSecondaryButton(
                    label = L10n.text("android.chatqueuestrip.view_pending.ed59515e"),
                    icon = ActionIcon.More.vector,
                    small = true,
                    onClick = { showingQueue = true },
                )
            }
        }
        items.firstOrNull()?.let { next ->
            ChatQueueRow(
                item = next,
                compact = true,
                offline = offline,
                onChange = { onChange(next, it) },
                onRemove = { onRemove(next) },
                onSendNow = { onSendNow(next) },
            )
        }
    }
    if (showingQueue) {
        ChatPendingSheet(
            items = items,
            offline = offline,
            onChange = onChange,
            onRemove = onRemove,
            onSendNow = onSendNow,
            onMove = onMove,
            onDismiss = { showingQueue = false },
        )
    }
}

/// The rest of the queue. Reordering is two buttons rather than a drag: the
/// Mac sheet offers exactly these as its keyboard and accessibility actions,
/// and a drag handle inside a scrolling sheet on a phone fights the scroll.
@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun ChatPendingSheet(
    items: List<QueuedMessage>,
    offline: Boolean,
    onChange: (QueuedMessage, String) -> Unit,
    onRemove: (QueuedMessage) -> Unit,
    onSendNow: (QueuedMessage) -> Unit,
    onMove: (Int, Int) -> Unit,
    onDismiss: () -> Unit,
) {
    val colors = LocalTsColors.current
    val state = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    ModalBottomSheet(
        onDismissRequest = onDismiss,
        sheetState = state,
        containerColor = colors.background,
    ) {
        Column(
            Modifier.fillMaxWidth().padding(horizontal = Space.m).padding(bottom = Space.l),
            verticalArrangement = Arrangement.spacedBy(Space.s),
        ) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(
                    L10n.text("android.chatqueuestrip.pending_messages.d71048f1"),
                    style = TsType.headline,
                    color = colors.textPrimary,
                    modifier = Modifier.weight(1f),
                )
                TextButton(onClick = onDismiss) { Text(L10n.text("common.done")) }
            }
            Text(
                L10n.text("android.chatqueuestrip.these_wait_for_this_turn_messages_marked_s.dbd6b117"),
                style = TsType.caption,
                color = colors.textSecondary,
            )
            Column(
                Modifier.heightIn(max = 420.dp).verticalScroll(rememberScrollState()),
                verticalArrangement = Arrangement.spacedBy(Space.s),
            ) {
                items.forEachIndexed { index, item ->
                    Row(
                        Modifier
                            .fillMaxWidth()
                            .clip(RoundedCornerShape(12.dp))
                            .background(colors.panel)
                            .padding(Space.s),
                        horizontalArrangement = Arrangement.spacedBy(Space.xs),
                    ) {
                        Column {
                            IconButton(
                                onClick = { onMove(index, index - 1) },
                                enabled = index > 0,
                                modifier = Modifier.size(32.dp),
                            ) {
                                Icon(
                                    Icons.Default.KeyboardArrowUp,
                                    L10n.text("android.chatqueuestrip.move_up.c66feb5e"),
                                    tint = if (index > 0) colors.textSecondary else colors.textTertiary,
                                )
                            }
                            IconButton(
                                onClick = { onMove(index, index + 1) },
                                enabled = index < items.lastIndex,
                                modifier = Modifier.size(32.dp),
                            ) {
                                Icon(
                                    Icons.Default.KeyboardArrowDown,
                                    L10n.text("android.chatqueuestrip.move_down.40bb50da"),
                                    tint = if (index < items.lastIndex) colors.textSecondary else colors.textTertiary,
                                )
                            }
                        }
                        ChatQueueRow(
                            item = item,
                            compact = false,
                            offline = offline,
                            onChange = { onChange(item, it) },
                            onRemove = { onRemove(item) },
                            onSendNow = { onSendNow(item) },
                            modifier = Modifier.weight(1f),
                        )
                    }
                }
            }
            Text(
                L10n.text("android.chatqueuestrip.send_now_stops_the_current_turn_check_deli.e8ba1f87"),
                style = TsType.caption,
                color = colors.textSecondary,
            )
        }
    }
}

/// One queued message: its text, what state it is in, and the three things
/// that can be done to it. Port of `ChatQueueRow`.
@Composable
private fun ChatQueueRow(
    item: QueuedMessage,
    compact: Boolean,
    offline: Boolean,
    onChange: (String) -> Unit,
    onRemove: () -> Unit,
    onSendNow: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val colors = LocalTsColors.current
    val context = LocalContext.current
    var draft by remember(item.id) { mutableStateOf(item.text) }
    // The store is the truth: an edit that was refused, or a message another
    // path rewrote, has to show what is actually saved.
    LaunchedEffect(item.text) { if (draft != item.text) draft = item.text }
    Column(modifier, verticalArrangement = Arrangement.spacedBy(Space.xs)) {
        OutlinedTextField(
            value = draft,
            onValueChange = {
                draft = it
                onChange(it)
            },
            enabled = item.canEdit,
            textStyle = TsType.body,
            placeholder = { Text(L10n.text("android.chatqueuestrip.message.2f77668a")) },
            maxLines = if (compact) 2 else 6,
            modifier = Modifier.fillMaxWidth(),
        )
        if (item.attachments.isNotEmpty()) {
            Text(
                if (item.attachments.size == 1) item.attachments[0].name
                else L10n.text("android.chatqueuestrip.0_attached.62e5c2f9", "${item.attachments.size}"),
                style = TsType.caption,
                color = colors.textSecondary,
            )
        }
        val note = when {
            offline ->
                L10n.text("android.chatqueuestrip.reconnect_to_send_or_check_delivery_you_ca.418c13de")
            item.needsReceipt ->
                L10n.text("android.chatqueuestrip.that_computer_has_not_confirmed_this_messa.143c63eb")
            item.delivery == ChatDelivery.NeedsReview ->
                L10n.text("android.chatqueuestrip.review_the_live_conversation_first_use_lat.92fd9e6f")
            item.delivery == ChatDelivery.Ready ->
                L10n.text("android.chatqueuestrip.ready_with_the_conversation_context_you_la.c69bb317")
            item.delivery == ChatDelivery.Failed ->
                L10n.text("android.chatqueuestrip.the_last_attempt_was_refused_your_message.4ef87f5b")
            else -> null
        }
        note?.let { Text(it, style = TsType.caption, color = colors.textSecondary) }
        Row(
            Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.spacedBy(Space.xs),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            TsSecondaryButton(
                label = L10n.text("common.copy"),
                icon = ActionIcon.Copy.vector,
                small = true,
                onClick = { copyToClipboard(context, item.text) },
            )
            TsAccentButton(
                label = when {
                    item.needsReceipt -> L10n.text("android.chatqueuestrip.check_delivery.b8e3662d")
                    item.delivery == ChatDelivery.NeedsReview -> L10n.text("android.chatqueuestrip.use_latest_context.a29959ec")
                    else -> L10n.text("android.chatqueuestrip.send_now.58803287")
                },
                icon = if (item.delivery == ChatDelivery.NeedsReview) {
                    ActionIcon.Refresh.vector
                } else {
                    ActionIcon.Send.vector
                },
                small = true,
                enabled = !offline,
                onClick = onSendNow,
            )
            TsDangerButton(
                label = if (item.needsReceipt) L10n.text("android.chatqueuestrip.remove_copy.63d1aef0") else L10n.text("common.remove"),
                icon = ActionIcon.Delete.vector,
                small = true,
                onClick = onRemove,
            )
        }
    }
}

private fun copyToClipboard(context: Context, text: String) {
    if (text.isEmpty()) return
    val manager = context.getSystemService(ClipboardManager::class.java) ?: return
    manager.setPrimaryClip(ClipData.newPlainText("message", text))
}

/// A note waiting to ride the next tool step. Shown even when nothing else
/// is queued, because the words are already with the agent.
@Composable
fun ChatSteerNoteBanner(
    note: String,
    onRemove: () -> Unit,
) {
    val colors = LocalTsColors.current
    val shape = RoundedCornerShape(16.dp)
    Row(
        Modifier
            .fillMaxWidth()
            .clip(shape)
            .background(colors.accentSoft)
            .border(1.dp, colors.accent.copy(alpha = 0.35f), shape)
            .padding(Space.s),
        horizontalArrangement = Arrangement.spacedBy(Space.s),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Column(
            Modifier
                .weight(1f)
                .semantics(mergeDescendants = false) {
                    contentDescription = L10n.text("android.chatqueuestrip.on_the_next_step_0.81127e40", "${note}")
                },
            verticalArrangement = Arrangement.spacedBy(Space.xs),
        ) {
            Text(
                L10n.text("android.chatqueuestrip.on_the_next_step.78ea7972"),
                style = TsType.caption.copy(fontWeight = FontWeight.Medium),
                color = colors.accent,
            )
            Text(
                note,
                style = TsType.callout,
                color = colors.textPrimary,
                maxLines = 3,
                overflow = TextOverflow.Ellipsis,
            )
        }
        TsSecondaryButton(
            label = L10n.text("common.remove"),
            icon = ActionIcon.Delete.vector,
            small = true,
            onClick = onRemove,
        )
    }
}
