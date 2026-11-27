// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.components

import ai.tokenstat.tokenstat.ui.theme.onAccent
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.selection.toggleable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Check
import androidx.compose.material3.Icon
import androidx.compose.material3.Switch
import androidx.compose.material3.SwitchDefaults
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.unit.dp
import ai.tokenstat.tokenstat.ui.theme.LocalTsColors
import ai.tokenstat.tokenstat.ui.theme.Space

@Composable
fun BrandCheckbox(
    checked: Boolean,
    onToggle: () -> Unit,
    label: String,
    modifier: Modifier = Modifier,
    enabled: Boolean = true,
) {
    val colors = LocalTsColors.current
    val boxShape = RoundedCornerShape(5.dp)
    Row(
        modifier
            .alpha(if (enabled) 1f else 0.45f)
            .toggleable(
                value = checked,
                enabled = enabled,
                indication = null,
                interactionSource = remember { MutableInteractionSource() },
                role = Role.Checkbox,
                onValueChange = { onToggle() },
            )
            .padding(vertical = Space.xs)
            .heightIn(min = 44.dp),
        horizontalArrangement = Arrangement.spacedBy(Space.s),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Box(
            Modifier
                .size(18.dp)
                .clip(boxShape)
                .background(if (checked) colors.accent else colors.background)
                .border(1.5.dp, if (checked) colors.accent else colors.textSecondary.copy(alpha = 0.75f), boxShape),
            contentAlignment = Alignment.Center,
        ) {
            if (checked) {
                Icon(
                    Icons.Filled.Check,
                    null,
                    tint = colors.onAccent,
                    modifier = Modifier.size(11.dp),
                )
            }
        }
        Text(label, style = TsType.subheadline, color = colors.textPrimary, modifier = Modifier.weight(1f))
    }
}

@Composable
fun BrandCheckDisc(on: Boolean, modifier: Modifier = Modifier) {
    val colors = LocalTsColors.current
    Box(
        modifier
            .size(26.dp)
            .clip(CircleShape)
            .background(if (on) colors.accent else Color.Transparent)
            .border(
                1.5.dp,
                if (on) colors.accent else colors.border,
                CircleShape,
            ),
        contentAlignment = Alignment.Center,
    ) {
        if (on) {
            Icon(
                Icons.Filled.Check,
                null,
                tint = colors.onAccent,
                modifier = Modifier.size(12.dp),
            )
        }
    }
}

@Composable
fun TsBrandSwitch(
    checked: Boolean,
    onCheckedChange: (Boolean) -> Unit,
    modifier: Modifier = Modifier,
    enabled: Boolean = true,
) {
    val colors = LocalTsColors.current
    Switch(
        checked = checked,
        onCheckedChange = onCheckedChange,
        modifier = modifier,
        enabled = enabled,
        colors = SwitchDefaults.colors(
            checkedThumbColor = colors.onAccent,
            checkedTrackColor = colors.accent,
            checkedBorderColor = colors.accent,
            uncheckedThumbColor = colors.controlGlyph,
            uncheckedTrackColor = colors.controlSeat,
            uncheckedBorderColor = colors.border,
        ),
    )
}
