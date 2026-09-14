// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.marks

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import ai.tokenstat.tokenstat.ui.components.RelativeTick
import ai.tokenstat.tokenstat.ui.components.RelativeTimeText
import ai.tokenstat.tokenstat.ui.theme.LocalTsColors

/// How much of the wait until the next run is already spent. Mirrors
/// `CountdownRing` in `Sources/Design/CadenceGlyph.swift`: without a start
/// the ring cannot show progress, so it draws empty; a non-positive span
/// draws full.
fun countdownFraction(startMillis: Long?, endMillis: Long, nowMillis: Long): Double {
    if (startMillis == null) return 0.0
    val total = endMillis - startMillis
    if (total <= 0) return 1.0
    return minOf(1.0, maxOf(0.0, (nowMillis - startMillis).toDouble() / total))
}

/// A date you would otherwise have to subtract today from, as a ring that is
/// nearly closed when the run is soon. The fraction reads the shared
/// `RelativeTick`, the same subscription the words beside it use.
@Composable
fun CountdownRing(
    startMillis: Long?,
    endMillis: Long,
    modifier: Modifier = Modifier,
    size: Dp = 18.dp,
    lineWidth: Dp = 2.5.dp,
) {
    val colors = LocalTsColors.current
    RelativeTick.start()
    val now by RelativeTick.now.collectAsStateWithLifecycle()
    val fraction = countdownFraction(startMillis, endMillis, now).toFloat()
    Canvas(
        modifier
            .size(size)
            .semantics { contentDescription = "Next run" },
    ) {
        val stroke = Stroke(width = lineWidth.toPx(), cap = StrokeCap.Round)
        val diameter = size.toPx() - lineWidth.toPx()
        drawArc(
            color = colors.border,
            startAngle = 0f,
            sweepAngle = 360f,
            useCenter = false,
            style = stroke,
            size = Size(diameter, diameter),
            topLeft = Offset(lineWidth.toPx() / 2f, lineWidth.toPx() / 2f),
        )
        if (fraction > 0f) {
            drawArc(
                color = colors.accent,
                startAngle = -90f,
                sweepAngle = 360f * fraction,
                useCenter = false,
                style = stroke,
                size = Size(diameter, diameter),
                topLeft = Offset(lineWidth.toPx() / 2f, lineWidth.toPx() / 2f),
            )
        }
    }
}

/// The countdown ring with the words it stands for, for rows that have
/// space. Ported from `NextRunBadge`.
@Composable
fun NextRunBadge(startMillis: Long?, endMillis: Long, modifier: Modifier = Modifier) {
    val colors = LocalTsColors.current
    Row(
        modifier = modifier,
        horizontalArrangement = Arrangement.spacedBy(4.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        CountdownRing(startMillis = startMillis, endMillis = endMillis)
        RelativeTimeText(
            epochMillis = endMillis,
            style = TextStyle(fontSize = 12.sp),
            color = colors.textSecondary,
        )
    }
}

/// Tiles actually drawn. The number comes from a text field somebody is
/// still typing into, so it has to be bounded: past this many the count is
/// words, not shapes. Ported from `SlotGauge.maxTiles`.
const val SLOT_GAUGE_MAX_TILES = 12

/// How many tiles to draw for a total that may still be mid-typing.
fun slotGaugeDrawn(total: Int, maxTiles: Int = SLOT_GAUGE_MAX_TILES): Int =
    minOf(maxOf(total, 1), maxTiles)

/// The words the gauge stands for, matching the Apple accessibility label.
fun slotGaugeLabel(filled: Int, total: Int, uncapped: Boolean): String {
    if (uncapped) return "No limit on jobs at once"
    return "$filled of $total slots busy"
}

/// Concurrency as places at a table, filled by what is running now.
/// Ported from `SlotGauge`: zero concurrent means no cap on the host, which
/// has no shape at all, so it says so in words instead of drawing an
/// infinite row of tiles.
@Composable
fun SlotGauge(
    filled: Int,
    total: Int,
    modifier: Modifier = Modifier,
    uncapped: Boolean = false,
    tile: Dp = 10.dp,
) {
    val colors = LocalTsColors.current
    val drawn = slotGaugeDrawn(total)
    val tileShape = RoundedCornerShape(3.dp)
    Row(
        modifier.semantics { contentDescription = slotGaugeLabel(filled, total, uncapped) },
        horizontalArrangement = Arrangement.spacedBy(3.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        if (uncapped) {
            Text(
                "No cap",
                style = TextStyle(fontSize = 12.sp),
                color = colors.textSecondary,
            )
        } else {
            repeat(drawn) { index ->
                Box(
                    Modifier
                        .size(tile)
                        .clip(tileShape)
                        .background(if (index < filled) colors.accent else colors.border),
                )
            }
            if (total > drawn) {
                Text(
                    "+${total - drawn}",
                    style = TextStyle(fontSize = 12.sp),
                    color = colors.textSecondary,
                    modifier = Modifier.padding(start = 1.dp),
                )
            }
        }
    }
}
