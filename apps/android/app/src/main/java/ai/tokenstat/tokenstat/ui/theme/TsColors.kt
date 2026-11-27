// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.theme

import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.ColorScheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.Immutable
import androidx.compose.runtime.remember
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.luminance

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
    val heat: List<Color>,
    val textPrimary: Color,
    val textSecondary: Color,
    val textTertiary: Color,
    val showsBrandColors: Boolean = true,
    val ownsHeat: Boolean = false,
) {
    fun heat(level: Int): Color = heat[level.coerceIn(0, heat.lastIndex)]
}

private fun hex(value: Long): Color = Color(0xFF000000L or value)

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
    textPrimary = Color.Black,
    textSecondary = Color.Black.copy(alpha = 0.6f),
    textTertiary = Color.Black.copy(alpha = 0.3f),
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
    textPrimary = Color.White,
    textSecondary = Color.White.copy(alpha = 0.6f),
    textTertiary = Color.White.copy(alpha = 0.3f),
)

val LocalTsColors = staticCompositionLocalOf { DarkColors }

val TsColors.rowSelected: Color get() = accent.copy(alpha = 0.18f)

val TsColors.onAccent: Color get() = if (accent.luminance() > 0.35f) Color(0xFF111114) else Color.White

enum class SyntaxKind {
    Keyword, String, Number, Comment, Type, Function, Constant, Attribute,
    Property, Variable, Operator, Punctuation, Markup, Unknown,
}

fun TsColors.syntax(kind: SyntaxKind): Color = when (kind) {
    SyntaxKind.Keyword -> accent
    SyntaxKind.String ->
        if (isDark) hex(0xD8A657) else hex(0x8F5C1E)
    SyntaxKind.Number, SyntaxKind.Constant ->
        if (isDark) hex(0x7FD1B9) else hex(0x1F6F5C)
    SyntaxKind.Comment ->
        if (isDark) hex(0x6B6B76) else hex(0x8A8A93)
    SyntaxKind.Type -> secondary
    SyntaxKind.Function ->
        if (isDark) hex(0x89B4FA) else hex(0x2D62C4)
    SyntaxKind.Attribute ->
        if (isDark) hex(0xC79BF0) else hex(0x9A5CC4)
    SyntaxKind.Property ->
        if (isDark) hex(0x9CC5E0) else hex(0x1F5F8F)
    SyntaxKind.Markup ->
        if (isDark) hex(0x8FD6BE) else hex(0x1F6F5C)
    SyntaxKind.Variable, SyntaxKind.Operator, SyntaxKind.Punctuation, SyntaxKind.Unknown ->
        textPrimary
}

fun TsColors.shadow(opacity: Float): Color = Color.Black.copy(alpha = if (isDark) opacity else opacity * 0.35f)

@Composable
fun rememberTsColors(): TsColors {
    val systemDark = isSystemInDarkTheme()
    val mode = AppAppearance.mode
    val palette = AppAppearance.paletteId
    return remember(systemDark, mode, palette) { AppAppearance.colors(mode, palette, systemDark) }
}

fun TsColors.toColorScheme(): ColorScheme {
    val onAccent = onAccent
    val scheme = if (isDark) {
        darkColorScheme(
            primary = accent,
            onPrimary = onAccent,
            secondary = secondary,
            onSecondary = onAccent,
            background = background,
            onBackground = textPrimary,
            surface = panel,
            onSurface = textPrimary,
            surfaceVariant = sidebar,
            onSurfaceVariant = textSecondary,
            surfaceContainerLowest = background,
            surfaceContainerLow = panel,
            surfaceContainer = panel,
            surfaceContainerHigh = panel,
            outline = border,
            error = danger,
            onError = Color.White,
            tertiary = secondary,
            onTertiary = onAccent,
        )
    } else {
        lightColorScheme(
            primary = accent,
            onPrimary = onAccent,
            secondary = secondary,
            onSecondary = onAccent,
            background = background,
            onBackground = textPrimary,
            surface = panel,
            onSurface = textPrimary,
            surfaceVariant = sidebar,
            onSurfaceVariant = textSecondary,
            surfaceContainerLowest = background,
            surfaceContainerLow = panel,
            surfaceContainer = panel,
            surfaceContainerHigh = panel,
            outline = border,
            error = danger,
            onError = Color.White,
            tertiary = secondary,
            onTertiary = onAccent,
        )
    }
    return if (showsBrandColors) scheme else scheme.copy(secondaryContainer = border, onSecondaryContainer = textPrimary)
}

@Composable
fun TsTheme(colors: TsColors = rememberTsColors(), content: @Composable () -> Unit) {
    CompositionLocalProvider(LocalTsColors provides colors, content = content)
}
