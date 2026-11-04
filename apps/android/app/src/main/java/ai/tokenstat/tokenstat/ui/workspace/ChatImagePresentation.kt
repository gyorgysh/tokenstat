// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.workspace

internal const val CHAT_IMAGE_PREVIEW_BYTES = 250L * 1024 * 1024
internal const val CHAT_IMAGE_GALLERY_EDGE = 1280

internal fun chatImageAutomaticPreviewAllowed(size: Long?, route: String?): Boolean =
    route == "direct" && size != null && size in 1..CHAT_IMAGE_PREVIEW_BYTES

private val chatImageTypes = setOf("image/png", "image/jpeg", "image/webp", "image/gif", "image/avif", "image/heic", "image/heif", "image/bmp")

internal fun ChatDisplayItem.Attachment.isImage(): Boolean =
    mediaType?.substringBefore(';')?.trim()?.lowercase() in chatImageTypes

internal data class ChatImageRows(
    val rows: List<ChatDisplayItem>,
    val toolImages: Map<String, List<ChatDisplayItem.Attachment>>,
)

/** Only explicit, exact tool provenance moves an image beside a step. */
internal fun chatImageRows(folded: List<ChatDisplayItem>, raw: List<ChatDisplayItem>): ChatImageRows {
    val imageRows = folded.mapNotNull { (it as? ChatDisplayItem.Attachment)?.takeIf { image -> image.isImage() } }
    if (imageRows.isEmpty()) return ChatImageRows(folded, emptyMap())
    val visibleIds = folded.mapTo(HashSet()) { it.id }
    val collapsedOwners = mutableMapOf<String, String>()
    for (item in folded) {
        if (item is ChatDisplayItem.Group && !item.group.open) {
            for (member in item.group.memberIds) collapsedOwners.putIfAbsent(member, item.id)
        }
    }
    val toolsInTurn = mutableMapOf<Pair<String?, String>, String>()
    val imageTools = mutableMapOf<String, String>()
    raw.forEach { item ->
        when (item) {
            is ChatDisplayItem.User -> if (!item.isSteer) toolsInTurn.clear()
            is ChatDisplayItem.Handoff, is ChatDisplayItem.TurnSeparator -> toolsInTurn.clear()
            is ChatDisplayItem.Tool -> toolsInTurn[item.state.backend to item.state.callId] = item.id
            is ChatDisplayItem.Edit -> item.state.callId?.let { toolsInTurn[item.state.backend to it] = item.id }
            is ChatDisplayItem.Attachment -> item.callId?.let { toolsInTurn[item.backend to it] }?.let { imageTools[item.id] = it }
            else -> Unit
        }
    }
    val linked = linkedMapOf<String, MutableList<ChatDisplayItem.Attachment>>()
    val linkedIds = mutableSetOf<String>()
    val linkedImages = mutableSetOf<Pair<String, String>>()
    imageRows.forEach { image ->
        val toolId = imageTools[image.id] ?: return@forEach
        val anchor = if (toolId in visibleIds) toolId else collapsedOwners[toolId] ?: return@forEach
        val images = linked.getOrPut(anchor) { mutableListOf() }
        if (linkedImages.add(anchor to image.attachmentId)) images.add(image)
        linkedIds.add(image.id)
    }
    val rows = mutableListOf<ChatDisplayItem>()
    val pending = mutableListOf<ChatDisplayItem.Attachment>()
    val pendingIds = mutableSetOf<String>()
    fun flush() {
        if (pending.isNotEmpty()) rows.add(ChatDisplayItem.ImageGallery("images:${pending.first().attachmentId}", pending.toList()))
        pending.clear()
        pendingIds.clear()
    }
    for (item in folded) {
        if (item.id in linkedIds) {
            if (item is ChatDisplayItem.Attachment && pending.isNotEmpty() && pending.first().backend != item.backend) flush()
            continue
        }
        if (item is ChatDisplayItem.Attachment && item.isImage()) {
            if (pending.isNotEmpty() && pending.first().backend != item.backend) flush()
            if (pendingIds.add(item.attachmentId)) pending.add(item)
        } else { flush(); rows.add(item) }
    }
    flush()
    return ChatImageRows(rows, linked)
}

/** Decode at display resolution, preserving the original file for Open/Save. */
internal fun chatImageDecodeSize(width: Int, height: Int, maxEdge: Int): Pair<Int, Int> {
    require(width > 0 && height > 0 && maxEdge > 0)
    val scale = minOf(1.0, maxEdge.toDouble() / maxOf(width, height))
    return maxOf(1, (width * scale).toInt()) to maxOf(1, (height * scale).toInt())
}

internal fun chatImageGridColumns(count: Int): Int = if (count <= 3) count.coerceAtLeast(1) else 2
internal fun chatImageVisibleCount(count: Int): Int = count.coerceIn(0, 4)

internal data class ChatImageRowGeometry(
    val indexes: List<Int>,
    val widths: List<Float>,
    val height: Float,
    val gap: Float,
)

/** Justified rows in dp. Thumbnail dimensions never depend on these results. */
internal fun chatImageGalleryGeometry(aspects: List<Double?>, availableWidth: Float): List<ChatImageRowGeometry> {
    if (aspects.isEmpty() || !availableWidth.isFinite() || availableWidth <= 0) return emptyList()
    val width = availableWidth.coerceAtMost(640f)
    val count = chatImageVisibleCount(aspects.size)
    val columns = minOf(chatImageGridColumns(count), ((width + 4f) / 52f).toInt().coerceAtLeast(1))
    val ratios = aspects.take(count).map { it?.takeIf { ratio -> ratio.isFinite() && ratio > 0 }?.coerceIn(.65, 2.2) ?: 1.5 }
    return (0 until count).toList().chunked(columns).map { indexes ->
        val gap = if (indexes.size == 1) 0f else 4f
        val room = width - gap * (indexes.size - 1)
        val minimum = minOf(48.0, room.toDouble() / indexes.size)
        val widths = DoubleArray(indexes.size)
        val remaining = indexes.indices.toMutableSet()
        var freeWidth = room.toDouble()
        // Freeze narrow cells at a usable touch width, then distribute the
        // rest proportionally. Normal 3-up phone rows still fit in one row.
        while (remaining.isNotEmpty()) {
            val total = remaining.sumOf { ratios[indexes[it]] }
            val small = remaining.filter { freeWidth * ratios[indexes[it]] / total < minimum }
            if (small.isEmpty()) {
                remaining.forEach { widths[it] = freeWidth * ratios[indexes[it]] / total }
                break
            }
            small.forEach { widths[it] = minimum; freeWidth -= minimum; remaining.remove(it) }
        }
        val cap = if (aspects.size == 1) 300.0 else 240.0
        val height = indexes.indices.minOf { widths[it] / ratios[indexes[it]] }.coerceIn(48.0, cap)
        ChatImageRowGeometry(indexes, widths.map(Double::toFloat), height.toFloat(), gap)
    }
}
