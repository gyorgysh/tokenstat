// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.heatmap

import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.togetherWith
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.TouchApp
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
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
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.platform.LocalViewConfiguration
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import ai.tokenstat.tokenstat.ui.components.TsType
import ai.tokenstat.tokenstat.ui.logic.RelativeClock
import ai.tokenstat.tokenstat.ui.logic.money
import ai.tokenstat.tokenstat.ui.theme.LocalTsColors
import ai.tokenstat.tokenstat.ui.theme.Space
import java.time.LocalDate
import java.time.format.DateTimeFormatter
import java.util.Locale
import kotlinx.coroutines.withTimeoutOrNull
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.longOrNull

private val cellSize = 15.dp
private val cellGap = 3.5.dp
private val cellCorner = 3.dp
private val gutterWidth = 16.dp
private val monthRowHeight = 13.dp

/// A day cell under the finger, with the square it was drawn in.
private data class FocusCell(val col: Int, val row: Int, val day: JsonObject)

/// `YYYY-MM-DD` as a person reads it. "11 August", with the year only when it
/// is not this one: a column of dates all carrying the same year is a column
/// of noise. Falls back to the raw string rather than to today's date.
fun shortDate(iso: String, today: LocalDate = LocalDate.now()): String {
    val date = runCatching { LocalDate.parse(iso) }.getOrNull() ?: return iso
    val pattern = if (date.year == today.year) "d MMMM" else "d MMMM yyyy"
    return date.format(DateTimeFormatter.ofPattern(pattern, Locale.getDefault()))
}

/// "11 August 2026". Used where the year matters, because a sheet saying an
/// ISO date says nothing.
fun spokenDate(iso: String): String {
    val date = runCatching { LocalDate.parse(iso) }.getOrNull() ?: return iso
    return date.format(DateTimeFormatter.ofPattern("d MMMM yyyy", Locale.getDefault()))
}

/// How current the account grid is, in the same words the limit cards use.
/// Nil when the host never said, so the header shows the day count alone.
fun calendarFreshness(
    fetchedAtMs: Long?,
    noticeCode: String?,
    nowMillis: Long = System.currentTimeMillis(),
): Pair<String, Boolean>? {
    if (fetchedAtMs == null || fetchedAtMs <= 0) return null
    val ago = RelativeClock.label(fetchedAtMs, nowMillis)
    return if (noticeCode == "stale") "stale, last updated $ago" to true else "updated $ago" to false
}

/// The phone's year heatmap, a direct port of `PhoneHeatmap.swift`: fixed cell
/// size, horizontally scrolling grid opened on the most recent week, month
/// marks offset across the top, locked days muted, and hold-to-read with
/// lift-to-open detail.
///
/// Fitting 53 weeks to a phone width shrinks a day below anything a finger can
/// hit, which is why the Apple client scrolls the year too. The cell size is
/// deliberately not fitted to the width: a fitted cell makes the view measure
/// itself and drags every card on Home off the screen.
@Composable
fun YearHeatmap(
    rows: JsonArray,
    months: JsonArray,
    onSelectDay: (JsonObject) -> Unit,
    modifier: Modifier = Modifier,
    onScrub: (Boolean) -> Unit = {},
) {
    val colors = LocalTsColors.current
    val density = LocalDensity.current
    val haptic = LocalHapticFeedback.current
    val slopPx = LocalViewConfiguration.current.touchSlop
    val stepPx = with(density) { (cellSize + cellGap).toPx() }
    val cellPx = with(density) { cellSize.toPx() }
    val cornerPx = with(density) { cellCorner.toPx() }
    val weeks = ((rows.firstOrNull() as? JsonArray)?.size ?: rows.size).coerceAtLeast(1)
    val gridWidthDp = (cellSize + cellGap) * weeks - cellGap
    val scroll = rememberScrollState()

    // The activity ramp, with a quiet day that can actually be seen. Step
    // zero of the shared ramp all but vanishes on a white card at arm's
    // length, so the phone overrides it; the four active steps stay the
    // brand's own, like `PhoneHeatmap.heatPalette`.
    val heat = remember(colors) {
        colors.heat.toMutableList().also {
            it[0] = if (colors.isDark) Color(0xFF221E36) else Color(0xFFDEDAEA)
        }
    }

    // Open on the latest week, which is the part anybody wants first.
    // maxValue is zero until the grid has been laid out, so follow it.
    LaunchedEffect(rows) {
        snapshotFlow { scroll.maxValue }.collect { max ->
            if (max > 0 && scroll.value < max) scroll.scrollTo(max)
        }
    }

    var focus by remember { mutableStateOf<FocusCell?>(null) }
    var scrubbing by remember { mutableStateOf(false) }
    val focusAlpha by animateFloatAsState(
        targetValue = if (focus != null) 1f else 0f,
        animationSpec = tween(120),
        label = "heatmapFocus",
    )

    /// Which day a touch landed on, using the same packing the canvas drew
    /// with. Points between squares round to the square they are nearest, so
    /// a finger dragged across the grid never lands on nothing.
    fun hit(px: Float, py: Float): FocusCell? {
        val col = (px / stepPx).toInt()
        val row = (py / stepPx).toInt()
        if (row !in 0 until rows.size) return null
        val week = rows.getOrNull(row) as? JsonArray ?: return null
        if (col !in 0 until week.size) return null
        val day = week.getOrNull(col) as? JsonObject ?: return null
        if (day["locked"]?.jsonPrimitive?.booleanOrNull == true) return null
        return FocusCell(col, row, day)
    }

    Column(modifier, verticalArrangement = Arrangement.spacedBy(4.dp)) {
        // The line above the grid: what the finger is on, or how to use it.
        // The readout lives here rather than beside the square it names,
        // because a bubble by the cell is a bubble under the hand pointing
        // at it. Above the whole grid it is always visible, always in the
        // same place, and never behind a finger.
        AnimatedContent(
            targetState = focus?.day?.get("date")?.jsonPrimitive?.contentOrNull,
            transitionSpec = { fadeIn(tween(120)) togetherWith fadeOut(tween(120)) },
            label = "heatmapCaption",
        ) { focused ->
            Row(
                Modifier.height(18.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(6.dp),
            ) {
                val current = focus?.takeIf {
                    it.day["date"]?.jsonPrimitive?.contentOrNull == focused
                }
                if (current == null) {
                    Icon(
                        Icons.Outlined.TouchApp,
                        contentDescription = null,
                        modifier = Modifier.size(11.dp),
                        tint = colors.textTertiary,
                    )
                    Text(
                        "Swipe for the whole year, hold a day to read it",
                        style = TextStyle(fontSize = 11.sp, fontFamily = TsType.interfaceFamily),
                        color = colors.textTertiary,
                        maxLines = 1,
                    )
                } else {
                    val value = current.day["value"]?.jsonPrimitive?.longOrNull ?: 0L
                    Box(Modifier.size(7.dp).background(colors.accent, CircleShape))
                    Text(
                        shortDate(current.day["date"]?.jsonPrimitive?.contentOrNull.orEmpty()),
                        style = TextStyle(
                            fontSize = 13.sp,
                            fontWeight = FontWeight.SemiBold,
                            fontFamily = TsType.interfaceFamily,
                        ),
                        color = colors.textPrimary,
                        maxLines = 1,
                    )
                    Text(
                        if (value == 0L) "nothing recorded" else "${money(value)} at list rates",
                        style = TextStyle(fontSize = 12.sp, fontFamily = TsType.interfaceFamily),
                        color = colors.textSecondary,
                        maxLines = 1,
                    )
                }
            }
        }
        BoxWithConstraints(Modifier.fillMaxWidth()) {
            val fits = gutterWidth + 6.dp + gridWidthDp <= maxWidth
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = if (fits) Arrangement.Center else Arrangement.Start,
                verticalAlignment = Alignment.Top,
            ) {
                // Monday, Wednesday, Friday only. Seven letters at this size
                // is a column of noise beside the thing it labels.
                Column(
                    Modifier.width(gutterWidth),
                    verticalArrangement = Arrangement.spacedBy(cellGap),
                ) {
                    // Pushed down by the month row so the letters line up
                    // with the rows. The width matters: without it the clear
                    // spacer stretches across the card and squeezes the grid
                    // into what is left.
                    Spacer(Modifier.width(gutterWidth).height(monthRowHeight))
                    listOf("M", "", "W", "", "F", "", "").forEach { letter ->
                        Box(Modifier.height(cellSize), contentAlignment = Alignment.CenterStart) {
                            Text(
                                letter,
                                style = TextStyle(fontSize = 9.sp, fontFamily = TsType.interfaceFamily),
                                color = colors.textTertiary,
                            )
                        }
                    }
                }
                Spacer(Modifier.width(6.dp))
                Column(
                    Modifier
                        .then(if (fits) Modifier else Modifier.horizontalScroll(scroll, enabled = !scrubbing))
                        .padding(bottom = 6.dp),
                    verticalArrangement = Arrangement.spacedBy(6.dp),
                ) {
                    Box(Modifier.height(monthRowHeight).width(gridWidthDp)) {
                        months.forEach { month ->
                            // Objects from current hosts ({column, name}),
                            // arrays from older ones ([column, name]).
                            val column: Int?
                            val name: String?
                            when (month) {
                                is JsonObject -> {
                                    column = month["column"]?.jsonPrimitive?.intOrNull
                                    name = month["name"]?.jsonPrimitive?.contentOrNull
                                }
                                is JsonArray -> {
                                    column = month.firstOrNull()?.jsonPrimitive?.intOrNull
                                    name = month.getOrNull(1)?.jsonPrimitive?.contentOrNull
                                }
                                else -> {
                                    column = null
                                    name = null
                                }
                            }
                            if (column == null || name == null) return@forEach
                            Text(
                                name,
                                style = TextStyle(
                                    fontSize = 10.sp,
                                    fontWeight = FontWeight.Medium,
                                    fontFamily = TsType.interfaceFamily,
                                ),
                                color = colors.textSecondary,
                                modifier = Modifier.offset(x = (cellSize + cellGap) * column),
                            )
                        }
                    }
                    Canvas(
                        Modifier
                            .width(gridWidthDp)
                            .height((cellSize + cellGap) * 7 - cellGap)
                            .pointerInput(rows, stepPx) {
                                awaitEachGesture {
                                    val down = awaitFirstDown()
                                    // Phase one: wait up to 200ms for the
                                    // hold, watching for a lift or for the
                                    // finger wandering into a scroll. Nothing
                                    // is consumed here, so the grid keeps
                                    // scrolling under an ordinary drag.
                                    var liftedAt: Offset? = null
                                    var wandered = false
                                    withTimeoutOrNull(200) {
                                        while (true) {
                                            val event = awaitPointerEvent()
                                            val change = event.changes.first()
                                            if (!change.pressed) {
                                                liftedAt = change.position
                                                break
                                            }
                                            if ((change.position - down.position).getDistance() > slopPx) {
                                                wandered = true
                                                break
                                            }
                                        }
                                    }
                                    // A scroll owns the gesture from here.
                                    if (wandered) return@awaitEachGesture
                                    val lifted = liftedAt
                                    if (lifted != null) {
                                        // A quick tap opens the day it
                                        // landed on.
                                        hit(lifted.x, lifted.y)?.let { onSelectDay(it.day) }
                                    } else {
                                        // Held past 200ms: scrub until the
                                        // lift, then open the day named.
                                        try {
                                            scrubbing = true
                                            onScrub(true)
                                            var current = hit(down.position.x, down.position.y)
                                            focus = current
                                            haptic.performHapticFeedback(HapticFeedbackType.LongPress)
                                            var last = down.position
                                            while (true) {
                                                val event = awaitPointerEvent()
                                                val change = event.changes.first()
                                                change.consume()
                                                if (!change.pressed) {
                                                    last = change.position
                                                    break
                                                }
                                                if (change.position != last) {
                                                    last = change.position
                                                    val next = hit(last.x, last.y)
                                                    if (next != null && next.day != current?.day) {
                                                        current = next
                                                        focus = next
                                                        haptic.performHapticFeedback(
                                                            HapticFeedbackType.TextHandleMove,
                                                        )
                                                    }
                                                }
                                            }
                                            (hit(last.x, last.y) ?: current)?.let { onSelectDay(it.day) }
                                        } finally {
                                            scrubbing = false
                                            onScrub(false)
                                            focus = null
                                        }
                                    }
                                }
                            },
                    ) {
                        rows.forEachIndexed { rowIdx, row ->
                            val week = row as? JsonArray ?: return@forEachIndexed
                            week.forEachIndexed { col, day ->
                                if (day !is JsonObject) return@forEachIndexed
                                val level = (day["level"]?.jsonPrimitive?.intOrNull ?: fallbackLevel(day))
                                    .coerceIn(0, 4)
                                var paint = heat[level]
                                if (day["locked"]?.jsonPrimitive?.booleanOrNull == true) {
                                    paint = paint.copy(alpha = paint.alpha * 0.28f)
                                }
                                drawRoundRect(
                                    color = paint,
                                    topLeft = Offset(col * stepPx, rowIdx * stepPx),
                                    size = Size(cellPx, cellPx),
                                    cornerRadius = CornerRadius(cornerPx, cornerPx),
                                )
                            }
                        }
                        // The square under the finger, ringed in the accent.
                        focus?.let { (col, rowIdx, _) ->
                            val inset = with(density) { 2.dp.toPx() }
                            drawRoundRect(
                                color = colors.accent,
                                topLeft = Offset(col * stepPx - inset, rowIdx * stepPx - inset),
                                size = Size(cellPx + inset * 2, cellPx + inset * 2),
                                cornerRadius = CornerRadius(cornerPx + inset, cornerPx + inset),
                                style = Stroke(width = with(density) { 2.dp.toPx() }),
                                alpha = focusAlpha,
                            )
                        }
                    }
                }
            }
        }
    }
}

/// Quantile bands need the whole year, which an older host never sent, so a
/// cell without a level falls back to absolute spend. The bands only have to
/// be plausible: current hosts always send the real level.
private fun fallbackLevel(day: JsonObject): Int = when (val v = day["value"]?.jsonPrimitive?.longOrNull ?: 0L) {
    0L -> 0
    in 1..49_999 -> 1
    in 50_000..499_999 -> 2
    in 500_000..4_999_999 -> 3
    else -> 4
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
                spokenDate(day["date"]?.jsonPrimitive?.contentOrNull.orEmpty()),
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
