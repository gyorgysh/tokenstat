// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.marks

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.size
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.unit.dp
import ai.tokenstat.tokenstat.ui.theme.LocalTsColors

/// Silhouette marks from `Marks.swift` TierMark: star / badge / crown.
@Composable
fun TierMark(tier: String, markSize: Int = 18) {
    val colors = LocalTsColors.current
    val fill = colors.accent
    Canvas(Modifier.size(markSize.dp)) {
        when (tier.lowercase()) {
            "legend" -> {
                val path = Path().apply {
                    moveTo(size.width * 0.50f, size.height * 0.12f)
                    lineTo(size.width * 0.68f, size.height * 0.42f)
                    lineTo(size.width * 0.92f, size.height * 0.32f)
                    lineTo(size.width * 0.78f, size.height * 0.88f)
                    lineTo(size.width * 0.22f, size.height * 0.88f)
                    lineTo(size.width * 0.08f, size.height * 0.32f)
                    lineTo(size.width * 0.32f, size.height * 0.42f)
                    close()
                }
                drawPath(path, fill)
            }
            "patron" -> {
                val path = Path().apply {
                    moveTo(size.width * 0.50f, size.height * 0.08f)
                    lineTo(size.width * 0.88f, size.height * 0.28f)
                    lineTo(size.width * 0.78f, size.height * 0.82f)
                    lineTo(size.width * 0.22f, size.height * 0.82f)
                    lineTo(size.width * 0.12f, size.height * 0.28f)
                    close()
                }
                drawPath(path, fill)
            }
            "supporter" -> {
                val path = Path().apply {
                    moveTo(size.width * 0.50f, size.height * 0.08f)
                    lineTo(size.width * 0.61f, size.height * 0.38f)
                    lineTo(size.width * 0.92f, size.height * 0.38f)
                    lineTo(size.width * 0.67f, size.height * 0.58f)
                    lineTo(size.width * 0.76f, size.height * 0.90f)
                    lineTo(size.width * 0.50f, size.height * 0.70f)
                    lineTo(size.width * 0.24f, size.height * 0.90f)
                    lineTo(size.width * 0.33f, size.height * 0.58f)
                    lineTo(size.width * 0.08f, size.height * 0.38f)
                    lineTo(size.width * 0.39f, size.height * 0.38f)
                    close()
                }
                drawPath(path, fill)
            }
            else -> drawCircle(fill.copy(alpha = 0.35f), size.minDimension / 2f, Offset(size.width / 2f, size.height / 2f))
        }
    }
}
