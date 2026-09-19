// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.components

import androidx.compose.material3.LocalTextStyle
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.TextStyle
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import ai.tokenstat.tokenstat.ui.logic.RelativeClock
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.flow.collectLatest

/// One clock for every relative time on screen, port of Apple's
/// `RelativeTimeText.swift`.
///
/// A per-row timer would wake each row on its own schedule; named relative
/// text only moves at minute boundaries, so one shared tick at a granularity
/// the words actually have (15 seconds, like the Apple client) costs one
/// recomposition per visible row every fifteen seconds instead of one per
/// frame per row.
object RelativeTick {
    /// Coarse on purpose: the phrasing this drives moves at minute
    /// boundaries, and anything finer buys nothing but wake-ups.
    const val TICK_MILLIS = 15_000L

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    private val current = MutableStateFlow(System.currentTimeMillis())

    /// The shared tick. Reading this inside composition subscribes the caller,
    /// so a text formatted against it stays current without owning a timer.
    val now: StateFlow<Long> = current.asStateFlow()

    @Volatile
    private var started = false

    /// Starts the shared ticker once. Cheap to call from every row; only the
    /// first call does anything.
    fun start() {
        if (started) return
        synchronized(this) {
            if (started) return
            started = true
            scope.launch {
                current.subscriptionCount.collectLatest { subscribers ->
                    if (subscribers == 0) return@collectLatest
                    while (true) {
                        current.value = System.currentTimeMillis()
                        delay(TICK_MILLIS)
                    }
                }
            }
        }
    }
}

/// Relative time ("3m ago"), current to within a tick, without a per-row
/// timer. Use this wherever the app shows a relative time; a phrase built
/// with `RelativeClock.label` anywhere else is a snapshot that never updates.
@Composable
fun RelativeTimeText(
    epochMillis: Long,
    modifier: Modifier = Modifier,
    style: TextStyle = LocalTextStyle.current,
    color: Color = Color.Unspecified,
    /// "4h ago" instead of "4 hours ago", for a row that is already carrying
    /// a title and an agent name and has no width to spare.
    compact: Boolean = false,
) {
    RelativeTick.start()
    val now by RelativeTick.now.collectAsStateWithLifecycle()
    val text = if (compact) RelativeClock.compact(epochMillis, now) else RelativeClock.label(epochMillis, now)
    Text(text, modifier, color = color, style = style)
}
