// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.chrome

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.CloudOff
import androidx.compose.material.icons.filled.Laptop
import androidx.compose.material.icons.filled.WifiOff
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import ai.tokenstat.tokenstat.ConnectionUi
import ai.tokenstat.tokenstat.ui.components.RelativeTick
import ai.tokenstat.tokenstat.ui.components.TsAccentButton
import ai.tokenstat.tokenstat.ui.logic.RelativeClock
import ai.tokenstat.tokenstat.ui.theme.LocalTsColors
import ai.tokenstat.tokenstat.ui.theme.Space

/// The one place the client says the network is unwell.
///
/// Hidden while everything answers, so it never becomes furniture. Present,
/// it is a glyph in the top bar, and tapping it explains which of the three
/// things is wrong and offers the one control that can help.
///
/// Glyph only, like the Apple client's compact chip. A top bar this narrow is
/// already carrying an avatar and a title, and "Computer unreachable" landed
/// on top of both. The sentence lives in the dialog, which is where somebody
/// who tapped it is looking anyway.
///
/// It does not replace what a screen says about its own empty state. This is
/// the global answer, the screen gives the local one, and they cannot
/// contradict each other because both read the same `ConnectionTracker`.
@Composable
fun ConnectionChip(connection: ConnectionUi, onRetry: () -> Unit) {
    if (connection.ok) return
    val colors = LocalTsColors.current
    var open by remember { mutableStateOf(false) }
    val tint = if (connection.down) colors.danger else colors.warning
    // A glyph per cause. A wall of identical warning triangles teaches people
    // to stop reading them.
    val glyph = when {
        connection.offline -> Icons.Default.WifiOff
        connection.service -> Icons.Default.CloudOff
        else -> Icons.Default.Laptop
    }
    Row(
        Modifier
            .clip(RoundedCornerShape(50))
            .background(tint.copy(alpha = 0.14f))
            .clickable { open = true }
            .padding(horizontal = Space.s, vertical = 4.dp)
            .semantics { contentDescription = "Connection: ${connection.title}" },
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        Icon(glyph, null, tint = tint, modifier = Modifier.padding(0.dp))
    }
    if (open) {
        AlertDialog(
            onDismissRequest = { open = false },
            icon = { Icon(glyph, null, tint = tint) },
            title = {
                Text(connection.title, style = TextStyle(fontSize = 16.sp, fontWeight = FontWeight.SemiBold))
            },
            text = {
                Column(verticalArrangement = Arrangement.spacedBy(Space.s)) {
                    Text(connection.detail, color = colors.textSecondary)
                    // The most recent answer from either plane. "Nothing since
                    // you opened the app" is said by leaving this out rather
                    // than by inventing a time. One Text rather than a label
                    // beside a time, so it wraps on a narrow screen.
                    connection.lastGoodMs?.let { at ->
                        RelativeTick.start()
                        val now by RelativeTick.now.collectAsStateWithLifecycle()
                        Text(
                            "Last answered ${RelativeClock.label(at, now)}",
                            style = TextStyle(fontSize = 12.sp),
                            color = colors.textTertiary,
                        )
                    }
                }
            },
            confirmButton = {
                TsAccentButton(
                    label = "Try now",
                    small = true,
                    onClick = { open = false; onRetry() },
                )
            },
            dismissButton = {
                TextButton(onClick = { open = false }) {
                    Text("Close", color = colors.textSecondary)
                }
            },
        )
    }
}
