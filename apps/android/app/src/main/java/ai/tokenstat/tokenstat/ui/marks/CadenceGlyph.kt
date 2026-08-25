// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.marks

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.size
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.unit.dp
import ai.tokenstat.tokenstat.ui.theme.LocalTsColors

/// Compact clock from `CadenceGlyph.swift`: a ring and a hand, not a sentence.
@Composable
fun CadenceGlyph(cadence: String, modifier: Modifier = Modifier) {
    val colors = LocalTsColors.current
    val angle = when {
        cadence.contains("hour", ignoreCase = true) -> 90f
        cadence.contains("day", ignoreCase = true) -> 180f
        cadence.contains("week", ignoreCase = true) -> 240f
        else -> 45f
    }
    Canvas(modifier.size(18.dp)) {
        val stroke = Stroke(width = 2.4f, cap = StrokeCap.Round)
        val c = Offset(size.width / 2f, size.height / 2f)
        val r = size.minDimension / 2f - 2f
        drawCircle(colors.border, r, c, style = stroke)
        val rad = Math.toRadians((angle - 90).toDouble())
        drawLine(
            colors.accent,
            c,
            Offset(c.x + (r * 0.62f * kotlin.math.cos(rad)).toFloat(), c.y + (r * 0.62f * kotlin.math.sin(rad)).toFloat()),
            strokeWidth = 2.4f,
            cap = StrokeCap.Round,
        )
    }
}
