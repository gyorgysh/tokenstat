// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.screen

import ai.tokenstat.tokenstat.ui.components.ActionIcon
import ai.tokenstat.tokenstat.ui.theme.LocalTsColors
import ai.tokenstat.tokenstat.ui.theme.Space
import ai.tokenstat.tokenstat.ui.components.TsType
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.KeyboardArrowDown
import androidx.compose.material.icons.filled.KeyboardArrowUp
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowLeft
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp

/// What the bar can do to the pointer. A value rather than a pile of
/// callbacks, so the bar takes one parameter and the viewer keeps the state.
/// Port of Apple `ScreenPointerControls`.
class ScreenPointerControls(
    val fine: Boolean,
    val dragLatched: Boolean,
    val zoom: Float,
    val click: (Int, Int) -> Unit,
    val toggleDrag: () -> Unit,
    val toggleFine: () -> Unit,
    val resetZoom: () -> Unit,
)

/// The row of keys and pointer buttons a touch screen has no other way to
/// send. Port of Apple `ScreenKeyBar`.
///
/// Sticky rather than held, because holding control with one thumb and typing
/// with the other is not a thing on a phone. A modifier stays lit until the
/// next keystroke spends it.
@Composable
fun ScreenKeyBar(
    modifiers: Long,
    onModifiers: (Long) -> Unit,
    send: (Int, Long) -> Unit,
    pointer: ScreenPointerControls?,
) {
    val colors = LocalTsColors.current
    Row(
        Modifier.fillMaxWidth().background(colors.panel),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        if (pointer != null) {
            // A held mouse button cannot scroll off screen: releasing it is
            // the one pointer action that always has to be reachable. One
            // width for both words, or the pinned button grows the moment it
            // is pressed and shoves the row sideways under the thumb that
            // pressed it.
            ScreenKeyCap(
                label = if (pointer.dragLatched) "Release" else "Hold",
                icon = ActionIcon.Move.vector,
                active = pointer.dragLatched,
                width = 104.dp,
                onClick = pointer.toggleDrag,
                modifier = Modifier.padding(start = Space.m, end = Space.s),
            )
        }
        Row(
            Modifier.weight(1f).horizontalScroll(rememberScrollState())
                .padding(end = Space.m, top = Space.s, bottom = Space.s),
            horizontalArrangement = Arrangement.spacedBy(Space.s),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            if (pointer != null) {
                ScreenKeyCap("click", active = false) { pointer.click(0, 1) }
                ScreenKeyCap("double", active = false) { pointer.click(0, 2) }
                ScreenKeyCap("right", active = false) { pointer.click(1, 1) }
                ScreenKeyCap("fine", active = pointer.fine, onClick = pointer.toggleFine)
                if (pointer.zoom > 1.01f) {
                    ScreenKeyCap(
                        // Pinned to US formatting: the device locale would
                        // render this `2,0x` across much of Europe.
                        label = String.format(java.util.Locale.US, "%.1fx", pointer.zoom),
                        active = true,
                        onClick = pointer.resetZoom,
                    )
                }
                ScreenKeyRule()
            }
            STICKY.forEach { (name, flag) ->
                ScreenKeyCap(name, active = modifiers and flag != 0L) {
                    onModifiers(modifiers xor flag)
                }
            }
            ScreenKeyRule()
            SPECIALS.forEach { special ->
                // An arrow is its own word. The rest carry theirs, because
                // "esc" and "tab" have no glyph anybody would read faster.
                ScreenKeyCap(
                    label = special.label,
                    icon = special.icon,
                    iconOnly = special.icon != null,
                    active = false,
                ) {
                    send(special.code, modifiers)
                    onModifiers(0)
                }
            }
        }
    }
}

private class ScreenSpecial(val label: String, val code: Int, val icon: ImageVector?)

private val SPECIALS = listOf(
    ScreenSpecial("esc", ScreenKey.ESCAPE, null),
    ScreenSpecial("tab", ScreenKey.TAB, null),
    ScreenSpecial("return", ScreenKey.RETURN, null),
    ScreenSpecial("up", ScreenKey.UP, Icons.Default.KeyboardArrowUp),
    ScreenSpecial("down", ScreenKey.DOWN, Icons.Default.KeyboardArrowDown),
    ScreenSpecial("left", ScreenKey.LEFT, Icons.AutoMirrored.Filled.KeyboardArrowLeft),
    ScreenSpecial("right", ScreenKey.RIGHT, Icons.AutoMirrored.Filled.KeyboardArrowRight),
)

private val STICKY = listOf(
    "ctrl" to ScreenFlag.CONTROL,
    "opt" to ScreenFlag.OPTION,
    "cmd" to ScreenFlag.COMMAND,
    "shift" to ScreenFlag.SHIFT,
)

@Composable
private fun ScreenKeyRule() {
    Box(Modifier.width(1.dp).height(20.dp).background(LocalTsColors.current.border))
}

@Composable
private fun ScreenKeyCap(
    label: String,
    active: Boolean,
    modifier: Modifier = Modifier,
    icon: ImageVector? = null,
    iconOnly: Boolean = false,
    width: androidx.compose.ui.unit.Dp? = null,
    onClick: () -> Unit,
) {
    val colors = LocalTsColors.current
    val shape = RoundedCornerShape(8.dp)
    Row(
        modifier
            .then(if (width != null) Modifier.width(width) else Modifier.widthIn(min = 44.dp))
            .heightIn(min = 44.dp)
            .clip(shape)
            .background(if (active) colors.accent else colors.background)
            .border(1.dp, if (active) Color.Transparent else colors.border, shape)
            .clickable(onClick = onClick)
            .padding(horizontal = 10.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(4.dp, Alignment.CenterHorizontally),
    ) {
        if (icon != null) {
            Icon(
                icon,
                if (iconOnly) label else null,
                tint = if (active) Color.White else colors.textPrimary,
                modifier = Modifier.size(if (iconOnly) 20.dp else 16.dp),
            )
        }
        if (!iconOnly) {
            Text(
                label,
                style = TsType.callout.copy(fontWeight = FontWeight.Medium),
                color = if (active) Color.White else colors.textPrimary,
                maxLines = 1,
            )
        }
    }
}
