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
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
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
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.scale
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

/// One tab in the floating bar: label plus glyph.
data class TabSpec(val label: String, val icon: ImageVector)

/// The floating glass tab bar, matching the iOS 26 system bar the Apple
/// client gets from `TabView`: a rounded translucent dock with a soft
/// active pill, rather than the full-width Material strip. The wide layout
/// keeps its rail; this is the phone bar.
@Composable
fun FloatingTabBar(
    selected: Int,
    tabs: List<TabSpec>,
    onSelect: (Int) -> Unit,
    modifier: Modifier = Modifier,
) {
    val colors = LocalTsColors.current
    Box(modifier.fillMaxWidth().padding(horizontal = 16.dp).padding(bottom = 12.dp)) {
        Surface(
            shape = RoundedCornerShape(28.dp),
            color = colors.panel.copy(alpha = 0.92f),
            shadowElevation = 8.dp,
            modifier = Modifier.fillMaxWidth().border(1.dp, colors.border, RoundedCornerShape(28.dp)),
        ) {
            Row(
                Modifier
                    .fillMaxWidth()
                    .padding(horizontal = 8.dp, vertical = 10.dp)
                    .selectableGroup(),
                horizontalArrangement = Arrangement.SpaceEvenly,
                verticalAlignment = Alignment.CenterVertically,
            ) {
                tabs.forEachIndexed { index, tab ->
                    FloatingTab(
                        spec = tab,
                        selected = index == selected,
                        onClick = { onSelect(index) },
                    )
                }
            }
        }
    }
}

@Composable
private fun RowScope.FloatingTab(spec: TabSpec, selected: Boolean, onClick: () -> Unit) {
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
    Column(
        Modifier
            .weight(1f)
            .clip(RoundedCornerShape(20.dp))
            .selectable(selected = selected, onClick = onClick, role = Role.Tab),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(2.dp),
    ) {
        Box(
            Modifier
                .size(width = 52.dp, height = 32.dp)
                .clip(RoundedCornerShape(16.dp))
                .background(colors.accentSoft.copy(alpha = pillAlpha)),
            contentAlignment = Alignment.Center,
        ) {
            Icon(
                spec.icon,
                spec.label,
                tint = if (selected) colors.accent else colors.controlGlyph,
                modifier = Modifier.size(22.dp).scale(iconScale),
            )
        }
        Text(
            spec.label,
            style = TsType.caption2.copy(
                fontSize = 11.sp,
                fontWeight = if (selected) FontWeight.SemiBold else FontWeight.Normal,
            ),
            color = if (selected) colors.accent else colors.controlGlyph,
            maxLines = 1,
        )
    }
}
