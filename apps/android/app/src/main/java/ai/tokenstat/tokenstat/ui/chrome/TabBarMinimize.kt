// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.chrome

import ai.tokenstat.tokenstat.ui.logic.TabBarVisibility
import android.view.ViewConfiguration
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.input.nestedscroll.NestedScrollConnection
import androidx.compose.ui.input.nestedscroll.NestedScrollSource
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.unit.Velocity
import androidx.compose.ui.unit.dp

class TabBarMinimizeState {
    var minimized by mutableStateOf(false)

    var travelPx: Float = 0f

    fun update(step: TabBarVisibility.Step) {
        minimized = step.minimized
        travelPx = step.travelPx
    }

    fun expand() {
        minimized = false
        travelPx = 0f
    }
}

@Composable
fun rememberTabBarMinimizeState(): TabBarMinimizeState = remember { TabBarMinimizeState() }

@Composable
fun rememberTabBarMinimizeScroll(state: TabBarMinimizeState): NestedScrollConnection {
    val context = LocalContext.current
    val slop = remember(context) { ViewConfiguration.get(context).scaledTouchSlop.toFloat() }
    val density = LocalDensity.current
    val thresholdPx = remember(density) {
        with(density) { TabBarVisibility.minimizeAfterDp.dp.toPx() }
    }
    return remember(state, slop, thresholdPx) {
        object : NestedScrollConnection {
            override fun onPreScroll(available: Offset, source: NestedScrollSource): Offset {
                state.update(TabBarVisibility.next(
                    state.minimized, state.travelPx, -available.y, slop, thresholdPx, atTop = false,
                ))
                return Offset.Zero
            }

            override fun onPostScroll(consumed: Offset, available: Offset, source: NestedScrollSource): Offset {
                if (available.y > slop) state.expand()
                return Offset.Zero
            }

            override suspend fun onPostFling(consumed: Velocity, available: Velocity): Velocity {
                if (available.y > 0f) state.expand()
                return Velocity.Zero
            }
        }
    }
}
