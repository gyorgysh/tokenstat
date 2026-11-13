// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.workspace

import ai.tokenstat.tokenstat.ui.components.ActionIcon
import ai.tokenstat.tokenstat.ui.components.TsType
import ai.tokenstat.tokenstat.ui.localization.L10n
import ai.tokenstat.tokenstat.ui.marks.HarnessMark
import androidx.compose.material3.IconButton
import androidx.compose.ui.platform.LocalDensity
import ai.tokenstat.tokenstat.ui.theme.LocalTsColors
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Tune
import androidx.compose.material.icons.filled.UnfoldMore
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import kotlinx.serialization.json.JsonObject

/// What this chat runs on, as the iPhone composer shows it: the agent's mark,
/// then "model · effort", sized to its words rather than to the row. The
/// spoken label names the agent too. A dot on the corner says this agent has
/// an update, and the picker it opens has the button. Port of
/// `ChatAgentField(compactLabel: true)`.
@Composable
internal fun ChatComposerAgentField(backends: List<JsonObject>, chat: JsonObject?, onOpen: () -> Unit,
                                    enabled: Boolean, modifier: Modifier = Modifier) {
    val colors = LocalTsColors.current
    val shape = RoundedCornerShape(10.dp)
    val updateWaiting = backendOf(backends, chat?.str("backend").orEmpty())?.bol("updateAvailable") == true
    Box(modifier) {
        Row(Modifier.clip(shape).background(colors.panel).border(1.dp, colors.border, shape)
            .clickable(enabled = enabled, role = Role.Button, onClick = onOpen)
            .semantics {
                contentDescription = chatAgentSummary(backends, chat) +
                    if (updateWaiting) ", " + L10n.text("common.agent_updates.waiting") else ""
            }
            .heightIn(min = 44.dp).padding(horizontal = 10.dp, vertical = 6.dp),
            verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
            Box(Modifier.clearAndSetSemantics {}) { HarnessMark(chat?.str("backend").orEmpty(), size = 16.dp) }
            Text(chatAgentCompactSummary(backends, chat),
                modifier = Modifier.weight(1f, fill = false), style = TsType.callout.copy(fontWeight = FontWeight.Medium),
                color = if (enabled) colors.textPrimary else colors.textTertiary,
                maxLines = 1, overflow = TextOverflow.MiddleEllipsis)
            Icon(Icons.Default.UnfoldMore, null, tint = colors.textTertiary, modifier = Modifier.size(14.dp))
        }
        if (updateWaiting) {
            Box(Modifier.align(Alignment.TopEnd).offset(x = 2.dp, y = (-2).dp).size(7.dp).clip(CircleShape)
                .background(colors.accent).clearAndSetSemantics {})
        }
    }
}

/// The row above the field, in the iPhone's order: the agent on the left,
/// then setup, the limits ring, Hide keyboard while it is open, Stop while a
/// turn runs, and the expand toggle. One row, so the field keeps its height.
/// Port of `ChatComposerControls(condensed:)` with its chrome.
@Composable
internal fun ChatComposerToolbar(backends: List<JsonObject>, chat: JsonObject?, locked: Boolean,
                                expanded: Boolean, onAgent: () -> Unit, onSetup: () -> Unit,
                                onExpand: () -> Unit, quota: @Composable () -> Unit,
                                running: Boolean = false, onStop: () -> Unit = {},
                                keyboardOpen: Boolean = false, onHideKeyboard: () -> Unit = {}) {
    val colors = LocalTsColors.current
    val actions: @Composable RowScope.() -> Unit = {
        IconButton(onClick = onSetup) {
            Icon(Icons.Default.Tune, L10n.text("android.chatpullssections.chat_setup.9fa79d00"), tint = colors.textPrimary)
        }
        quota()
        if (keyboardOpen) {
            IconButton(onClick = onHideKeyboard) {
                Icon(ActionIcon.HideKeyboard.vector, L10n.text("android.chatpullssections.hide_keyboard"), tint = colors.textSecondary)
            }
        }
        if (running) {
            IconButton(onClick = onStop) {
                Icon(ActionIcon.Stop.vector, L10n.text("common.stop"), tint = colors.danger)
            }
        }
        IconButton(onClick = onExpand) {
            Icon(if (expanded) ActionIcon.ExitFullScreen.vector else ActionIcon.EnterFullScreen.vector,
                if (expanded) L10n.text("android.chatpullssections.shrink_the_message_box.2430d33f") else L10n.text("android.chatpullssections.expand_the_message_box.c0441a94"),
                tint = colors.accent)
        }
    }
    BoxWithConstraints(Modifier.fillMaxWidth()) {
        // Large text, or a narrow window: the chip gets its own line so its
        // words stay readable beside up to five action targets.
        if (maxWidth < 360.dp || LocalDensity.current.fontScale > 1.3f) {
            Column(Modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                ChatComposerAgentField(backends, chat, onAgent, !locked)
                Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.End, verticalAlignment = Alignment.CenterVertically, content = actions)
            }
        } else {
            Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                // The chip keeps its own width and the actions stay at the end.
                Box(Modifier.weight(1f)) { ChatComposerAgentField(backends, chat, onAgent, !locked) }
                actions()
            }
        }
    }
}
