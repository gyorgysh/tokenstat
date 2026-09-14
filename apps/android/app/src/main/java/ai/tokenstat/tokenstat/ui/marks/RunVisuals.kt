// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.marks

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import ai.tokenstat.tokenstat.ui.theme.LocalTsColors
import ai.tokenstat.tokenstat.ui.theme.TsColors
import java.util.Locale

/// What a run's status looks like, in one place. Port of `RunVisuals.swift`:
/// the Apple client's Automations and Workflows screens each carried their own
/// copy of this switch, which is how one status ended up two colours. Both
/// entry points now call through here, and so does this one.
object RunOutcome {
    fun tint(status: String, colors: TsColors): Color = when (status) {
        "running", "queued" -> colors.stateWorking
        "waiting" -> colors.warning
        "ok" -> colors.success
        "stopped" -> colors.warning
        "error" -> colors.danger
        "interrupted" -> colors.warning
        else -> colors.stateIdle
    }
}

/// One past run on the strip. Oldest first; the strip trims the front.
data class RunTick(val id: String, val status: String, val label: String)

/// Slots always drawn, so the strip reads as a track that is filling up.
/// Two amber ticks on their own are a pause glyph; empty slots behind them
/// give the filled ones something to be part of.
const val RUN_HISTORY_SLOTS = 8

/// The ticks actually shown: the newest `limit` at most. A bad limit shows an
/// empty strip rather than crashing, like the Apple client's `max(0, limit)`.
fun visibleRunTicks(ticks: List<RunTick>, limit: Int = RUN_HISTORY_SLOTS): List<RunTick> {
    val cap = maxOf(0, limit)
    return if (ticks.size > cap) ticks.takeLast(cap) else ticks
}

fun runStripSummary(shown: List<RunTick>): String {
    if (shown.isEmpty()) return "Never run"
    val failed = shown.count { it.status == "error" }
    if (failed == 0) return "Last ${shown.size} runs, none failed"
    return "Last ${shown.size} runs, $failed failed"
}

/// The last handful of outcomes as ticks, newest on the right. A job whose
/// last three runs failed should look wrong from across the room.
@Composable
fun RunHistoryStrip(
    ticks: List<RunTick>,
    modifier: Modifier = Modifier,
    limit: Int = RUN_HISTORY_SLOTS,
    tickWidth: Dp = 4.dp,
    tickHeight: Dp = 14.dp,
    onSelect: ((RunTick) -> Unit)? = null,
) {
    val colors = LocalTsColors.current
    val shown = visibleRunTicks(ticks, limit)
    val pill = RoundedCornerShape(50)
    Row(
        modifier.semantics { contentDescription = runStripSummary(shown) },
        horizontalArrangement = Arrangement.spacedBy(2.dp),
    ) {
        repeat(maxOf(0, RUN_HISTORY_SLOTS - shown.size)) {
            Box(
                Modifier
                    .size(tickWidth, tickHeight)
                    .clip(pill)
                    .background(colors.border.copy(alpha = 0.5f)),
            )
        }
        shown.forEach { tick ->
            val tickModifier = Modifier
                .size(tickWidth, tickHeight)
                .clip(pill)
                .background(RunOutcome.tint(tick.status, colors).let {
                    if (tick.status == "ok") it.copy(alpha = 0.85f) else it
                })
            Box(
                if (onSelect != null) tickModifier.clickable { onSelect(tick) } else tickModifier,
            )
        }
    }
}

/// How long a run took, relative to the longest one beside it. Deliberately
/// relative rather than absolute: the question a list of runs answers is
/// "which of these was the long one", not "how many seconds".
fun durationFraction(seconds: Double, longest: Double): Double {
    if (longest <= 0 || seconds <= 0) return 0.0
    return minOf(1.0, maxOf(0.06, seconds / longest))
}

fun durationLabel(seconds: Double): String {
    if (seconds <= 0) return "Still running"
    if (seconds < 60) return "Took ${seconds.toInt()}s"
    if (seconds < 3600) return "Took ${(seconds / 60).toInt()}m"
    return "Took ${"%.1f".format(Locale.US, seconds / 3600)}h"
}

@Composable
fun DurationBar(
    seconds: Double,
    longest: Double,
    modifier: Modifier = Modifier,
    width: Dp = 44.dp,
    height: Dp = 4.dp,
) {
    val colors = LocalTsColors.current
    val pill = RoundedCornerShape(50)
    val label = durationLabel(seconds)
    Box(
        modifier
            .size(width, height)
            .semantics { contentDescription = label },
    ) {
        Box(
            Modifier
                .fillMaxSize()
                .clip(pill)
                .background(colors.border),
        )
        Box(
            Modifier
                .fillMaxHeight()
                .fillMaxWidth(durationFraction(seconds, longest).toFloat())
                .clip(pill)
                .background(colors.accent.copy(alpha = 0.7f)),
        )
    }
}
