// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.theme

import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.Immutable
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.graphics.Color

/// Shared visual constants, transcribed from the Apple client's
/// `Sources/Design/Theme.swift`. The brand colours follow tokenstat.ai's
/// design tokens, so both clients read as one product in either theme.
@Immutable
data class TsColors(
    val isDark: Boolean,
    val accent: Color,
    val secondary: Color,
    val background: Color,
    val sidebar: Color,
    val panel: Color,
    val tabStrip: Color,
    val border: Color,
    val rowHighlight: Color,
    val controlSeat: Color,
    val controlGlyph: Color,
    val controlGlyphHover: Color,
    val rowSelectedNested: Color,
    val accentSoft: Color,
    val success: Color,
    val warning: Color,
    val danger: Color,
    val stateWorking: Color,
    val stateIdle: Color,
    val diffAdded: Color,
    val diffRemoved: Color,
    /// Five steps of activity, idle first. Step 0 is neutral so a quiet day
    /// reads as "nothing here"; upper levels run violet into fuchsia.
    val heat: List<Color>,
    /// Text colours standing in for SwiftUI's `.primary/.secondary/.tertiary`.
    val textPrimary: Color,
    val textSecondary: Color,
    val textTertiary: Color,
) {
    fun heat(level: Int): Color = heat[level.coerceIn(0, heat.lastIndex)]
}

private fun hex(value: Long): Color = Color(0xFF000000L or value)

private fun hexWithAlpha(alpha: Float, value: Long): Color =
    Color(((alpha * 255).toInt() shl 24) or value.toInt())

val LightColors: TsColors = TsColors(
    isDark = false,
    accent = hex(0x6A3DFF),
    secondary = hex(0xC026D3),
    background = hex(0xFBFBFD),
    sidebar = hex(0xF3F2F8),
    panel = Color.White,
    tabStrip = hex(0xF3F2F8),
    border = hex(0xE7E7EE),
    rowHighlight = hex(0xF0ECFF),
    controlSeat = Color.Black.copy(alpha = 0.06f),
    controlGlyph = hex(0x6B6876),
    controlGlyphHover = hex(0x2A2831),
    rowSelectedNested = hex(0xE8E7F0),
    accentSoft = hex(0xF0ECFF),
    success = hex(0x6A3DFF),
    warning = hex(0xE0A93B),
    danger = hex(0xD6453F),
    stateWorking = hex(0x6A3DFF),
    stateIdle = hex(0x9A97A6),
    diffAdded = hex(0x2E8B57),
    diffRemoved = hex(0xC2453F),
    heat = listOf(
        hex(0xECEAF2),
        hex(0xD6C9FF),
        hex(0xA98CFF),
        hex(0x7C4DFF),
        hex(0xC026D3),
    ),
    textPrimary = hex(0x1C1B22),
    textSecondary = hex(0x5F5D69),
    textTertiary = hex(0x8A8894),
)

val DarkColors: TsColors = TsColors(
    isDark = true,
    accent = hex(0x8B5CF6),
    secondary = hex(0xE879F9),
    background = hex(0x08070D),
    sidebar = hex(0x12101D),
    panel = hex(0x100E1A),
    tabStrip = hex(0x08070D),
    border = hex(0x211D33),
    rowHighlight = hex(0x1B1430),
    controlSeat = Color.White.copy(alpha = 0.09f),
    controlGlyph = hex(0xA8A5B5),
    controlGlyphHover = hex(0xE9E7F0),
    rowSelectedNested = hex(0x26213D),
    accentSoft = hex(0x1B1430),
    success = hex(0x8B5CF6),
    warning = hex(0xE0A93B),
    danger = hex(0xD6453F),
    stateWorking = hex(0x8B5CF6),
    stateIdle = hex(0x6E6A80),
    diffAdded = hex(0x5FBF8B),
    diffRemoved = hex(0xE8827C),
    heat = listOf(
        hex(0x191627),
        hex(0x3B2A6B),
        hex(0x5F3FB8),
        hex(0x8B5CF6),
        hex(0xE879F9),
    ),
    textPrimary = hex(0xF0EFF5),
    textSecondary = hex(0xA8A5B5),
    textTertiary = hex(0x6E6A80),
)

val LocalTsColors = staticCompositionLocalOf { DarkColors }

/// The accent tinted at card strength; success is deliberately the accent.
val TsColors.rowSelected: Color get() = hexWithAlpha(0.18f, if (isDark) 0x8B5CF6 else 0x6A3DFF)

/// A drop shadow weighted for the appearance it lands on: dark mode takes the
/// full weight, light mode a little under half.
fun TsColors.shadow(opacity: Float): Color = Color.Black.copy(alpha = if (isDark) opacity else opacity * 0.35f)

@Composable
fun rememberTsColors(): TsColors = if (isSystemInDarkTheme()) DarkColors else LightColors

@Composable
fun TsTheme(colors: TsColors = rememberTsColors(), content: @Composable () -> Unit) {
    CompositionLocalProvider(LocalTsColors provides colors, content = content)
}
