// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.components

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
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
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import ai.tokenstat.tokenstat.ui.theme.LocalTsColors
import ai.tokenstat.tokenstat.ui.theme.Space

/// A checkbox in the app's colours. Ported from `BrandCheckboxStyle` in
/// `Sources/Design/Theme.swift`: the stock checkbox is a small grey circle
/// on a dark panel, so a tick in an accent box says the same thing and
/// belongs to this app. The whole row is the tap target.
@Composable
fun BrandCheckbox(
    checked: Boolean,
    onToggle: () -> Unit,
    label: String,
    modifier: Modifier = Modifier,
) {
    val colors = LocalTsColors.current
    val boxShape = RoundedCornerShape(5.dp)
    Row(
        modifier
            .clickable(
                indication = null,
                interactionSource = remember { MutableInteractionSource() },
                role = Role.Checkbox,
                onClick = onToggle,
            )
            .padding(vertical = Space.xs)
            .heightIn(min = 44.dp)
            .semantics { contentDescription = "$label, ${if (checked) "On" else "Off"}" },
        horizontalArrangement = Arrangement.spacedBy(Space.s),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Box(
            Modifier
                .size(18.dp)
                .clip(boxShape)
                .background(if (checked) colors.accent else colors.panel)
                .border(1.dp, if (checked) colors.accent else colors.border, boxShape),
            contentAlignment = Alignment.Center,
        ) {
            if (checked) {
                Icon(
                    Icons.Filled.Check,
                    null,
                    tint = Color.White,
                    modifier = Modifier.size(11.dp),
                )
            }
        }
        Text(label, style = TsType.subheadline, color = colors.textPrimary, modifier = Modifier.weight(1f))
    }
}

/// A check that wears the theme, not the platform default. Ported from
/// `ThemeCheckDisc`: accent-filled with a white check when on, a quiet ring
/// when off. The disc never handles the touch; the row around it does.
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
                tint = Color.White,
                modifier = Modifier.size(12.dp),
            )
        }
    }
}

/// The one switch the app keeps, in the app's colours. A `Switch` left
/// untinted draws the platform default, and a default-coloured control in
/// this app reads as a control from another app. Single flags that can be a
/// chip should be a `BrandToggleChip` instead; this is for rows where the
/// platform switch is the expected shape, like notifications.
@Composable
fun TsBrandSwitch(
    checked: Boolean,
    onCheckedChange: (Boolean) -> Unit,
    modifier: Modifier = Modifier,
) {
    val colors = LocalTsColors.current
    Switch(
        checked = checked,
        onCheckedChange = onCheckedChange,
        modifier = modifier,
        colors = SwitchDefaults.colors(
            checkedThumbColor = Color.White,
            checkedTrackColor = colors.accent,
            checkedBorderColor = colors.accent,
            uncheckedThumbColor = colors.controlGlyph,
            uncheckedTrackColor = colors.controlSeat,
            uncheckedBorderColor = colors.border,
        ),
    )
}
