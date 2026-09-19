// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.core

import java.io.ByteArrayOutputStream
import java.io.IOException
import java.io.InputStream

internal class InputLimitExceeded : IOException("Input exceeds the allowed size")

/** Check the limit while reading, including providers that do not report a size. */
internal fun InputStream.readBounded(limit: Int): ByteArray {
    require(limit >= 0)
    val output = ByteArrayOutputStream(minOf(limit, 8192))
    val buffer = ByteArray(8192)
    while (true) {
        val remaining = limit.toLong() - output.size() + 1
        val count = read(buffer, 0, minOf(buffer.size.toLong(), remaining).toInt())
        if (count < 0) break
        if (count == 0) {
            val byte = read()
            if (byte < 0) break
            if (output.size() == limit) throw InputLimitExceeded()
            output.write(byte)
        } else {
            if (count > limit - output.size()) throw InputLimitExceeded()
            output.write(buffer, 0, count)
        }
    }
    return output.toByteArray()
}
