// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.team

import ai.tokenstat.tokenstat.ui.components.ActionIcon
import ai.tokenstat.tokenstat.ui.components.TsAccentButton
import ai.tokenstat.tokenstat.ui.localization.L10n
import ai.tokenstat.tokenstat.ui.theme.LocalTsColors
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

/**
 * Says that Teams is an early preview, beside the Team title. A phone has
 * no hover, so a tap opens the note that explains what that means.
 */
@Composable internal fun TeamPreviewBadge(modifier: Modifier = Modifier) {
    val colors = LocalTsColors.current
    var open by remember { mutableStateOf(false) }
    val title = L10n.text("common.teams.preview_title")
    Text(L10n.text("common.teams.preview_badge"), color = colors.accent, fontSize = 11.sp, fontWeight = FontWeight.SemiBold,
        modifier = modifier
            .background(colors.accentSoft, RoundedCornerShape(50))
            .clickable(role = Role.Button, onClickLabel = title) { open = true }
            .padding(horizontal = 8.dp, vertical = 3.dp)
            .semantics { contentDescription = title })
    if (open) AlertDialog(onDismissRequest = { open = false },
        title = { Text(title) },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Text(L10n.text("common.teams.preview_detail"))
                Text(L10n.text("common.teams.preview_safety"), color = colors.textSecondary)
            }
        },
        confirmButton = { TsAccentButton(L10n.text("common.done"), icon = ActionIcon.Done.vector, onClick = { open = false }) })
}
