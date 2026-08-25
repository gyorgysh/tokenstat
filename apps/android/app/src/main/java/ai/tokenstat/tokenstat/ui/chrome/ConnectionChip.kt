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
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import ai.tokenstat.tokenstat.ConnectionUi
import ai.tokenstat.tokenstat.ui.components.TsAccentButton
import ai.tokenstat.tokenstat.ui.theme.LocalTsColors
import ai.tokenstat.tokenstat.ui.theme.Space

/// Hidden while everything answers. Present, it is a capsule in the top bar.
@Composable
fun ConnectionChip(connection: ConnectionUi, onRetry: () -> Unit) {
    if (connection.ok) return
    val colors = LocalTsColors.current
    var open by remember { mutableStateOf(false) }
    val tint = if (connection.down) colors.danger else colors.warning
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
            .padding(horizontal = Space.s, vertical = 4.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        Icon(glyph, null, tint = tint, modifier = Modifier.padding(0.dp))
    }
    if (open) {
        AlertDialog(
            onDismissRequest = { open = false },
            title = {
                Text(connection.title, style = TextStyle(fontSize = 16.sp, fontWeight = FontWeight.SemiBold))
            },
            text = {
                Column(verticalArrangement = Arrangement.spacedBy(Space.s)) {
                    Text(connection.detail, color = colors.textSecondary)
                }
            },
            confirmButton = {
                TsAccentButton(
                    label = "Try now",
                    small = true,
                    onClick = { open = false; onRetry() },
                )
            },
        )
    }
}
