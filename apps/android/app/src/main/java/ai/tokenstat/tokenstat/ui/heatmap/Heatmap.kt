// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.heatmap

import ai.tokenstat.tokenstat.ui.components.TsBottomSheet
import ai.tokenstat.tokenstat.ui.localization.L10n

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
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.TouchApp
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
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
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import ai.tokenstat.tokenstat.core.CoreClient
import ai.tokenstat.tokenstat.ui.components.TsSecondaryButton
import ai.tokenstat.tokenstat.ui.components.SkeletonRows
import ai.tokenstat.tokenstat.ui.components.TsType
import ai.tokenstat.tokenstat.ui.components.tsPanel
import ai.tokenstat.tokenstat.ui.logic.RelativeClock
import ai.tokenstat.tokenstat.ui.logic.compactTokens
import ai.tokenstat.tokenstat.ui.logic.harnessName
import ai.tokenstat.tokenstat.ui.logic.money
import ai.tokenstat.tokenstat.ui.marks.HarnessMark
import ai.tokenstat.tokenstat.ui.theme.LocalTsColors
import ai.tokenstat.tokenstat.ui.theme.Space
import ai.tokenstat.tokenstat.ui.theme.TsColors
import java.text.NumberFormat
import java.time.LocalDate
import java.time.format.DateTimeFormatter
import java.util.Locale
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.withTimeoutOrNull
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.longOrNull
import kotlinx.serialization.json.put

private val cellSize = 15.dp
private val cellGap = 3.5.dp
private val cellCorner = 3.dp
private val gutterWidth = 16.dp
private val monthRowHeight = 13.dp

private data class FocusCell(val col: Int, val row: Int, val day: JsonObject)

fun shortDate(iso: String, today: LocalDate = LocalDate.now()): String {
    val date = runCatching { LocalDate.parse(iso) }.getOrNull() ?: return iso
    val pattern = if (date.year == today.year) "d MMMM" else "d MMMM yyyy"
    return date.format(DateTimeFormatter.ofPattern(pattern, Locale.getDefault()))
}

fun spokenDate(iso: String): String {
    val date = runCatching { LocalDate.parse(iso) }.getOrNull() ?: return iso
    return date.format(DateTimeFormatter.ofPattern("d MMMM yyyy", Locale.getDefault()))
}

fun calendarFreshness(
    fetchedAtMs: Long?,
    noticeCode: String?,
    nowMillis: Long = System.currentTimeMillis(),
): Pair<String, Boolean>? {
    if (fetchedAtMs == null || fetchedAtMs <= 0) return null
    val ago = RelativeClock.label(fetchedAtMs, nowMillis)
    return if (noticeCode == "stale") "stale, last updated $ago" to true else "updated $ago" to false
}

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

    val heat = remember(colors) { phoneHeat(colors) }

    val fallbackScale = remember(rows) {
        heatFallbackScale(
            rows.flatMap { row ->
                (row as? JsonArray).orEmpty().mapNotNull { day ->
                    (day as? JsonObject)?.get("value")?.jsonPrimitive?.longOrNull
                }
            },
        )
    }

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
                        L10n.text("android.heatmap.swipe_for_the_whole_year_hold_a_day_to_rea.90159e22"),
                        style = TextStyle(fontSize = 11.sp, fontFamily = TsType.interfaceFamily),
                        color = colors.textTertiary,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
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
                        overflow = TextOverflow.Ellipsis,
                    )
                    Text(
                        if (value == 0L) L10n.text("android.heatmap.nothing_recorded.ef5e03f6") else L10n.text("android.heatmap.0_at_api_list_price.1faebace", "${money(value)}"),
                        style = TextStyle(fontSize = 12.sp, fontFamily = TsType.interfaceFamily),
                        color = colors.textSecondary,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
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
                Column(
                    Modifier.width(gutterWidth),
                    verticalArrangement = Arrangement.spacedBy(cellGap),
                ) {
                    Spacer(Modifier.width(gutterWidth).height(monthRowHeight))
                    listOf(L10n.text("android.heatmap.m.08f27188"), L10n.text("android.heatmap..e3b0c442"), L10n.text("android.heatmap.w.fcb5f40d"), L10n.text("android.heatmap..e3b0c442"), L10n.text("android.heatmap.f.f67ab10a"), L10n.text("android.heatmap..e3b0c442"), L10n.text("android.heatmap..e3b0c442")).forEach { letter ->
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
                                    if (wandered) return@awaitEachGesture
                                    val lifted = liftedAt
                                    if (lifted != null) {
                                        hit(lifted.x, lifted.y)?.let { onSelectDay(it.day) }
                                    } else {
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
                                val value = day["value"]?.jsonPrimitive?.longOrNull ?: 0L
                                val level = (day["level"]?.jsonPrimitive?.intOrNull ?: fallbackLevel(value, fallbackScale))
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

sealed interface HeatFallbackScale {
    data class Quartiles(val breaks: List<Long>) : HeatFallbackScale
    data class MaxRatio(val max: Long) : HeatFallbackScale
    data object Empty : HeatFallbackScale
}

fun heatFallbackScale(values: List<Long>): HeatFallbackScale {
    val active = values.filter { it > 0 }.sorted()
    if (active.isEmpty()) return HeatFallbackScale.Empty
    if (active.size < 4) return HeatFallbackScale.MaxRatio(active.last())
    fun at(q: Double): Long {
        val rank = kotlin.math.ceil(active.size * q).toInt()
        return active[(rank - 1).coerceIn(0, active.lastIndex)]
    }
    return HeatFallbackScale.Quartiles(listOf(at(0.25), at(0.5), at(0.75)))
}

fun fallbackLevel(value: Long, scale: HeatFallbackScale): Int {
    if (value <= 0) return 0
    return when (scale) {
        HeatFallbackScale.Empty -> 1
        is HeatFallbackScale.Quartiles -> {
            val i = scale.breaks.indexOfFirst { value <= it }
            if (i >= 0) i + 1 else 4
        }
        is HeatFallbackScale.MaxRatio -> {
            if (scale.max <= 0) return 1
            val ratio = value.toDouble() / scale.max
            when {
                ratio <= 0.25 -> 1
                ratio <= 0.5 -> 2
                ratio <= 0.75 -> 3
                else -> 4
            }
        }
    }
}

fun phoneHeat(colors: TsColors): List<Color> =
    if (colors.ownsHeat) colors.heat else colors.heat.toMutableList().also {
        it[0] = if (colors.isDark) Color(0xFF221E36) else Color(0xFFDEDAEA)
    }

fun dayDetailParams(date: String): JsonObject = buildJsonObject {
    put("date", date)
    put("weeks", 53)
    put("scope", "account")
}

fun groupedCount(count: Long): String =
    NumberFormat.getIntegerInstance(Locale.getDefault()).format(count)

fun dayTotalsLine(events: Long, tokens: Long): String =
    L10n.text("android.heatmap.0_events_1_tokens.e35a47c3", "${events}", "${groupedCount(tokens)}")

fun dayPartRows(detail: JsonObject?): List<JsonObject> =
    (detail?.get("rows") as? JsonArray).orEmpty().mapNotNull { it as? JsonObject }

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun DayDetailSheet(day: JsonObject?, onDismiss: () -> Unit) {
    if (day == null) return
    val colors = LocalTsColors.current
    val date = day["date"]?.jsonPrimitive?.contentOrNull.orEmpty()
    val locked = day["locked"]?.jsonPrimitive?.booleanOrNull == true
    var detail by remember(date) { mutableStateOf<JsonObject?>(null) }
    var isLoading by remember(date) { mutableStateOf(!locked) }
    var failed by remember(date) { mutableStateOf(false) }
    var reload by remember(date) { mutableStateOf(0) }
    LaunchedEffect(date, locked, reload) {
        if (locked) { isLoading = false; return@LaunchedEffect }
        isLoading = true
        failed = false
        try {
            detail = CoreClient.call("activity.day", dayDetailParams(date)) as? JsonObject
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            failed = true
        } finally {
            isLoading = false
        }
    }
    TsBottomSheet(onDismissRequest = onDismiss, containerColor = colors.background) {
        Column(
            Modifier
                .fillMaxWidth()
                .verticalScroll(rememberScrollState())
                .padding(horizontal = Space.m)
                .padding(bottom = Space.xl),
            verticalArrangement = Arrangement.spacedBy(Space.m),
        ) {
            Text(spokenDate(date), style = TsType.headline, color = colors.textPrimary)
            DayDetailHeader(day, detail)
            if (locked) {
                Text(
                    L10n.text("android.heatmap.locked_history_shows_the_shape_of_the_year.57d209fc"),
                    style = TsType.subheadline,
                    color = colors.textSecondary,
                )
            } else if (isLoading) {
                SkeletonRows(count = 2)
            } else if (failed) {
                Text(L10n.text("android.heatmap.detail_unavailable"), color = colors.danger)
                TsSecondaryButton(label = L10n.text("common.retry"), onClick = { reload += 1 })
            } else {
                val rows = dayPartRows(detail)
                if (rows.isEmpty()) {
                    Text(
                        L10n.text("android.heatmap.nothing_recorded_on_this_day.5ad77ba8"),
                        style = TsType.subheadline,
                        color = colors.textSecondary,
                        modifier = Modifier.fillMaxWidth(),
                    )
                } else {
                    rows.forEach { DayPartRow(it) }
                }
            }
        }
    }
}

@Composable
private fun DayDetailHeader(day: JsonObject, detail: JsonObject?) {
    val colors = LocalTsColors.current
    val value = day["value"]?.jsonPrimitive?.longOrNull ?: 0L
    Column(
        Modifier.semantics(mergeDescendants = true) {},
        verticalArrangement = Arrangement.spacedBy(2.dp),
    ) {
        Text(money(value), style = TsType.numeric(34, FontWeight.SemiBold), color = colors.accent)
        Text(L10n.text("android.heatmap.at_api_list_price.128de85c"), style = TsType.caption, color = colors.textSecondary)
        if (detail != null) {
            val events = detail["events"]?.jsonPrimitive?.longOrNull ?: 0L
            val tokens = detail["tokens"]?.jsonPrimitive?.longOrNull ?: 0L
            Text(
                dayTotalsLine(events, tokens),
                style = TsType.caption,
                color = colors.textSecondary,
                modifier = Modifier.padding(top = 2.dp),
            )
        }
    }
}

@Composable
private fun DayPartRow(row: JsonObject) {
    val colors = LocalTsColors.current
    val model = row["model"]?.jsonPrimitive?.contentOrNull.orEmpty()
    val src = row["src"]?.jsonPrimitive?.contentOrNull.orEmpty()
    val tokens = row["tokens"]?.jsonPrimitive?.longOrNull ?: 0L
    Row(
        Modifier
            .fillMaxWidth()
            .semantics(mergeDescendants = true) {
                contentDescription = L10n.text("android.heatmap.0_on_1_2_tokens.2b7237a6", "${model}", "${harnessName(src)}", "${compactTokens(tokens)}")
            }
            .tsPanel()
            .padding(Space.s)
            .heightIn(min = 44.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(Space.s),
    ) {
        HarnessMark(id = src, size = 26.dp)
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(1.dp)) {
            Text(
                model,
                style = TsType.subheadline.copy(fontWeight = FontWeight.Medium),
                color = colors.textPrimary,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            Text(harnessName(src), style = TsType.caption, color = colors.textSecondary)
        }
        Text(compactTokens(tokens), style = TsType.numeric(16), color = colors.textSecondary)
    }
}
