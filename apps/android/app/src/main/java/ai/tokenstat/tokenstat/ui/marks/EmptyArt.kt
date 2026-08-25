// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.marks

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.size
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.StrokeJoin
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.unit.dp
import ai.tokenstat.tokenstat.ui.theme.LocalTsColors

enum class EmptyArtKind { Sessions, Tasks, Notes, Workflows, Automations, Changes, Files, Waiting, Vault }

/// Line drawings from `ClientEmptyArt.swift`, 128×84, brand stroke.
@Composable
fun EmptyArt(kind: EmptyArtKind, modifier: Modifier = Modifier) {
    val colors = LocalTsColors.current
    val accent = colors.accent
    val border = colors.border
    Canvas(modifier.size(128.dp, 84.dp)) {
        val stroke = Stroke(width = 3.4f, cap = StrokeCap.Round, join = StrokeJoin.Round)
        when (kind) {
            EmptyArtKind.Sessions -> {
                drawRoundRect(border, Offset(size.width * 0.18f, size.height * 0.18f), Size(size.width * 0.64f, size.height * 0.64f), CornerRadius(10f, 10f), style = stroke)
                drawCircle(colors.danger.copy(alpha = 0.7f), 3.5f, Offset(size.width * 0.28f, size.height * 0.32f))
                drawCircle(colors.warning.copy(alpha = 0.7f), 3.5f, Offset(size.width * 0.36f, size.height * 0.32f))
                drawCircle(accent.copy(alpha = 0.7f), 3.5f, Offset(size.width * 0.44f, size.height * 0.32f))
                drawLine(accent, Offset(size.width * 0.28f, size.height * 0.55f), Offset(size.width * 0.34f, size.height * 0.55f), strokeWidth = 3.4f, cap = StrokeCap.Round)
                drawLine(accent, Offset(size.width * 0.38f, size.height * 0.48f), Offset(size.width * 0.38f, size.height * 0.62f), strokeWidth = 3.4f, cap = StrokeCap.Round)
            }
            EmptyArtKind.Tasks -> {
                repeat(3) { i ->
                    val y = size.height * (0.22f + i * 0.22f)
                    drawRoundRect(if (i == 0) accent.copy(alpha = 0.45f) else border, Offset(size.width * 0.18f, y), Size(size.width * 0.64f, size.height * 0.16f), CornerRadius(6f, 6f), style = stroke)
                }
            }
            EmptyArtKind.Notes -> {
                drawRoundRect(border, Offset(size.width * 0.28f, size.height * 0.16f), Size(size.width * 0.44f, size.height * 0.68f), CornerRadius(6f, 6f), style = stroke)
                drawLine(accent, Offset(size.width * 0.36f, size.height * 0.38f), Offset(size.width * 0.62f, size.height * 0.38f), strokeWidth = 3f, cap = StrokeCap.Round)
                drawLine(accent.copy(alpha = 0.5f), Offset(size.width * 0.36f, size.height * 0.50f), Offset(size.width * 0.58f, size.height * 0.50f), strokeWidth = 3f, cap = StrokeCap.Round)
            }
            EmptyArtKind.Workflows -> {
                val nodes = listOf(0.22f, 0.42f, 0.62f, 0.82f)
                nodes.forEachIndexed { i, x ->
                    drawCircle(if (i == 0) accent else border, 7f, Offset(size.width * x, size.height * 0.5f), style = stroke)
                    if (i < nodes.lastIndex) {
                        drawLine(border, Offset(size.width * x + 8f, size.height * 0.5f), Offset(size.width * nodes[i + 1] - 8f, size.height * 0.5f), strokeWidth = 2.4f, cap = StrokeCap.Round)
                    }
                }
            }
            EmptyArtKind.Automations -> {
                drawCircle(border, size.minDimension * 0.28f, Offset(size.width * 0.5f, size.height * 0.5f), style = stroke)
                drawLine(accent, Offset(size.width * 0.5f, size.height * 0.5f), Offset(size.width * 0.5f, size.height * 0.28f), strokeWidth = 3.4f, cap = StrokeCap.Round)
            }
            EmptyArtKind.Changes -> {
                drawLine(colors.diffAdded, Offset(size.width * 0.28f, size.height * 0.30f), Offset(size.width * 0.72f, size.height * 0.30f), strokeWidth = 3f)
                drawLine(colors.diffRemoved, Offset(size.width * 0.28f, size.height * 0.48f), Offset(size.width * 0.62f, size.height * 0.48f), strokeWidth = 3f)
                drawLine(accent, Offset(size.width * 0.28f, size.height * 0.66f), Offset(size.width * 0.55f, size.height * 0.66f), strokeWidth = 3f)
            }
            EmptyArtKind.Files -> {
                drawRoundRect(border, Offset(size.width * 0.22f, size.height * 0.34f), Size(size.width * 0.36f, size.height * 0.42f), CornerRadius(6f, 6f), style = stroke)
                drawRoundRect(accent.copy(alpha = 0.55f), Offset(size.width * 0.42f, size.height * 0.22f), Size(size.width * 0.34f, size.height * 0.48f), CornerRadius(6f, 6f), style = stroke)
            }
            EmptyArtKind.Waiting -> {
                drawRoundRect(border, Offset(size.width * 0.32f, size.height * 0.28f), Size(size.width * 0.36f, size.height * 0.44f), CornerRadius(8f, 8f), style = stroke)
                drawCircle(accent.copy(alpha = 0.35f), size.minDimension * 0.22f, Offset(size.width * 0.5f, size.height * 0.5f), style = stroke)
            }
            EmptyArtKind.Vault -> {
                drawRoundRect(border, Offset(size.width * 0.16f, size.height * 0.22f), Size(size.width * 0.22f, size.height * 0.56f), CornerRadius(10f, 10f), style = stroke)
                drawRoundRect(border, Offset(size.width * 0.48f, size.height * 0.28f), Size(size.width * 0.36f, size.height * 0.44f), CornerRadius(8f, 8f), style = stroke)
                val lock = Path().apply {
                    moveTo(size.width * 0.44f, size.height * 0.52f)
                    lineTo(size.width * 0.56f, size.height * 0.52f)
                    lineTo(size.width * 0.56f, size.height * 0.66f)
                    lineTo(size.width * 0.44f, size.height * 0.66f)
                    close()
                }
                drawPath(lock, accent, style = stroke)
            }
        }
    }
}
