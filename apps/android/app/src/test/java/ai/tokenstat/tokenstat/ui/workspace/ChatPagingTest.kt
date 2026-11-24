// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.workspace

import org.junit.Assert.assertEquals
import org.junit.Test

class ChatPagingTest {
    @Test fun oldAndEntryPhonesGetSmallPages() {
        assertEquals(ChatPaging.Tier.Low, ChatPaging.tier(lowRam = true, heapMb = 512, cores = 8, performanceClass = 33))
        assertEquals(ChatPaging.Tier.Low, ChatPaging.tier(lowRam = false, heapMb = 128, cores = 8, performanceClass = 0))
        assertEquals(ChatPaging.Tier.Low, ChatPaging.tier(lowRam = false, heapMb = 256, cores = 4, performanceClass = 0))
    }

    @Test fun currentPhonesGetTheIphoneSizes() {
        assertEquals(ChatPaging.Tier.High, ChatPaging.tier(lowRam = false, heapMb = 256, cores = 8, performanceClass = 33))
        assertEquals(ChatPaging.Tier.High, ChatPaging.tier(lowRam = false, heapMb = 512, cores = 8, performanceClass = 0))
        assertEquals(3000, ChatPaging.high.openPageEvents)
    }

    @Test fun everythingElseIsMiddle() {
        assertEquals(ChatPaging.Tier.Medium, ChatPaging.tier(lowRam = false, heapMb = 256, cores = 8, performanceClass = 0))
        assertEquals(ChatPaging.Tier.Medium, ChatPaging.tier(lowRam = false, heapMb = 0, cores = 6, performanceClass = 0))
    }

    @Test fun everyTierOpensOnMoreThanOneReply() {
        ChatPaging.Tier.entries.forEach { assert(ChatPaging.of(it).openPageEvents >= 800) }
    }

    private val before = listOf("text-s50", "tool-a", "text-s90", "user-1")

    @Test fun theListHoldsARowThatKeptItsId() {
        val visible = listOf(RowSpan("tool-a", -20, 60), RowSpan("text-s90", 46, 400))
        assertEquals(null, earlierPageAnchor(visible, before, listOf("text-s1", "tool-a", "text-s90", "user-1"), 6))
    }

    @Test fun atTheVeryTopTheFirstRowThatSurvivedHoldsThePlace() {
        val visible = listOf(RowSpan("earlier", 0, 90), RowSpan("text-s50", 96, 500), RowSpan("tool-a", 602, 60))
        val after = listOf("user-0", "text-s1", "tool-a", "text-s90", "user-1")
        assertEquals(PageAnchor(2, 602), earlierPageAnchor(visible, before, after, 6))
    }

    @Test fun aCutReplyThatFillsTheScreenIsHeldByTheRowBelowIt() {
        val visible = listOf(RowSpan("text-s50", -300, 2400))
        val after = listOf("user-0", "text-s1", "tool-a", "text-s90", "user-1")
        assertEquals(PageAnchor(2, 2106), earlierPageAnchor(visible, before, after, 6))
    }

    @Test fun nothingInCommonHoldsNothing() {
        assertEquals(null, earlierPageAnchor(listOf(RowSpan("earlier", 0, 90)), before, before, 6))
        assertEquals(null, earlierPageAnchor(emptyList(), before, before, 6))
    }
}
