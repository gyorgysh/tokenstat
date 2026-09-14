// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.components

import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.sp
import org.junit.Assert.assertEquals
import org.junit.Test

/// Pins the Android type scale to the Apple client's phone ladder in
/// `Sources/Design/Theme.swift`, so the two clients cannot drift apart
/// silently. Every size and weight here traces to that file.
class TsTypeTest {

    @Test
    fun phoneLadderSizes() {
        assertEquals(34.sp, TsType.largeTitle.fontSize)
        assertEquals(28.sp, TsType.title.fontSize)
        assertEquals(22.sp, TsType.title2.fontSize)
        assertEquals(20.sp, TsType.title3.fontSize)
        assertEquals(17.sp, TsType.headline.fontSize)
        assertEquals(17.sp, TsType.body.fontSize)
        assertEquals(16.sp, TsType.callout.fontSize)
        assertEquals(15.sp, TsType.subheadline.fontSize)
        assertEquals(13.sp, TsType.footnote.fontSize)
        assertEquals(12.sp, TsType.caption.fontSize)
        assertEquals(11.sp, TsType.caption2.fontSize)
    }

    @Test
    fun headlineIsSemiboldBodyIsRegular() {
        assertEquals(FontWeight.SemiBold, TsType.headline.fontWeight)
        assertEquals(FontWeight.Normal, TsType.body.fontWeight)
        assertEquals(FontWeight.SemiBold, TsType.sectionHeader.fontWeight)
        assertEquals(12.sp, TsType.sectionHeader.fontSize)
    }

    @Test
    fun chatStepsDownFromBody() {
        assertEquals(15.sp, TsType.chatBody.fontSize)
        assertEquals(12.sp, TsType.chatCode.fontSize)
    }

    @Test
    fun interfaceTextIsManropeCodeIsMono() {
        assertEquals(TsType.interfaceFamily, TsType.body.fontFamily)
        assertEquals(TsType.interfaceFamily, TsType.caption.fontFamily)
        assertEquals(TsType.interfaceFamily, TsType.sectionHeader.fontFamily)
        assertEquals(TsType.monoFamily, TsType.chatCode.fontFamily)
        val mono = TsType.mono(13)
        assertEquals(TsType.monoFamily, mono.fontFamily)
        assertEquals(13.sp, mono.fontSize)
    }

    @Test
    fun numbersUseTabularFiguresInTheInterfaceFace() {
        val style = TsType.numeric(26, FontWeight.Medium)
        assertEquals(26.sp, style.fontSize)
        assertEquals(FontWeight.Medium, style.fontWeight)
        assertEquals(TsType.interfaceFamily, style.fontFamily)
        assertEquals("tnum", style.fontFeatureSettings)
    }

    @Test
    fun materialSlotsReadTheLadder() {
        val typography = TsType.typography
        assertEquals(TsType.body, typography.bodyLarge)
        assertEquals(TsType.footnote, typography.bodySmall)
        assertEquals(TsType.title3, typography.headlineSmall)
        assertEquals(TsType.caption2, typography.labelSmall)
        assertEquals(TsType.interfaceFamily, typography.bodyLarge.fontFamily)
    }
}
