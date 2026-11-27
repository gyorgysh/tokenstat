// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.workspace

import ai.tokenstat.tokenstat.ui.localization.L10n

import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.lazy.LazyListScope
import androidx.compose.foundation.lazy.LazyListState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import ai.tokenstat.tokenstat.ui.components.ActionIcon
import ai.tokenstat.tokenstat.ui.components.TsAccentButton
import ai.tokenstat.tokenstat.ui.theme.Space

object TranscriptFollow {
    val thresholdDp = 56.dp
}

internal suspend fun LazyListState.scrollToTranscriptEnd() {
    val last = layoutInfo.totalItemsCount - 1
    if (last >= 0) scrollToItem(last)
}

internal fun LazyListScope.transcriptEnd() {
    item(key = "transcript-end") { Spacer(Modifier.height(1.dp)) }
}

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

class TranscriptFollowState {
    var pinned: Boolean = true
        private set
    var paused: Boolean by mutableStateOf(false)
        private set
    var showJump: Boolean by mutableStateOf(false)
        private set

    fun jump() {
        paused = false
        pinned = true
        showJump = false
    }

    fun pause() {
        paused = true
        pinned = false
    }

    fun stopFollowing() {
        pinned = false
        showJump = true
    }

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

@Composable
fun TranscriptFollowPill(
    pill: FollowPill,
    onResume: () -> Unit,
    onPause: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val label = when (pill) {
        FollowPill.JumpToLatest -> L10n.text("android.transcriptfollow.jump_to_latest.86752458")
        FollowPill.Follow -> L10n.text("android.transcriptfollow.follow.641d1ef6")
        FollowPill.Following -> L10n.text("android.transcriptfollow.following.344b4271")
    }
    TsAccentButton(
        label = label,
        onClick = { if (pill == FollowPill.Following) onPause() else onResume() },
        icon = ActionIcon.Latest.vector,
        small = true,
        modifier = modifier.padding(bottom = Space.s),
    )
}
