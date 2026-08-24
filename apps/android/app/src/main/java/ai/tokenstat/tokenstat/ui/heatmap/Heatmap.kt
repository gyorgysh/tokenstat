// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.heatmap

import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.runtime.snapshotFlow
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.input.pointer.positionChange
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import ai.tokenstat.tokenstat.ui.components.TsType
import ai.tokenstat.tokenstat.ui.logic.money
import ai.tokenstat.tokenstat.ui.theme.LocalTsColors
import ai.tokenstat.tokenstat.ui.theme.Space
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.longOrNull

private val cellSize = 15.dp
private val cellGap = 3.dp

/// The phone's year heatmap, a direct port of `PhoneHeatmap.swift`: fixed cell
/// size, horizontally scrolling grid opened on the most recent week, month
/// marks offset across the top, locked days muted, and press-and-hold day
/// focus with tap-to-open detail.
///
/// Fitting 53 weeks to a phone width shrinks a day below anything a finger can
/// hit, which is why the Apple client scrolls the year too.
@Composable
fun YearHeatmap(
    rows: JsonArray,
    months: JsonArray,
    onSelectDay: (JsonObject) -> Unit,
    modifier: Modifier = Modifier,
) {
    val colors = LocalTsColors.current
    val density = androidx.compose.ui.platform.LocalDensity.current
    val stepPx = with(density) { (cellSize + cellGap).toPx() }
    val cellPx = with(density) { cellSize.toPx() }
    val weeks = ((rows.firstOrNull() as? JsonArray)?.size ?: rows.size).coerceAtLeast(1)
    val gridWidthDp = (cellSize + cellGap) * weeks - cellGap
    val scroll = rememberScrollState()

    // Open on the latest week, which is the part anybody wants first.
    // maxValue is zero until the grid has been laid out, so follow it.
    LaunchedEffect(rows) {
        snapshotFlow { scroll.maxValue }.collect { max ->
            if (max > 0 && scroll.value < max) scroll.scrollTo(max)
        }
    }

    var focusCell by remember { mutableStateOf<Pair<Int, Int>?>(null) }
    val focusAlpha by animateFloatAsState(
        targetValue = if (focusCell != null) 1f else 0f,
        animationSpec = tween(120),
        label = "heatmapFocus",
    )

    Row(modifier) {
        Column(Modifier.width(16.dp)) {
            Spacer(Modifier.height(14.dp))
            listOf("M", "", "W", "", "F", "", "").forEach { letter ->
                Box(Modifier.height(cellSize), contentAlignment = Alignment.CenterStart) {
                    Text(
                        letter,
                        style = TsType.sectionHeader.copy(fontSize = 10.sp),
                        color = colors.textTertiary,
                    )
                }
            }
        }
        Column(Modifier.horizontalScroll(scroll)) {
            Box(Modifier.height(14.dp).width(gridWidthDp)) {
                months.forEach { month ->
                    val entry = month as? JsonArray ?: return@forEach
                    val column = entry.firstOrNull()?.jsonPrimitive?.intOrNull ?: return@forEach
                    val name = entry.getOrNull(1)?.jsonPrimitive?.contentOrNull ?: return@forEach
                    Text(
                        name,
                        style = TextStyle(fontSize = 10.sp),
                        color = colors.textSecondary,
                        modifier = Modifier.offset(x = (cellSize + cellGap) * column),
                    )
                }
            }
            Canvas(
                Modifier
                    .width(gridWidthDp)
                    .height((cellSize + cellGap) * 7 - cellGap)
                    .pointerInput(rows) {
                        awaitEachGesture {
                            val down = awaitFirstDown()
                            focusCell = Pair(
                                (down.position.x / stepPx).toInt(),
                                (down.position.y / stepPx).toInt(),
                            )
                            var pressed = true
                            while (pressed) {
                                val event = awaitPointerEvent()
                                if (event.changes.all { !it.pressed }) pressed = false
                                else if (event.changes.any { it.positionChange() != Offset.Zero }) {
                                    val p = event.changes.first().position
                                    focusCell = Pair((p.x / stepPx).toInt(), (p.y / stepPx).toInt())
                                }
                            }
                            val cellAt = focusCell
                            focusCell = null
                            if (cellAt != null) {
                                val week = rows.getOrNull(cellAt.second) as? JsonArray
                                (week?.getOrNull(cellAt.first) as? JsonObject)?.let(onSelectDay)
                            }
                        }
                    },
            ) {
                rows.forEachIndexed { rowIdx, row ->
                    val week = row as? JsonArray ?: return@forEachIndexed
                    week.forEachIndexed { col, day ->
                        if (day !is JsonObject) return@forEachIndexed
                        val level = (day["level"]?.jsonPrimitive?.intOrNull ?: fallbackLevel(day)).coerceIn(0, 4)
                        var paint = colors.heat[level]
                        if (day["locked"]?.jsonPrimitive?.booleanOrNull == true) {
                            paint = paint.copy(alpha = paint.alpha * 0.28f)
                        }
                        drawRoundRect(
                            color = paint,
                            topLeft = Offset(col * stepPx, rowIdx * stepPx),
                            size = Size(cellPx, cellPx),
                            cornerRadius = CornerRadius(6f, 6f),
                        )
                    }
                }
                // Press-and-hold day focus: the square under the finger lifts.
                focusCell?.let { (col, rowIdx) ->
                    drawRoundRect(
                        color = colors.accent,
                        topLeft = Offset(col * stepPx - 2f, rowIdx * stepPx - 2f),
                        size = Size(cellPx + 4f, cellPx + 4f),
                        cornerRadius = CornerRadius(8f, 8f),
                        style = Stroke(width = 4f),
                        alpha = focusAlpha,
                    )
                }
            }
        }
    }
}

private fun fallbackLevel(day: JsonObject): Int = when (val v = day["value"]?.jsonPrimitive?.longOrNull ?: 0L) {
    0L -> 0
    in 1..49_999 -> 1
    in 50_000..499_999 -> 2
    else -> 3
}

/// The tapped-day sheet, standing in for `DayDetailSheet.swift`: everything
/// the calendar cell carries, at reading size.
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun DayDetailSheet(day: JsonObject?, onDismiss: () -> Unit) {
    if (day == null) return
    ModalBottomSheet(onDismissRequest = onDismiss) {
        Column(
            Modifier
                .fillMaxWidth()
                .padding(horizontal = Space.l)
                .padding(bottom = Space.xl),
            verticalArrangement = Arrangement.spacedBy(Space.s),
        ) {
            Text(
                day["date"]?.jsonPrimitive?.contentOrNull ?: "",
                style = TextStyle(fontSize = 17.sp, fontWeight = FontWeight.SemiBold),
                color = LocalTsColors.current.textPrimary,
            )
            val value = day["value"]?.jsonPrimitive?.longOrNull ?: 0L
            Text(money(value), style = TsType.numeric(30, FontWeight.Medium), color = LocalTsColors.current.accent)
            if (day["locked"]?.jsonPrimitive?.booleanOrNull == true) {
                Text(
                    "Locked history shows the shape of the year only.",
                    style = TextStyle(fontSize = 13.sp),
                    color = LocalTsColors.current.textSecondary,
                )
            }
        }
    }
}
