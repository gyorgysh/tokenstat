// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.chrome

import ai.tokenstat.tokenstat.ui.localization.L10n

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
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.TextUnit
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
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

data class TabSpec(val label: String, val icon: ImageVector)

object TabBarChrome {
    val contentBottomInset = 100.dp
}

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
    val barShape = RoundedCornerShape(percent = 50)
    val inset = if (LocalConfiguration.current.screenWidthDp < 400) 14.dp else 22.dp
    BoxWithConstraints(modifier.fillMaxWidth().padding(horizontal = inset).padding(bottom = 14.dp)) {
        val fullWidth = maxWidth
        val pillWidth = 64.dp
        val perTab = (fullWidth - 12.dp) / tabs.size.coerceAtLeast(1)
        val fontScale = LocalDensity.current.fontScale
        val labelSize = when {
            perTab < 62.dp * fontScale -> 9.sp
            perTab < 70.dp * fontScale -> 10.sp
            else -> 11.sp
        }
        val width = fullWidth - (fullWidth - pillWidth) * fraction
        val glass = backdrop?.supported == true
        Surface(
            shape = barShape,
            color = colors.panel.copy(alpha = if (glass) 0.86f else 0.97f),
            shadowElevation = 3.dp,
            modifier = Modifier
                .width(width)
                .then(if (backdrop != null) Modifier.backdropBlur(backdrop, barShape) else Modifier)
                .border(1.dp, colors.border, barShape),
        ) {
            Box(
                contentAlignment = Alignment.Center,
                modifier = Modifier.clip(barShape),
            ) {
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
                            labelSize = labelSize,
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

@Composable
private fun MinimizedPill(
    icon: ImageVector?,
    visible: Boolean,
    fraction: Float,
    onExpandRequest: () -> Unit,
) {
    val colors = LocalTsColors.current
    Box(
        Modifier
            .size(64.dp)
            .alpha(fraction)
            .clip(RoundedCornerShape(28.dp))
            .clickable(
                enabled = visible,
                onClick = onExpandRequest,
                role = Role.Button,
                onClickLabel = L10n.text("android.floatingtabbar.show_tabs.321c6e5b"),
            ),
        contentAlignment = Alignment.Center,
    ) {
        if (icon != null) {
            Icon(
                icon,
                contentDescription = L10n.text("android.floatingtabbar.show_tabs.321c6e5b"),
                tint = colors.accent,
                modifier = Modifier.size(22.dp),
            )
        }
    }
}

@Composable
private fun RowScope.FloatingTab(
    spec: TabSpec,
    selected: Boolean,
    enabled: Boolean,
    labelSize: TextUnit,
    onClick: () -> Unit,
) {
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
    Box(Modifier.weight(1f), contentAlignment = Alignment.Center) {
        Box(
            Modifier
                .matchParentSize()
                .clip(RoundedCornerShape(18.dp))
                .background(colors.accentSoft.copy(alpha = pillAlpha))
                .selectable(selected = selected, enabled = enabled, onClick = onClick, role = Role.Tab)
                .semantics { contentDescription = spec.label },
        )
        FloatingTabContent(spec, selected, labelSize, iconScale)
    }
}

@Composable
private fun FloatingTabContent(spec: TabSpec, selected: Boolean, labelSize: TextUnit, iconScale: Float) {
    val colors = LocalTsColors.current
    Column(
        Modifier
            .fillMaxWidth()
            .clearAndSetSemantics {}
            .padding(horizontal = 2.dp, vertical = 7.dp),
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
                fontSize = labelSize,
                fontWeight = if (selected) FontWeight.SemiBold else FontWeight.Normal,
            ),
            color = if (selected) colors.accent else colors.textPrimary,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
        )
    }
}
