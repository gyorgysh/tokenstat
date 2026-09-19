// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.marks

internal object AvatarImageLimits {
    fun sampleSize(width: Int, height: Int): Int? {
        if (width <= 0 || height <= 0) return null
        var sample = 1
        while (maxOf(width, height).toLong() > 512L * sample) sample *= 2
        return sample
    }
}
