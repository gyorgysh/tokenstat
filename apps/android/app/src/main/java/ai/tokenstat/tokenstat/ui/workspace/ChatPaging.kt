// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.workspace

import android.app.ActivityManager
import android.content.Context
import android.os.Build

internal data class ChatPaging(
    val openPageEvents: Int,
    val earlierPageEvents: Int,
) {
    enum class Tier { Low, Medium, High }

    companion object {
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

        fun tier(lowRam: Boolean, heapMb: Int, cores: Int, performanceClass: Int): Tier = when {
            lowRam || heapMb in 1 until 192 || cores <= 4 -> Tier.Low
            performanceClass >= Build.VERSION_CODES.S || (heapMb >= 384 && cores >= 8) -> Tier.High
            else -> Tier.Medium
        }
    }
}

internal data class RowSpan(val key: Any, val offset: Int, val size: Int)

internal data class PageAnchor(val row: Int, val offset: Int)

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
