// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.theme

import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.ColorScheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
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
    /// The Apple client never gives these a hex: body text is `.primary`
    /// (opaque black or white) and supporting text the hierarchical
    /// `.secondary` and `.tertiary` styles, which are that same black or
    /// white at 60% and 30% alpha. These transcribe that behaviour, not a
    /// brand value, so they stay readable if the background ever moves.
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

/// The accent tinted at card strength; success is deliberately the accent.
val TsColors.rowSelected: Color get() = hexWithAlpha(0.18f, if (isDark) 0x8B5CF6 else 0x6A3DFF)

/// Highlight kind, mirroring the core table the Apple client reads. A kind
/// this build does not know decodes as Unknown and renders as plain text.
enum class SyntaxKind {
    Keyword, String, Number, Comment, Type, Function, Constant, Attribute,
    Property, Variable, Operator, Punctuation, Markup, Unknown,
}

/// Colour for a syntax kind.
///
/// The whole palette in one place, transcribed hex-for-hex from the Apple
/// client's `Sources/Design/Theme.swift`, which is the only place the app
/// decides what a keyword looks like. Variables, operators and punctuation
/// stay the text colour: colouring every token is how a file ends up
/// unreadable, so most of it must not be coloured.
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

/// A drop shadow weighted for the appearance it lands on: dark mode takes the
/// full weight, light mode a little under half.
fun TsColors.shadow(opacity: Float): Color = Color.Black.copy(alpha = if (isDark) opacity else opacity * 0.35f)

@Composable
fun rememberTsColors(): TsColors = if (isSystemInDarkTheme()) DarkColors else LightColors

/// Material widgets that have not been restyled still read this scheme, so
/// light paper cannot sit under a forced `darkColorScheme`.
fun TsColors.toColorScheme(): ColorScheme {
    val onAccent = Color.White
    // Every floating surface reads the container roles: dialogs use High,
    // menus use Container. Leaving them at Material's defaults painted all
    // thirty-odd dialogs and every menu neutral grey in dark mode, while
    // light mode hid it. Highest stays default on purpose: it feeds the
    // switch and progress tracks, which read fine grey on a card and would
    // blend into one in panel.
    return if (isDark) {
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
            onError = onAccent,
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
            onError = onAccent,
            tertiary = secondary,
            onTertiary = onAccent,
        )
    }
}

@Composable
fun TsTheme(colors: TsColors = rememberTsColors(), content: @Composable () -> Unit) {
    CompositionLocalProvider(LocalTsColors provides colors, content = content)
}
