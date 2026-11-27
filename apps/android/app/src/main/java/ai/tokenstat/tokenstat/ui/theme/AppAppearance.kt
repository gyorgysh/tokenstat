// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.theme

import android.app.UiModeManager
import android.content.Context
import android.os.Build
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.graphics.Color
import ai.tokenstat.tokenstat.ui.localization.L10n

enum class AppearanceMode(val key: String) {
    Auto("auto"),
    Light("light"),
    Dark("dark"),
    Oled("oled");

    val label: String
        get() = when (this) {
            Auto -> L10n.text("common.appearance.auto")
            Light -> L10n.text("common.appearance.light")
            Dark -> L10n.text("common.appearance.dark")
            Oled -> L10n.text("common.appearance.oled")
        }

    val dark: Boolean?
        get() = when (this) {
            Auto -> null
            Light -> false
            Dark, Oled -> true
        }

    companion object {
        fun of(key: String?) = entries.firstOrNull { it.key == key } ?: Auto
    }
}

data class AppearanceColors(
    val background: Color,
    val sidebar: Color,
    val panel: Color,
    val border: Color,
    val accent: Color,
    val secondary: Color,
    val selection: Color,
)

data class AppearancePalette(val id: String, val name: String, val light: AppearanceColors, val dark: AppearanceColors) {
    val label: String get() = if (id == "default") L10n.text("common.appearance.default_theme") else name
}

private fun paletteSide(vararg hex: Long) =
    hex.map { Color(0xFF000000L or it) }.let { AppearanceColors(it[0], it[1], it[2], it[3], it[4], it[5], it[6]) }

object AppAppearance {
    val palettes = listOf(
        AppearancePalette(
            "default", "Default",
            paletteSide(0xFBFBFD, 0xF3F2F8, 0xFFFFFF, 0xE7E7EE, 0x6A3DFF, 0xA21CAF, 0xF0ECFF),
            paletteSide(0x08070D, 0x12101D, 0x100E1A, 0x211D33, 0xA786FF, 0xE879F9, 0x1B1430),
        ),
        AppearancePalette(
            "ink", "Ink",
            paletteSide(0xEDF2F7, 0xE3EAF1, 0xF9FBFD, 0xD1DCE7, 0x315B83, 0x2B6578, 0xDCE8F1),
            paletteSide(0x0D141C, 0x1B2A37, 0x151F2A, 0x293B4B, 0x79B4E0, 0x63C2CF, 0x1D3848),
        ),
        AppearancePalette(
            "ember", "Ember",
            paletteSide(0xFBF1E8, 0xF3E1D2, 0xFFFAF5, 0xEAD4C3, 0xA6431D, 0x8B521E, 0xF6DFCF),
            paletteSide(0x1B100D, 0x352019, 0x281814, 0x4B2C22, 0xFF9A63, 0xEDBD67, 0x48271D),
        ),
        AppearancePalette(
            "aurora", "Aurora",
            paletteSide(0xEAF7F5, 0xD9EFEB, 0xF8FFFE, 0xC7E2DD, 0x096E67, 0x236798, 0xD2EEEA),
            paletteSide(0x081B1B, 0x143836, 0x102928, 0x20504C, 0x65DFC9, 0x81CEF9, 0x17433E),
        ),
    )

    var mode by mutableStateOf(AppearanceMode.Auto)
        private set
    var paletteId by mutableStateOf("default")
        private set

    private fun prefs(context: Context) = context.getSharedPreferences("tokenstat.appearance.v1", Context.MODE_PRIVATE)

    fun load(context: Context) {
        val prefs = prefs(context)
        mode = AppearanceMode.of(prefs.getString("mode", null))
        paletteId = palette(prefs.getString("palette", null)).id
        applyNightMode(context)
    }

    fun choose(context: Context, next: AppearanceMode) {
        mode = next
        prefs(context).edit().putString("mode", next.key).apply()
        applyNightMode(context)
    }

    fun choosePalette(context: Context, id: String) {
        paletteId = palette(id).id
        prefs(context).edit().putString("palette", paletteId).apply()
    }

    fun palette(id: String?) = palettes.firstOrNull { it.id == id } ?: palettes.first()

    private fun applyNightMode(context: Context) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) return
        context.getSystemService(UiModeManager::class.java)?.setApplicationNightMode(
            when (mode.dark) {
                null -> UiModeManager.MODE_NIGHT_AUTO
                true -> UiModeManager.MODE_NIGHT_YES
                false -> UiModeManager.MODE_NIGHT_NO
            },
        )
    }

    fun colors(mode: AppearanceMode, paletteId: String, systemDark: Boolean): TsColors {
        val dark = mode.dark ?: systemDark
        val oled = mode == AppearanceMode.Oled
        var colors = if (dark) DarkColors else LightColors
        val palette = palette(paletteId)
        val themed = palette.id != "default"
        if (themed) {
            val side = if (dark) palette.dark else palette.light
            colors = colors.copy(
                accent = side.accent,
                secondary = side.secondary,
                background = side.background,
                sidebar = side.sidebar,
                panel = side.panel,
                tabStrip = side.sidebar,
                border = side.border,
                rowHighlight = side.selection,
                rowSelectedNested = side.selection,
                accentSoft = side.selection,
                success = side.accent,
                stateWorking = side.accent,
                showsBrandColors = false,
            )
        }
        if (oled) {
            colors = colors.copy(
                background = Color.Black,
                sidebar = Color.Black,
                tabStrip = Color.Black,
                panel = Color(0xFF0C0C0F),
                border = Color.White.copy(alpha = 0.06f),
            )
        }
        if (themed || oled) {
            colors = colors.copy(
                heat = listOf(
                    colors.border,
                    colors.accent.copy(alpha = 0.38f),
                    colors.accent.copy(alpha = 0.7f),
                    colors.accent,
                    colors.secondary,
                ),
                ownsHeat = true,
            )
        }
        return colors
    }
}
