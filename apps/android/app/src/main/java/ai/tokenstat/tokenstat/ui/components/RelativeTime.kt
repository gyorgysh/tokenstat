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

object RelativeTick {
    const val TICK_MILLIS = 15_000L

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    private val current = MutableStateFlow(System.currentTimeMillis())

    val now: StateFlow<Long> = current.asStateFlow()

    @Volatile
    private var started = false

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

@Composable
fun RelativeTimeText(
    epochMillis: Long,
    modifier: Modifier = Modifier,
    style: TextStyle = LocalTextStyle.current,
    color: Color = Color.Unspecified,
    compact: Boolean = false,
) {
    RelativeTick.start()
    val now by RelativeTick.now.collectAsStateWithLifecycle()
    val text = if (compact) RelativeClock.compact(epochMillis, now) else RelativeClock.label(epochMillis, now)
    Text(text, modifier, color = color, style = style)
}
