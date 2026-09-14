// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.marks

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.size
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material3.Icon
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import ai.tokenstat.tokenstat.ui.theme.LocalTsColors
import kotlin.math.PI
import kotlin.math.cos
import kotlin.math.sin

/// Whether a weekday dot fires, with Monday as day 0, matching the host
/// `weekdays` bitset and Apple's `CadenceGlyph.fires`. Weekly prefers the
/// bitset when it carries days and falls back to the single `weekday`, the
/// same choice the schedule summary makes, so the ring cannot contradict it.
fun scheduleFires(kind: String, weekdays: Int, weekday: Int, day: Int): Boolean =
    when (kind.lowercase()) {
        "daily" -> true
        "weekdays" -> day < 5
        "weekly" ->
            if (weekdays and 0x7F != 0) weekdays and (1 shl day) != 0
            else day == weekday
        "custom" -> weekdays and (1 shl day) != 0
        else -> false
    }

/// A schedule as a shape rather than a sentence, from `CadenceGlyph.swift`.
/// Seven dots around a ring, Monday at the top running clockwise, the live
/// ones filled. A paused job draws in the idle tint: it still has a rhythm,
/// it just is not keeping it. Once and interval jobs are symbols, not rings.
@Composable
fun CadenceGlyph(
    kind: String,
    weekdays: Int = 0,
    weekday: Int = 0,
    enabled: Boolean = true,
    summary: String = "",
    glyphSize: Int = 22,
) {
    val colors = LocalTsColors.current
    val tint = if (enabled) colors.accent else colors.stateIdle
    val label = summary.ifBlank { kind.ifBlank { "schedule" } }
    when (kind.lowercase()) {
        "once" -> Icon(
            Icons.Default.PlayArrow,
            contentDescription = label,
            tint = tint,
            modifier = Modifier.size(glyphSize.dp),
        )
        "interval" -> Icon(
            Icons.Default.Refresh,
            contentDescription = label,
            tint = tint,
            modifier = Modifier.size(glyphSize.dp),
        )
        else -> Canvas(
            Modifier
                .size(glyphSize.dp)
                .semantics { contentDescription = label },
        ) {
            val side = size.minDimension
            val dot = maxOf(3f, side * 0.19f)
            val radius = (side - dot) / 2f
            val center = Offset(size.width / 2f, size.height / 2f)
            drawCircle(colors.border, radius, center, style = Stroke(width = 1.dp.toPx()))
            for (day in 0 until 7) {
                val angle = day / 7f * 2f * PI.toFloat()
                val at = Offset(
                    center.x + radius * sin(angle),
                    center.y - radius * cos(angle),
                )
                drawCircle(
                    if (scheduleFires(kind, weekdays, weekday, day)) tint
                    else colors.stateIdle.copy(alpha = 0.28f),
                    dot / 2f,
                    at,
                )
            }
        }
    }
}
