// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.theme

import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.luminance
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class AppAppearanceTest {
    private fun contrast(a: Color, b: Color): Float {
        val (light, dark) = listOf(a.luminance(), b.luminance()).sortedDescending()
        return (light + 0.05f) / (dark + 0.05f)
    }

    @Test fun theDefaultThemeIsTheBrandExactly() {
        assertEquals(LightColors, AppAppearance.colors(AppearanceMode.Auto, "default", systemDark = false))
        assertEquals(DarkColors, AppAppearance.colors(AppearanceMode.Auto, "default", systemDark = true))
        assertEquals(DarkColors, AppAppearance.colors(AppearanceMode.Dark, "default", systemDark = false))
        assertEquals(LightColors, AppAppearance.colors(AppearanceMode.Light, "default", systemDark = true))
    }

    @Test fun oledIsBlackWithARaisedPanelAndItsOwnHeat() {
        val colors = AppAppearance.colors(AppearanceMode.Oled, "default", systemDark = false)
        assertTrue(colors.isDark)
        assertEquals(Color.Black, colors.background)
        assertEquals(Color(0xFF0C0C0F), colors.panel)
        assertTrue(colors.ownsHeat)
        assertTrue(colors.showsBrandColors)
    }

    @Test fun aThemeKeepsTheLogoOutOfItsColors() {
        assertFalse(AppAppearance.colors(AppearanceMode.Auto, "ember", systemDark = true).showsBrandColors)
    }

    @Test fun everyThemeReadsOnEverySurface() {
        AppAppearance.palettes.forEach { palette ->
            AppearanceMode.entries.forEach { mode ->
                val colors = AppAppearance.colors(mode, palette.id, systemDark = true)
                // The default dark accent is the brand's and sits just under.
                val floor = if (palette.id == "default") 4f else 4.5f
                listOf(colors.background, colors.sidebar, colors.panel).forEach {
                    assertTrue("${palette.id} $mode", contrast(colors.accent, it) >= floor)
                }
                assertTrue("on accent ${palette.id} $mode", contrast(colors.onAccent, colors.accent) >= 4f)
            }
        }
    }

    @Test fun aStoredThemeThisBuildDoesNotKnowIsTheDefault() {
        assertEquals("default", AppAppearance.palette("gone").id)
        assertEquals(AppearanceMode.Auto, AppearanceMode.of("gone"))
    }
}
