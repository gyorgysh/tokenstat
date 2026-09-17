// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.workspace

import androidx.compose.foundation.layout.padding
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import ai.tokenstat.tokenstat.ui.components.ActionIcon
import ai.tokenstat.tokenstat.ui.components.TsAccentButton
import ai.tokenstat.tokenstat.ui.theme.Space

/// How a transcript stays with the latest turn, ported from
/// `TranscriptFollow.swift`. Same three states, same rule: content growth
/// must never unpin the view, only the reader's own scroll may.
object TranscriptFollow {
    /// How far from the bottom counts as "still with the conversation".
    val thresholdDp = 56.dp
}

/// Whether the end is under the viewport, from a lazy list's visible items.
///
/// Pure so the boundary is testable: [lastVisibleIndex] null (nothing laid
/// out yet) is not the end, an empty list is, and anything past the last
/// item within [thresholdPx] still counts.
fun isAtBottom(
    lastVisibleIndex: Int?,
    totalItems: Int,
    distancePx: Int,
    thresholdPx: Float,
): Boolean {
    if (totalItems == 0) return true
    if (lastVisibleIndex == null || lastVisibleIndex < totalItems - 1) return false
    return distancePx <= thresholdPx
}

/// Which follow control the transcript offers, if any. Same seats as the
/// Apple pill: Jump to latest when scrolled away, Follow/Following while a
/// turn is live, nothing when idle and pinned.
enum class FollowPill {
    JumpToLatest,
    Follow,
    Following,
}

fun pillFor(showJump: Boolean, busy: Boolean, paused: Boolean): FollowPill? =
    when {
        showJump -> FollowPill.JumpToLatest
        busy && paused -> FollowPill.Follow
        busy -> FollowPill.Following
        else -> null
    }

/// Whether the viewport is still following the bottom.
///
/// `showJump` and `paused` are the only observed fields: both change on
/// transitions, never per frame, so a scroll does not redraw the transcript
/// to report its offset. Everything else is read by effects, not drawn.
class TranscriptFollowState {
    var pinned: Boolean = true
        private set
    var paused: Boolean by mutableStateOf(false)
        private set
    var showJump: Boolean by mutableStateOf(false)
        private set

    /// Back to the latest turn, from the pill or a send. Sending is
    /// engaging: follow is the default, so a new turn resumes it.
    fun jump() {
        paused = false
        pinned = true
        showJump = false
    }

    /// Stop following by hand, from the Following pill. The button state is
    /// left alone: if the end drifts away the scroll callback offers Jump to
    /// latest on its own.
    fun pause() {
        paused = true
        pinned = false
    }

    /// Stop following the end and offer the way back.
    fun stopFollowing() {
        pinned = false
        showJump = true
    }

    /// One position report from the list.
    ///
    /// Growth nobody scrolled for must not unpin the view: a stream that
    /// unpinned itself would stall mid-screen. Only a scroll of one's own
    /// away from the end releases the pin, and only a scroll of one's own
    /// back onto it clears a manual pause, so pausing at the bottom sticks.
    fun note(atBottom: Boolean, userScroll: Boolean) {
        if (atBottom) {
            if (userScroll) paused = false
            if (!paused) {
                pinned = true
                showJump = false
            }
        } else {
            if (userScroll) {
                pinned = false
                showJump = true
            } else if (!pinned) {
                showJump = true
            }
        }
    }

    fun pill(busy: Boolean): FollowPill? = pillFor(showJump, busy, paused)
}

/// The follow control at the bottom of a transcript. The caller seats it
/// over the list. All three states share one capsule and a down arrow, so
/// the control does not change language when the state does.
@Composable
fun TranscriptFollowPill(
    pill: FollowPill,
    onResume: () -> Unit,
    onPause: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val label = when (pill) {
        FollowPill.JumpToLatest -> "Jump to latest"
        FollowPill.Follow -> "Follow"
        FollowPill.Following -> "Following"
    }
    TsAccentButton(
        label = label,
        onClick = { if (pill == FollowPill.Following) onPause() else onResume() },
        icon = ActionIcon.Latest.vector,
        small = true,
        modifier = modifier.padding(bottom = Space.s),
    )
}
