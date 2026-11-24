// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.workspace

import android.app.ActivityManager
import android.content.Context
import android.os.Build

/// How much transcript one `chat.eventPage` answer carries, sized to the
/// device. Port of the Apple `ChatPaging`, which only has to cover a few
/// iPhone and iPad generations. Android runs on ten-year-old phones too, and
/// a page that a current phone folds in a blink can stall one of those.
///
/// Records, not rows: a streamed reply is often a thousand records that
/// become one paragraph, so even the smallest tier opens on about one reply
/// and its tool steps. An older host caps both at its own, lower ceiling.
internal data class ChatPaging(
    /// The newest page a conversation opens on.
    val openPageEvents: Int,
    /// Each earlier page, loaded as the reader scrolls back.
    val earlierPageEvents: Int,
) {
    enum class Tier { Low, Medium, High }

    companion object {
        /// The iPhone and iPad sizes: half the host's history ceiling.
        val high = ChatPaging(openPageEvents = 3000, earlierPageEvents = 4000)
        val medium = ChatPaging(openPageEvents = 1500, earlierPageEvents = 2000)
        val low = ChatPaging(openPageEvents = 800, earlierPageEvents = 1000)

        fun of(tier: Tier) = when (tier) {
            Tier.Low -> low
            Tier.Medium -> medium
            Tier.High -> high
        }

        fun forDevice(context: Context): ChatPaging {
            val activity = context.getSystemService(ActivityManager::class.java)
            val performanceClass = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) Build.VERSION.MEDIA_PERFORMANCE_CLASS else 0
            return of(
                tier(
                    lowRam = activity?.isLowRamDevice ?: false,
                    heapMb = activity?.memoryClass ?: 0,
                    cores = Runtime.getRuntime().availableProcessors(),
                    performanceClass = performanceClass,
                ),
            )
        }

        /// The system's own low-RAM flag or a small app heap means an old or
        /// entry phone. A declared performance class (Android 12 and later)
        /// or a large heap on eight cores means a phone that keeps up with
        /// the iPhone sizes. Everything else gets the middle.
        fun tier(lowRam: Boolean, heapMb: Int, cores: Int, performanceClass: Int): Tier = when {
            lowRam || heapMb in 1 until 192 || cores <= 4 -> Tier.Low
            performanceClass >= Build.VERSION_CODES.S || (heapMb >= 384 && cores >= 8) -> Tier.High
            else -> Tier.Medium
        }
    }
}

internal data class RowSpan(val key: Any, val offset: Int, val size: Int)

/// Where a row of the new list has to sit for the reader's line to stay put.
internal data class PageAnchor(val row: Int, val offset: Int)

/// The row that holds the reader's place when an earlier page lands above it.
///
/// Null when the list's own key anchoring already holds it, which is the case
/// whenever its first visible item is still there. It is not when that item is
/// the Earlier button, or a reply the page cut in half: joined to its start,
/// the reply takes the id of its first record. Then the first visible row that
/// kept its id holds the place, or the row just below the ones on screen when
/// one long reply fills the screen.
internal fun earlierPageAnchor(
    visible: List<RowSpan>,
    before: List<String>,
    after: List<String>,
    spacing: Int,
): PageAnchor? {
    val kept = after.withIndex().associate { it.value to it.index }
    val known = before.toSet()
    if (visible.isEmpty() || visible.first().key in kept) return null
    val rows = visible.filter { it.key in known }
    rows.firstOrNull { it.key in kept }?.let { return PageAnchor(kept.getValue(it.key as String), it.offset) }
    val last = rows.lastOrNull() ?: return null
    val below = before.getOrNull(before.indexOf(last.key as String) + 1) ?: return null
    return kept[below]?.let { PageAnchor(it, last.offset + last.size + spacing) }
}
