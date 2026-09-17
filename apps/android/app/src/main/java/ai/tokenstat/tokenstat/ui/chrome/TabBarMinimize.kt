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

/// Holds whether the floating tab bar is minimised to its corner pill.
/// Hoisted above the tab screens and the bar itself: the screens report
/// scrolls through `rememberTabBarMinimizeScroll`, and the bar reads
/// `minimized`. Reset on tab switches by the host, so a new tab never
/// opens on a pill.
class TabBarMinimizeState {
    var minimized by mutableStateOf(false)

    /// Downward travel banked toward the next minimise. Plain, not state:
    /// only the flip recomposes.
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

/// A nested scroll connection that minimises the tab bar after a longer
/// scroll down and expands it at the top of the list, like the iOS 26
/// floating bar. Attached to each tab screen's scrollable root with
/// `Modifier.nestedScroll(...)`. Scroll deltas inside the touch slop hold
/// the state, and nothing is ever consumed: the list keeps every pixel of
/// its own scroll.
///
/// The top is read from what the list leaves unconsumed, so the screens
/// report nothing but their scrolls: an upward move the list cannot take
/// means there is no more list above, and a fling that arrives with upward
/// velocity to spare landed on the first row.
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
                // `available.y` is negative when the content moves up under
                // a finger moving up, which is a scroll down the page. The
                // top is not known yet: that arrives post-scroll, below.
                state.update(TabBarVisibility.next(
                    state.minimized, state.travelPx, -available.y, slop, thresholdPx, atTop = false,
                ))
                return Offset.Zero
            }

            override fun onPostScroll(consumed: Offset, available: Offset, source: NestedScrollSource): Offset {
                // Upward scroll the list could not take: the first row is
                // showing, so the bar comes back.
                if (available.y > slop) state.expand()
                return Offset.Zero
            }

            override suspend fun onPostFling(consumed: Velocity, available: Velocity): Velocity {
                // An upward fling with velocity to spare hit the top.
                if (available.y > 0f) state.expand()
                return Velocity.Zero
            }
        }
    }
}
