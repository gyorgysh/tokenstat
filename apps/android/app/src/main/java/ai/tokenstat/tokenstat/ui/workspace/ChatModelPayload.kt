// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.workspace

import java.io.File

internal const val MODEL_PREVIEW_BYTES = 12 * 1024 * 1024

internal fun readModelPreviewBytes(file: File): ByteArray? {
    if (!file.isFile) return null
    return file.inputStream().use { input ->
        // Size the buffer from the opened file, not an earlier path lookup.
        val size = input.channel.size()
        if (size !in 1..MODEL_PREVIEW_BYTES.toLong()) return null
        val bytes = ByteArray(size.toInt())
        var offset = 0
        while (offset < bytes.size) {
            val count = input.read(bytes, offset, bytes.size - offset)
            if (count <= 0) return null
            offset += count
        }
        // A growing file must not expand the allocation beyond the preview limit.
        if (input.read() != -1) null else bytes
    }
}
