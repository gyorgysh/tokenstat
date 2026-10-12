// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.screen

import java.io.InputStream
import java.security.MessageDigest
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.withContext

internal data class ScreenFileHash(val size: Long, val sha256: String)

/** A content provider may block, and large selections must remain cancellable. */
internal suspend fun hashScreenFile(open: () -> InputStream): ScreenFileHash = withContext(Dispatchers.IO) {
    val digest = MessageDigest.getInstance("SHA-256")
    var size = 0L
    open().use { stream ->
        val buffer = ByteArray(256 * 1024)
        while (true) {
            currentCoroutineContext().ensureActive()
            val count = stream.read(buffer)
            if (count < 0) break
            if (count == 0) {
                val byte = stream.read()
                if (byte < 0) break
                digest.update(byte.toByte())
                size++
            } else {
                digest.update(buffer, 0, count)
                size += count
            }
        }
    }
    ScreenFileHash(size, digest.digest().joinToString("") { "%02x".format(it.toInt() and 255) })
}
