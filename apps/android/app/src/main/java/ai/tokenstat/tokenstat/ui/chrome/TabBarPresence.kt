// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.chrome

import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.Stable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.setValue
import androidx.compose.runtime.staticCompositionLocalOf

/// Whether the floating bar is on the screen at all.
///
/// Minimising and hiding are different things and the app needs both.
/// Minimising is the scroll behaviour: the bar banks travel and shrinks to
/// its corner pill, and a tap brings it back. Hiding is the push behaviour:
/// a conversation is not a tab, so while one is open the bar is gone and
/// Back is the way out. `TabBarMinimizeState` owns the first; this owns the
/// second.
///
/// Claims are counted rather than a flag, for the same reason the Apple
/// client's `ClientHiddenTabBar` restores only what it hid: two screens can
/// both want the bar gone, and the outer one leaving must not put it back
/// underneath the inner one.
@Stable
class TabBarPresence {
    private var barClaims by mutableIntStateOf(0)
    private var topClaims by mutableIntStateOf(0)
    private var sectionClaims by mutableIntStateOf(0)

    val hidden: Boolean get() = barClaims > 0

    /// The app's own toolbar, the avatar and wordmark row. A pushed screen
    /// brings its own header, and the Apple clients replace the toolbar
    /// rather than stacking a second one under it.
    val topHidden: Boolean get() = topClaims > 0

    internal fun claim() {
        barClaims += 1
    }

    internal fun release() {
        barClaims = (barClaims - 1).coerceAtLeast(0)
    }

    /// The pushed section's own header row. A screen inside a section can
    /// take it over when it has a better title to show than the section's
    /// name, rather than stacking a second header underneath it.
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

/// Take the bar off the screen for as long as this is in the composition,
/// and put it back on the way out.
///
/// Tied to the composition rather than to an event, so every way out of a
/// screen restores it: Back, a gesture, a tab change underneath, or the
/// screen being torn down by a reconnect. There is no path that forgets.
@Composable
fun HideTabBar(active: Boolean = true) {
    val presence = LocalTabBarPresence.current
    DisposableEffect(presence, active) {
        if (active) presence.claim()
        onDispose { if (active) presence.release() }
    }
}

/// Put the app toolbar away while a pushed screen owns the header.
///
/// A folder, and everything inside it, is a push: it has a back button, a
/// title and its own actions. Leaving the avatar and wordmark above that
/// gave those screens two headers and cost about a fifth of the display for
/// chrome nobody uses from in there.
@Composable
fun HideTopBar(active: Boolean = true) {
    val presence = LocalTabBarPresence.current
    DisposableEffect(presence, active) {
        if (active) presence.claimTop()
        onDispose { if (active) presence.releaseTop() }
    }
}

/// Take over the section header, because this screen has the better title.
///
/// A conversation knows its own name; the section above it only knows it is
/// "Chat". Stacking both gave the screen two back arrows and two titles.
@Composable
fun OwnSectionHeader(active: Boolean = true) {
    val presence = LocalTabBarPresence.current
    DisposableEffect(presence, active) {
        if (active) presence.claimSection()
        onDispose { if (active) presence.releaseSection() }
    }
}
