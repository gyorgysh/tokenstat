// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.logic

/// Cold-start splash timing, ported from `LaunchState` and `ClientRootView`
/// in the Apple client: the splash never flashes for a single frame, and it
/// leaves with the same fade as the other door changes.
object SplashHold {
    /// Shortest the splash stays on screen, so a hot start is not a
    /// one-frame flash. Apple: `LaunchState.minimumSplash`, 560ms.
    const val minimumMs = 560L

    /// The splash exit fade. Apple: the `.opacity` door transition over
    /// easeInOut 0.28, the same `doorMillis` the app doors use.
    const val exitMs = 280L

    /// Whether the system splash must stay up `elapsedMs` after launch.
    fun hold(elapsedMs: Long): Boolean = elapsedMs < minimumMs
}

/// The floating tab bar minimise rule, matching the iOS 26 system bar: a
/// short scroll leaves it alone, a longer scroll down shrinks it to its
/// corner pill, and it comes back at the top of the list or on a tap, never
/// mid-list. Pure so both the nested-scroll helper and unit tests answer
/// identically.
object TabBarVisibility {
    /// Downward travel before the bar minimises. The call site converts to
    /// pixels; the rule only ever sees the converted threshold.
    const val minimizeAfterDp = 64

    /// The bar after one scroll delta: whether it is minimised, and the
    /// downward travel it has banked toward the next minimise.
    data class Step(val minimized: Boolean, val travelPx: Float)

    /// The bar after a scroll delta. `scrolledDownPx` is positive when the
    /// content moves up under a finger moving up (a scroll down the page).
    /// Deltas inside the touch slop hold the state, so a tap or a resting
    /// finger never flips the bar. `atTop` is true when the list had nothing
    /// left to scroll up, which is the only upward move that expands.
    fun next(
        minimized: Boolean,
        travelPx: Float,
        scrolledDownPx: Float,
        slopPx: Float,
        thresholdPx: Float,
        atTop: Boolean,
    ): Step = when {
        scrolledDownPx > slopPx -> {
            val travel = travelPx + scrolledDownPx
            Step(minimized || travel > thresholdPx, travel)
        }
        scrolledDownPx < -slopPx -> Step(minimized && !atTop, 0f)
        else -> Step(minimized, travelPx)
    }
}
