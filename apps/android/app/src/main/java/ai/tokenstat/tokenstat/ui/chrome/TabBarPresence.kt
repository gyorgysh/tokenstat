// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.chrome

import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.Stable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.setValue
import androidx.compose.runtime.staticCompositionLocalOf

@Stable
class TabBarPresence {
    private var barClaims by mutableIntStateOf(0)
    private var topClaims by mutableIntStateOf(0)
    private var sectionClaims by mutableIntStateOf(0)

    val hidden: Boolean get() = barClaims > 0

    val topHidden: Boolean get() = topClaims > 0

    internal fun claim() {
        barClaims += 1
    }

    internal fun release() {
        barClaims = (barClaims - 1).coerceAtLeast(0)
    }

    val sectionHeaderHidden: Boolean get() = sectionClaims > 0

    internal fun claimSection() {
        sectionClaims += 1
    }

    internal fun releaseSection() {
        sectionClaims = (sectionClaims - 1).coerceAtLeast(0)
    }

    internal fun claimTop() {
        topClaims += 1
    }

    internal fun releaseTop() {
        topClaims = (topClaims - 1).coerceAtLeast(0)
    }
}

val LocalTabBarPresence = staticCompositionLocalOf { TabBarPresence() }

@Composable
fun HideTabBar(active: Boolean = true) {
    val presence = LocalTabBarPresence.current
    DisposableEffect(presence, active) {
        if (active) presence.claim()
        onDispose { if (active) presence.release() }
    }
}

@Composable
fun HideTopBar(active: Boolean = true) {
    val presence = LocalTabBarPresence.current
    DisposableEffect(presence, active) {
        if (active) presence.claimTop()
        onDispose { if (active) presence.releaseTop() }
    }
}

@Composable
fun OwnSectionHeader(active: Boolean = true) {
    val presence = LocalTabBarPresence.current
    DisposableEffect(presence, active) {
        if (active) presence.claimSection()
        onDispose { if (active) presence.releaseSection() }
    }
}
