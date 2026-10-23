// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.team

import kotlinx.serialization.json.*
import java.util.Base64
import java.util.Locale

internal data class TeamSharedFileData(val name: String, val mediaType: String, val bytes: ByteArray) {
    val raster get() = mediaType.startsWith("image/") && mediaType != "image/svg+xml"
    companion object {
        const val MAXIMUM_BYTES = 5 * 1024 * 1024
        fun safeName(value: String): String {
            val leaf = value.replace('\\', '/').substringAfterLast('/')
            val points = leaf.codePoints().filter { !Character.isISOControl(it) && Character.getType(it) != Character.FORMAT.toInt() && !"<>:\"/\\|?*".contains(String(Character.toChars(it))) }.limit(120).toArray()
            var clean = String(points, 0, points.size).trim().trimEnd('.')
            if (clean.isEmpty() || clean in setOf(".", "..")) return "shared-file"
            if (clean.substringBefore('.').matches(Regex("(?i)(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])"))) clean = "_$clean"
            return clean
        }
        fun read(reply: JsonObject, id: String): TeamSharedFileData {
            val attachment = reply["attachment"] as? JsonObject ?: error("shared_file_invalid")
            require(attachment.teamString("id") == id)
            val size = (attachment["size"] as? JsonPrimitive)?.takeIf { !it.isString }?.longOrNull ?: error("shared_file_invalid")
            val encoded = reply.teamString("data") ?: error("shared_file_invalid")
            require(size in 0..MAXIMUM_BYTES && encoded.length <= 8 * 1024 * 1024)
            val bytes = Base64.getDecoder().decode(encoded)
            require(bytes.size.toLong() == size && bytes.size <= MAXIMUM_BYTES)
            val media = attachment.teamString("mediaType")?.lowercase(Locale.ROOT)?.takeIf { it.length <= 160 && it.matches(Regex("[a-z0-9!#$&^_.+-]+/[a-z0-9!#$&^_.+-]+")) } ?: "application/octet-stream"
            return TeamSharedFileData(safeName(attachment.teamString("name").orEmpty()), media, bytes)
        }
    }
}
