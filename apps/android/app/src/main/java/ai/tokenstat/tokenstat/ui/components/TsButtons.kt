// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.components

import androidx.compose.animation.core.tween
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInHorizontally
import androidx.compose.animation.slideOutHorizontally
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.collectIsPressedAsState
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import ai.tokenstat.tokenstat.ui.theme.LocalTsColors
import ai.tokenstat.tokenstat.ui.theme.Space
import ai.tokenstat.tokenstat.ui.theme.TsMotion

private val buttonShape = RoundedCornerShape(8.dp)

/// Soft accent capsule for a primary action in content, ported from
/// `AccentButtonStyle`. Toolbar items stay system-styled.
@Composable
fun TsAccentButton(
    label: String,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    icon: ImageVector? = null,
    small: Boolean = false,
    enabled: Boolean = true,
) {
    val colors = LocalTsColors.current
    TsCapsuleButton(
        label = label,
        icon = icon,
        small = small,
        enabled = enabled,
        onClick = onClick,
        modifier = modifier,
        contentColor = colors.accent,
        fill = colors.accentSoft,
        pressedFill = colors.accent.copy(alpha = 0.18f),
        stroke = BorderStroke(1.dp, colors.accent.copy(alpha = 0.35f)),
        pressedStroke = BorderStroke(1.dp, colors.accent.copy(alpha = 0.35f)),
    )
}

/// The secondary action: the same capsule family, but neutral — panel fill,
/// hairline border, primary text. For revoke, forget and every action that is
/// a real operation but not the one being offered.
@Composable
fun TsSecondaryButton(
    label: String,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    icon: ImageVector? = null,
    small: Boolean = false,
    enabled: Boolean = true,
) {
    val colors = LocalTsColors.current
    TsCapsuleButton(
        label = label,
        icon = icon,
        small = small,
        enabled = enabled,
        onClick = onClick,
        modifier = modifier,
        contentColor = colors.textPrimary,
        fill = colors.panel,
        pressedFill = colors.rowHighlight,
        stroke = BorderStroke(1.dp, colors.border),
        pressedStroke = BorderStroke(1.dp, colors.accent.copy(alpha = 0.35f)),
    )
}

@Composable
private fun TsCapsuleButton(
    label: String,
    icon: ImageVector?,
    small: Boolean,
    enabled: Boolean,
    onClick: () -> Unit,
    modifier: Modifier,
    contentColor: Color,
    fill: Color,
    pressedFill: Color,
    stroke: BorderStroke,
    pressedStroke: BorderStroke,
) {
    val interaction = remember { MutableInteractionSource() }
    val pressed by interaction.collectIsPressedAsState()
    Box(
        modifier
            .clip(buttonShape)
            .background(if (pressed) pressedFill else fill)
            .border(if (pressed) pressedStroke else stroke, buttonShape)
            .clickable(interactionSource = interaction, indication = null, enabled = enabled, onClick = onClick)
            .padding(horizontal = if (small) 10.dp else 14.dp, vertical = if (small) 4.dp else 6.dp)
            .alpha(if (pressed) 0.85f else 1f),
        contentAlignment = Alignment.Center,
    ) {
        Row(horizontalArrangement = Arrangement.spacedBy(if (small) 5.dp else 6.dp), verticalAlignment = Alignment.CenterVertically) {
            if (icon != null) Icon(icon, null, tint = contentColor)
            Text(
                label,
                style = TextStyle(fontSize = (if (small) 12 else 13).sp, fontWeight = FontWeight.Medium),
                color = if (enabled) contentColor else contentColor.copy(alpha = 0.45f),
            )
        }
    }
}

/// A capsule selector in the app's own language: equal segments inside a
/// bordered panel, the selected one filled with the accent's soft tint and
/// accent text. Deliberately not the system's segmented control.
@Composable
fun <T> SegmentedCapsulePicker(
    options: List<Triple<T, String, ImageVector?>>,
    selection: T,
    onSelect: (T) -> Unit,
    modifier: Modifier = Modifier,
) {
    val colors = LocalTsColors.current
    Row(
        modifier
            .clip(RoundedCornerShape(10.dp))
            .background(colors.panel)
            .border(BorderStroke(1.dp, colors.border), RoundedCornerShape(10.dp))
            .padding(3.dp),
        horizontalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        options.forEach { (value, label, symbol) ->
            val active = value == selection
            Column(
                Modifier
                    .weight(1f)
                    .clip(RoundedCornerShape(7.dp))
                    .background(if (active) colors.accentSoft else Color.Transparent)
                    .clickable(indication = null, interactionSource = remember { MutableInteractionSource() }) {
                        onSelect(value)
                    }
                    .padding(vertical = 6.dp),
                horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.spacedBy(Space.xs),
            ) {
                if (symbol != null) Icon(symbol, null, tint = if (active) colors.accent else colors.controlGlyph)
                Text(
                    label,
                    style = TextStyle(fontSize = 13.sp, fontWeight = if (active) FontWeight.SemiBold else FontWeight.Normal),
                    color = if (active) colors.accent else colors.controlGlyph,
                    maxLines = 1,
                )
            }
        }
    }
}

/// A short-lived confirmation that does not push the content column down.
/// Slides in from the trailing edge with opacity (Apple: snappy 0.25).
@Composable
fun TransientToast(
    message: String?,
    onDismissed: () -> Unit,
    modifier: Modifier = Modifier,
    actionLabel: String? = null,
    onAction: (() -> Unit)? = null,
) {
    val colors = LocalTsColors.current
    AnimatedVisibility(
        visible = message != null,
        enter = slideInHorizontally(tween(TsMotion.toastMillis)) { it } + fadeIn(tween(TsMotion.toastMillis)),
        exit = slideOutHorizontally(tween(TsMotion.toastMillis)) { it } + fadeOut(tween(TsMotion.toastMillis)),
        modifier = modifier,
    ) {
        Row(
            Modifier
                .clip(RoundedCornerShape(50))
                .background(colors.sidebar)
                .border(BorderStroke(1.dp, colors.success.copy(alpha = 0.35f)), RoundedCornerShape(50))
                .padding(horizontal = Space.m, vertical = Space.s),
            horizontalArrangement = Arrangement.spacedBy(Space.s),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            message?.let {
                Text(it, style = TextStyle(fontSize = 14.sp, fontWeight = FontWeight.Medium), color = colors.success)
            }
            if (actionLabel != null && onAction != null) {
                Text(
                    actionLabel,
                    style = TextStyle(fontSize = 14.sp, fontWeight = FontWeight.SemiBold),
                    color = colors.accent,
                    modifier = Modifier.clickable(
                        indication = null,
                        interactionSource = remember { MutableInteractionSource() },
                    ) {
                        onAction()
                        onDismissed()
                    },
                )
            }
        }
    }
}
