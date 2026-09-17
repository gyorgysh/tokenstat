// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.automations

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ChevronRight
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import ai.tokenstat.tokenstat.ui.components.ActionIcon
import ai.tokenstat.tokenstat.ui.components.TsCard
import ai.tokenstat.tokenstat.ui.components.TsType
import ai.tokenstat.tokenstat.ui.components.cardRadiusDp
import ai.tokenstat.tokenstat.ui.marks.RunOutcome
import ai.tokenstat.tokenstat.ui.theme.LocalTsColors
import ai.tokenstat.tokenstat.ui.theme.Space

/// A labelled fact on a job or graph. Same shape on every detail page.
/// Port of `ClientFactRow`.
@Composable
fun JobFactRow(label: String, value: String, modifier: Modifier = Modifier) {
    Column(modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(2.dp)) {
        Text(label, style = TsType.caption, color = LocalTsColors.current.textTertiary)
        Text(value, style = TsType.subheadline, color = LocalTsColors.current.textPrimary)
    }
}

/// The outcome pill beside a run. Dot plus words, like the Apple client.
@Composable
fun JobStatusPill(status: String, text: String, modifier: Modifier = Modifier) {
    val colors = LocalTsColors.current
    val tint = RunOutcome.tint(status, colors)
    Row(
        modifier
            .clip(CircleShape)
            .background(tint.copy(alpha = 0.12f))
            .padding(horizontal = Space.s, vertical = 2.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(Space.xs),
    ) {
        androidx.compose.foundation.Canvas(Modifier.size(7.dp)) {
            drawCircle(tint)
        }
        Text(text, style = TsType.caption.copy(fontWeight = FontWeight.Medium), color = tint)
    }
}

/// One past run as a row. Used on the phone list and the detail preview.
/// Port of `ClientPastRunRow`.
@Composable
fun PastRunRow(
    title: String,
    status: String,
    label: String,
    whenText: String,
    isSelected: Boolean = false,
    onOpen: () -> Unit,
) {
    val colors = LocalTsColors.current
    Row(
        Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(cardRadiusDp))
            .background(if (isSelected) colors.rowHighlight else colors.panel)
            .clickable(onClick = onOpen)
            .padding(Space.m),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(Space.s),
    ) {
        androidx.compose.foundation.Canvas(Modifier.size(8.dp)) {
            drawCircle(RunOutcome.tint(status, colors))
        }
        Text(
            title.ifBlank { "Run" },
            style = TsType.subheadline.copy(fontWeight = FontWeight.Medium),
            color = colors.textPrimary,
            maxLines = 1,
            modifier = Modifier.weight(1f),
        )
        JobStatusPill(status, label)
        Text(whenText, style = TsType.caption, color = colors.textSecondary)
        Icon(Icons.Default.ChevronRight, null, tint = colors.textTertiary, modifier = Modifier.size(12.dp))
    }
}

/// Opens the complete run history from a short preview.
/// Port of `ClientAllRunsRow`.
@Composable
fun AllRunsRow(count: Int, onOpen: () -> Unit) {
    val colors = LocalTsColors.current
    Row(
        Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(cardRadiusDp))
            .background(colors.panel)
            .clickable(onClick = onOpen)
            .padding(Space.m),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(Space.s),
    ) {
        Icon(ActionIcon.History.vector, null, tint = colors.accent, modifier = Modifier.size(22.dp))
        Text(
            ai.tokenstat.tokenstat.ui.tasks.allRunsLabel(count),
            style = TsType.subheadline.copy(fontWeight = FontWeight.Medium),
            color = colors.textPrimary,
            modifier = Modifier.weight(1f),
        )
        Icon(Icons.Default.ChevronRight, null, tint = colors.textTertiary, modifier = Modifier.size(12.dp))
    }
}

/// The header every full-page workbench screen shares: back, title,
/// subtitle, and trailing actions on the app background.
@Composable
fun JobScreenHeader(
    title: String,
    subtitle: String,
    onBack: () -> Unit,
    actions: @Composable () -> Unit = {},
) {
    val colors = LocalTsColors.current
    Row(verticalAlignment = Alignment.CenterVertically) {
        IconButton(onClick = onBack) {
            Icon(ActionIcon.Back.vector, "Back", tint = colors.controlGlyph)
        }
        Column(Modifier.weight(1f)) {
            Text(title, style = TsType.headline, color = colors.textPrimary, maxLines = 1)
            if (subtitle.isNotBlank()) {
                Text(subtitle, style = TsType.caption, color = colors.textSecondary, maxLines = 1)
            }
        }
        actions()
    }
}

/// A confirm that names the machine, like the Apple confirmation dialogs.
/// Confirms are not management screens, so a dialog is the faithful shape.
@Composable
fun JobConfirmDialog(
    title: String,
    message: String,
    confirmLabel: String,
    destructive: Boolean = false,
    onConfirm: () -> Unit,
    onDismiss: () -> Unit,
) {
    val colors = LocalTsColors.current
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(title, color = colors.textPrimary) },
        text = { Text(message, color = colors.textSecondary) },
        confirmButton = {
            TextButton(onClick = { onDismiss(); onConfirm() }) {
                Text(confirmLabel, color = if (destructive) colors.danger else colors.accent)
            }
        },
        dismissButton = {
            TextButton(onClick = onDismiss) { Text("Cancel", color = colors.textSecondary) }
        },
    )
}

/// A past run's timestamp: the host wall clock when the zone is known,
/// otherwise this device's short time. Port of `ClientPastRunRow.when`.
fun pastRunWhen(epochMs: Long, timezone: String?): String =
    HostScheduleClock.wallClock(epochMs, timezone)
        ?: java.text.DateFormat.getTimeInstance(java.text.DateFormat.SHORT).format(java.util.Date(epochMs))

/// A run header timestamp in this device's locale, like the Apple run view.
fun deviceDateTime(epochMs: Long): String =
    java.text.DateFormat.getDateTimeInstance(java.text.DateFormat.MEDIUM, java.text.DateFormat.SHORT)
        .format(java.util.Date(epochMs))

/// The empty detail: the run or job is gone but the folder is still here.
@Composable
fun JobGoneCard(title: String, message: String) {
    TsCard(title = title) {
        Text(
            message,
            style = TsType.caption,
            color = LocalTsColors.current.textSecondary,
            modifier = Modifier.padding(Space.m),
        )
    }
}
