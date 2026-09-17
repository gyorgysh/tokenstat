// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.chrome

import ai.tokenstat.tokenstat.ui.components.TsType
import ai.tokenstat.tokenstat.ui.theme.LocalTsColors
import ai.tokenstat.tokenstat.ui.theme.Space
import ai.tokenstat.tokenstat.ui.theme.TsMotion
import ai.tokenstat.tokenstat.ui.theme.rememberReduceMotion
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.snap
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.selection.selectableGroup
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Icon
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.scale
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

/// One tab in the floating bar: label plus glyph.
data class TabSpec(val label: String, val icon: ImageVector)

/// The floating bar's share of the screen. The host draws the bar over the
/// tab content, and every scrollable under it ends this far above the
/// bottom edge, so the last row rests clear of the glass while scrolled
/// rows pass behind it.
object TabBarChrome {
    /// Bar height plus its margins and breathing room.
    val contentBottomInset = 100.dp
}

/// The floating glass tab bar, matching the iOS 26 system bar the Apple
/// client gets from `TabView`: a rounded translucent dock with a soft
/// active pill, rather than the full-width Material strip. The wide layout
/// keeps its rail; this is the phone bar.
///
/// Like iOS it minimises to a small pill on the left after a longer scroll
/// down, and comes back at the top of the list or on a tap: `minimized` is
/// driven by the screens through `TabBarMinimizeState` (see
/// `TabBarMinimize.kt`), and tapping the pill asks the host to expand again
/// through `onExpandRequest`. The height stays fixed so the content above
/// never reflows mid-scroll.
@Composable
fun FloatingTabBar(
    selected: Int,
    tabs: List<TabSpec>,
    onSelect: (Int) -> Unit,
    modifier: Modifier = Modifier,
    minimized: Boolean = false,
    onExpandRequest: () -> Unit = {},
    backdrop: Backdrop? = null,
) {
    val colors = LocalTsColors.current
    val reduceMotion = rememberReduceMotion()
    val fraction by animateFloatAsState(
        targetValue = if (minimized) 1f else 0f,
        animationSpec = if (reduceMotion) snap() else TsMotion.tunedSpring(0.45f, 0.8f),
        label = "tabMinimize",
    )
    // A capsule at every width, so the minimise animation never passes
    // through a rounded rectangle on its way to the pill.
    val barShape = RoundedCornerShape(percent = 50)
    // Inset further than the old bar: what made the iOS dock read as a
    // floating capsule was the margin around it, not the corner radius.
    BoxWithConstraints(modifier.fillMaxWidth().padding(horizontal = 22.dp).padding(bottom = 14.dp)) {
        val fullWidth = maxWidth
        val pillWidth = 64.dp
        val width = fullWidth - (fullWidth - pillWidth) * fraction
        // Frosted, not see-through. The blur stops list rows being legible
        // under the bar, but a blur alone still leaves the labels sitting on
        // whatever happened to scroll past, so the tint has to give them a
        // steady ground to read against. Legibility wins over the effect:
        // you can still see colour and movement behind the glass, and you
        // can always read the tabs.
        val glass = backdrop?.supported == true
        Surface(
            shape = barShape,
            color = colors.panel.copy(alpha = if (glass) 0.86f else 0.97f),
            // A soft ambient shadow this large reads as a grey haze around
            // the capsule and dirties the labels near its edge. Just enough
            // lift to separate it from the list.
            shadowElevation = 3.dp,
            // No offset: the dock shrinks toward the left like the iOS bar,
            // and the tabs fade under it from the right.
            modifier = Modifier
                .width(width)
                .then(if (backdrop != null) Modifier.backdropBlur(backdrop, barShape) else Modifier)
                .border(1.dp, colors.border, barShape),
        ) {
            Box(
                contentAlignment = Alignment.Center,
                modifier = Modifier.clip(barShape),
            ) {
                // Fixed inner width from the left edge, so the tabs fade
                // under the shrinking dock instead of being squashed into
                // the pill or spilling past its rounded ends.
                Row(
                    Modifier
                        .align(Alignment.CenterStart)
                        .width(fullWidth)
                        .padding(horizontal = 6.dp, vertical = 6.dp)
                        .selectableGroup()
                        .alpha(1f - fraction),
                    horizontalArrangement = Arrangement.SpaceEvenly,
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    tabs.forEachIndexed { index, tab ->
                        FloatingTab(
                            spec = tab,
                            selected = index == selected,
                            enabled = fraction < 0.5f,
                            onClick = { onSelect(index) },
                        )
                    }
                }
                if (fraction > 0f) {
                    MinimizedPill(
                        icon = tabs.getOrNull(selected)?.icon,
                        visible = fraction > 0.5f,
                        fraction = fraction,
                        onExpandRequest = onExpandRequest,
                    )
                }
            }
        }
    }
}

/// The minimised corner pill: the current tab's glyph on the same dock
/// surface, asking the host to expand when tapped.
@Composable
private fun MinimizedPill(
    icon: ImageVector?,
    visible: Boolean,
    fraction: Float,
    onExpandRequest: () -> Unit,
) {
    val colors = LocalTsColors.current
    // Fixed size: this box lives in the Scaffold's bottom bar, and a
    // fillMaxSize here inflates the whole bar to full height.
    Box(
        Modifier
            .size(64.dp)
            .alpha(fraction)
            .clip(RoundedCornerShape(28.dp))
            .clickable(
                enabled = visible,
                onClick = onExpandRequest,
                role = Role.Button,
                onClickLabel = "Show tabs",
            ),
        contentAlignment = Alignment.Center,
    ) {
        if (icon != null) {
            Icon(
                icon,
                contentDescription = "Show tabs",
                tint = colors.accent,
                modifier = Modifier.size(22.dp),
            )
        }
    }
}

@Composable
private fun RowScope.FloatingTab(spec: TabSpec, selected: Boolean, enabled: Boolean, onClick: () -> Unit) {
    val colors = LocalTsColors.current
    val reduceMotion = rememberReduceMotion()
    val pillAlpha by animateFloatAsState(
        targetValue = if (selected) 1f else 0f,
        animationSpec = if (reduceMotion) snap() else TsMotion.tunedSpring(0.45f, 0.8f),
        label = "tabPill",
    )
    val iconScale by animateFloatAsState(
        targetValue = if (selected) 1.08f else 1f,
        animationSpec = if (reduceMotion) snap() else TsMotion.tunedSpring(0.45f, 0.7f),
        label = "tabIcon",
    )
    // One capsule around the glyph and the label together. The old bar put
    // the pill on the glyph alone and left the label outside it, which read
    // as a highlighted icon with a caption rather than as a selected tab.
    Column(
        Modifier
            .weight(1f)
            .clip(RoundedCornerShape(percent = 50))
            .background(colors.accentSoft.copy(alpha = pillAlpha))
            .selectable(selected = selected, enabled = enabled, onClick = onClick, role = Role.Tab)
            .padding(vertical = 7.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(2.dp),
    ) {
        Box(contentAlignment = Alignment.Center) {
            Icon(
                spec.icon,
                spec.label,
                tint = if (selected) colors.accent else colors.textPrimary,
                modifier = Modifier.size(22.dp).scale(iconScale),
            )
        }
        Text(
            spec.label,
            style = TsType.caption2.copy(
                fontSize = 11.sp,
                fontWeight = if (selected) FontWeight.SemiBold else FontWeight.Normal,
            ),
            color = if (selected) colors.accent else colors.textPrimary,
            maxLines = 1,
        )
    }
}
