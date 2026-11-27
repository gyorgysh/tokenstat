// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.components

import ai.tokenstat.tokenstat.ui.localization.L10n
import ai.tokenstat.tokenstat.ui.theme.AppAppearance
import ai.tokenstat.tokenstat.ui.theme.AppearanceMode
import ai.tokenstat.tokenstat.ui.theme.AppearancePalette
import ai.tokenstat.tokenstat.ui.theme.LocalTsColors
import ai.tokenstat.tokenstat.ui.theme.Space
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.selection.selectableGroup
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.SideEffect
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.DialogWindowProvider
import androidx.core.view.WindowCompat

@Composable
fun AppearanceCard() {
    val context = LocalContext.current
    val colors = LocalTsColors.current
    val view = LocalView.current
    (view.parent as? DialogWindowProvider)?.window?.let { window ->
        SideEffect {
            WindowCompat.getInsetsController(window, view).apply {
                isAppearanceLightStatusBars = !colors.isDark
                isAppearanceLightNavigationBars = !colors.isDark
            }
        }
    }
    TsCard(title = L10n.text("common.appearance.title"), mark = "mark_device") {
        Column(verticalArrangement = Arrangement.spacedBy(Space.m)) {
            SegmentedCapsulePicker(
                options = AppearanceMode.entries.map { Triple(it, it.label, null as ImageVector?) },
                selection = AppAppearance.mode,
                onSelect = { AppAppearance.choose(context, it) },
            )
            Column(Modifier.selectableGroup(), verticalArrangement = Arrangement.spacedBy(Space.s)) {
                AppAppearance.palettes.chunked(2).forEach { pair ->
                    Row(horizontalArrangement = Arrangement.spacedBy(Space.s)) {
                        pair.forEach { palette ->
                            PaletteSwatch(palette, AppAppearance.paletteId == palette.id, Modifier.weight(1f)) {
                                AppAppearance.choosePalette(context, palette.id)
                            }
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun PaletteSwatch(palette: AppearancePalette, selected: Boolean, modifier: Modifier, onSelect: () -> Unit) {
    val colors = LocalTsColors.current
    val side = if (colors.isDark) palette.dark else palette.light
    val ground = if (AppAppearance.mode == AppearanceMode.Oled) Color.Black else side.background
    val shape = RoundedCornerShape(12.dp)
    Column(
        modifier
            .clip(shape)
            .background(if (selected) colors.accentSoft else colors.panel)
            .border(1.dp, if (selected) colors.accent else colors.border, shape)
            .selectable(selected, role = Role.RadioButton, onClick = onSelect)
            .padding(Space.s),
        verticalArrangement = Arrangement.spacedBy(Space.s),
    ) {
        Box(
            Modifier.fillMaxWidth().height(34.dp).clip(RoundedCornerShape(8.dp))
                .background(Brush.linearGradient(listOf(ground, side.accent, side.secondary))),
        )
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(palette.label, style = TsType.callout, color = colors.textPrimary, maxLines = 1, modifier = Modifier.weight(1f))
            if (selected) Icon(ActionIcon.Done.vector, null, tint = colors.accent, modifier = Modifier.size(16.dp))
        }
    }
}
