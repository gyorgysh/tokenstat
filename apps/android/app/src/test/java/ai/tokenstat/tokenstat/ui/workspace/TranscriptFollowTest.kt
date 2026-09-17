// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.workspace

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class TranscriptFollowTest {
    @Test
    fun `a conversation opens pinned with no pill`() {
        val follow = TranscriptFollowState()
        assertTrue(follow.pinned)
        assertFalse(follow.paused)
        assertFalse(follow.showJump)
        assertNull(follow.pill(busy = false))
    }

    @Test
    fun `growth nobody scrolled for never unpins`() {
        val follow = TranscriptFollowState()
        // A streaming turn pushes the end away for hundreds of frames while
        // the viewport sits still. Unpinning here is what would stall a reply
        // mid-screen behind Jump to latest.
        repeat(10) { follow.note(atBottom = false, userScroll = false) }
        assertTrue(follow.pinned)
        assertFalse(follow.showJump)
    }

    @Test
    fun `the reader scrolling away unpins and offers the way back`() {
        val follow = TranscriptFollowState()
        follow.note(atBottom = false, userScroll = true)
        assertFalse(follow.pinned)
        assertTrue(follow.showJump)
        assertEquals(FollowPill.JumpToLatest, follow.pill(busy = true))
        assertEquals(FollowPill.JumpToLatest, follow.pill(busy = false))
    }

    @Test
    fun `scrolling back onto the latest turn follows again`() {
        val follow = TranscriptFollowState()
        follow.note(atBottom = false, userScroll = true)
        follow.note(atBottom = true, userScroll = true)
        assertTrue(follow.pinned)
        assertFalse(follow.paused)
        assertFalse(follow.showJump)
    }

    @Test
    fun `pausing at the bottom sticks until the reader moves`() {
        val follow = TranscriptFollowState()
        follow.pause()
        assertFalse(follow.pinned)
        // Stationary frames at the bottom must not resume on their own, or
        // the pause could never hold where it was pressed.
        follow.note(atBottom = true, userScroll = false)
        assertTrue(follow.paused)
        assertFalse(follow.pinned)
        // A scroll of one's own back onto the end clears it.
        follow.note(atBottom = true, userScroll = true)
        assertFalse(follow.paused)
        assertTrue(follow.pinned)
    }

    @Test
    fun `drifting away while paused offers jump without resuming`() {
        val follow = TranscriptFollowState()
        follow.pause()
        follow.note(atBottom = false, userScroll = false)
        assertTrue(follow.showJump)
        assertTrue(follow.paused)
        assertFalse(follow.pinned)
    }

    @Test
    fun `jump resumes from paused and from scrolled away`() {
        val paused = TranscriptFollowState()
        paused.pause()
        paused.jump()
        assertTrue(paused.pinned)
        assertFalse(paused.paused)
        assertFalse(paused.showJump)

        val away = TranscriptFollowState()
        away.note(atBottom = false, userScroll = true)
        away.jump()
        assertTrue(away.pinned)
        assertFalse(away.showJump)
    }

    @Test
    fun `the pill seats match the Apple transcript`() {
        // Scrolled away wins over everything: the way back first.
        assertEquals(FollowPill.JumpToLatest, pillFor(showJump = true, busy = true, paused = true))
        // A live turn offers pause and resume.
        assertEquals(FollowPill.Following, pillFor(showJump = false, busy = true, paused = false))
        assertEquals(FollowPill.Follow, pillFor(showJump = false, busy = true, paused = true))
        // Idle and pinned: nothing. A control nobody needs is clutter.
        assertNull(pillFor(showJump = false, busy = false, paused = false))
        assertNull(pillFor(showJump = false, busy = false, paused = true))
    }

    @Test
    fun `at bottom needs the last item within the threshold`() {
        assertTrue(isAtBottom(lastVisibleIndex = 9, totalItems = 10, distancePx = 0, thresholdPx = 56f))
        assertTrue(isAtBottom(lastVisibleIndex = 9, totalItems = 10, distancePx = 56, thresholdPx = 56f))
        assertFalse(isAtBottom(lastVisibleIndex = 9, totalItems = 10, distancePx = 57, thresholdPx = 56f))
        // The last item is not even laid out: far from the end.
        assertFalse(isAtBottom(lastVisibleIndex = 7, totalItems = 10, distancePx = 0, thresholdPx = 56f))
        assertFalse(isAtBottom(lastVisibleIndex = null, totalItems = 10, distancePx = 0, thresholdPx = 56f))
        // Nothing to scroll: already there.
        assertTrue(isAtBottom(lastVisibleIndex = null, totalItems = 0, distancePx = 0, thresholdPx = 56f))
    }
}
