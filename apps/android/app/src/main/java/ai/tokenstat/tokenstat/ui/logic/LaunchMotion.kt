// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.logic

object SplashHold {
    const val minimumMs = 560L

    const val exitMs = 280L

    fun hold(elapsedMs: Long): Boolean = elapsedMs < minimumMs
}

object TabBarVisibility {
    const val minimizeAfterDp = 64

    data class Step(val minimized: Boolean, val travelPx: Float)

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
