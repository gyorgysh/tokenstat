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
import androidx.compose.foundation.shape.RoundedCornerShape
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

/** Keep model and effort on one line; the spoken label includes the backend too. */
@Composable
internal fun ChatComposerAgentField(backends: List<JsonObject>, chat: JsonObject?, onOpen: () -> Unit,
                                    enabled: Boolean, modifier: Modifier = Modifier) {
    val colors = LocalTsColors.current
    val shape = RoundedCornerShape(8.dp)
    Row(modifier.clip(shape).background(colors.panel).border(1.dp, colors.border, shape)
        .clickable(enabled = enabled, role = Role.Button, onClick = onOpen)
        .semantics { contentDescription = chatAgentSummary(backends, chat) }
        .heightIn(min = 44.dp).padding(horizontal = 8.dp, vertical = 5.dp),
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(4.dp)) {
        Box(Modifier.clearAndSetSemantics {}) { HarnessMark(chat?.str("backend").orEmpty(), size = 16.dp) }
        Text(chatAgentCompactSummary(backends, chat),
            modifier = Modifier.weight(1f), style = TsType.callout.copy(fontWeight = FontWeight.Medium),
            color = if (enabled) colors.textPrimary else colors.textTertiary,
            maxLines = 1, overflow = TextOverflow.MiddleEllipsis)
        Icon(ActionIcon.Disclosure.vector, null, tint = colors.textTertiary, modifier = Modifier.size(12.dp))
    }
}

@Composable
internal fun ChatComposerToolbar(backends: List<JsonObject>, chat: JsonObject?, locked: Boolean,
                                expanded: Boolean, onAgent: () -> Unit, onSetup: () -> Unit,
                                onExpand: () -> Unit, quota: @Composable () -> Unit) {
    val colors = LocalTsColors.current
    val actions: @Composable RowScope.() -> Unit = {
        quota()
        IconButton(onClick = onSetup) {
            Icon(ActionIcon.Settings.vector, L10n.text("android.chatpullssections.chat_setup.9fa79d00"),
                tint = colors.accent, modifier = Modifier.size(18.dp))
        }
        IconButton(onClick = onExpand) {
            Icon(if (expanded) ActionIcon.ExitFullScreen.vector else ActionIcon.EnterFullScreen.vector,
                if (expanded) L10n.text("android.chatpullssections.shrink_the_message_box.2430d33f") else L10n.text("android.chatpullssections.expand_the_message_box.c0441a94"),
                tint = colors.accent, modifier = Modifier.size(18.dp))
        }
    }
    BoxWithConstraints(Modifier.fillMaxWidth()) {
        // Keep the model and effort readable beside three action targets.
        if (maxWidth < 360.dp || LocalDensity.current.fontScale > 1.3f) {
            Column(Modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                ChatComposerAgentField(backends, chat, onAgent, !locked, Modifier.fillMaxWidth())
                Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.End, verticalAlignment = Alignment.CenterVertically, content = actions)
            }
        } else {
            Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                ChatComposerAgentField(backends, chat, onAgent, !locked, Modifier.weight(1f))
                actions()
            }
        }
    }
}
