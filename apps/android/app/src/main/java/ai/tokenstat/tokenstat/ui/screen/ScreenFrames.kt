// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.screen

import ai.tokenstat.tokenstat.ui.localization.L10n

import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put

object ScreenFrames {
    const val HEADER_LEN = 32

    data class VideoFrame(
        val sequence: Long,
        val timestampUs: Long,
        val width: Int,
        val height: Int,
        val keyframe: Boolean,
        val payload: ByteArray,
    ) {
        override fun equals(other: Any?): Boolean =
            other is VideoFrame && sequence == other.sequence &&
                timestampUs == other.timestampUs && width == other.width &&
                height == other.height && keyframe == other.keyframe &&
                payload.contentEquals(other.payload)

        override fun hashCode(): Int = sequence.hashCode() * 31 + payload.contentHashCode()
    }

    fun parse(data: ByteArray): VideoFrame? {
        if (data.size < HEADER_LEN) return null
        if (data[0] != 'T'.code.toByte() || data[1] != 'S'.code.toByte() ||
            data[2] != 'C'.code.toByte() || data[3] != 'R'.code.toByte()
        ) return null
        if (data[4] != 1.toByte() || data[5] != 1.toByte()) return null
        val keyframe = data[6].toInt() and 0x01 == 0x01
        val width = u16(data, 24)
        val height = u16(data, 26)
        val count = u32(data, 28)
        if (width <= 0 || height <= 0 || count <= 0 || data.size.toLong() != HEADER_LEN.toLong() + count) return null
        return VideoFrame(
            sequence = i64(data, 8),
            timestampUs = i64(data, 16),
            width = width,
            height = height,
            keyframe = keyframe,
            payload = data.copyOfRange(HEADER_LEN, data.size),
        )
    }

    private fun u16(data: ByteArray, at: Int): Int =
        ((data[at].toInt() and 0xFF) shl 8) or (data[at + 1].toInt() and 0xFF)

    private fun u32(data: ByteArray, at: Int): Int {
        var out = 0
        for (i in 0..<4) out = (out shl 8) or (data[at + i].toInt() and 0xFF)
        return out
    }

    private fun i64(data: ByteArray, at: Int): Long {
        var out = 0L
        for (i in 0..<8) out = (out shl 8) or (data[at + i].toInt() and 0xFF).toLong()
        return out
    }

    fun splitAnnexB(payload: ByteArray): List<ByteArray> {
        val starts = mutableListOf<Int>()
        var i = 0
        while (i + 3 < payload.size) {
            if (payload[i] == 0.toByte() && payload[i + 1] == 0.toByte() &&
                payload[i + 2] == 0.toByte() && payload[i + 3] == 1.toByte()
            ) {
                starts.add(i + 4)
                i += 4
            } else {
                i++
            }
        }
        return starts.mapIndexed { index, start ->
            val end = if (index + 1 < starts.size) starts[index + 1] - 4 else payload.size
            payload.copyOfRange(start, end)
        }
    }

    fun nalType(unit: ByteArray): Int? =
        unit.firstOrNull()?.toInt()?.and(0x1F)

    fun isParameterSet(unit: ByteArray): Boolean = nalType(unit) == 7 || nalType(unit) == 8

    fun isPicture(unit: ByteArray): Boolean = (nalType(unit) ?: 0) in 1..5

    fun toAnnexB(units: List<ByteArray>): ByteArray {
        var total = 0
        units.forEach { total += START_CODE.size + it.size }
        val out = ByteArray(total)
        var at = 0
        for (unit in units) {
            START_CODE.copyInto(out, at)
            unit.copyInto(out, at + START_CODE.size)
            at += START_CODE.size + unit.size
        }
        return out
    }

    private val START_CODE = byteArrayOf(0, 0, 0, 1)


    data class Display(val id: Long, val name: String, val width: Int, val height: Int)

    data class Metadata(
        val type: String,
        val selected: Long?,
        val displays: List<Display>,
        val text: String?,
    )

    fun metadata(json: JsonObject): Metadata? {
        val type = json["type"]?.jsonPrimitive?.contentOrNull ?: return null
        val displays = runCatching { json["displays"]?.jsonArray }
            .getOrNull()
            ?.mapNotNull { element ->
                val row = element as? JsonObject ?: return@mapNotNull null
                val id = row["id"]?.jsonPrimitive?.contentOrNull?.toLongOrNull()
                    ?: return@mapNotNull null
                Display(
                    id = id,
                    name = row["name"]?.jsonPrimitive?.contentOrNull ?: L10n.text("android.screenframes.display.34e108c0"),
                    width = row["width"]?.jsonPrimitive?.intOrNull ?: 0,
                    height = row["height"]?.jsonPrimitive?.intOrNull ?: 0,
                )
            }
            .orEmpty()
        return Metadata(
            type = type,
            selected = json["selected"]?.jsonPrimitive?.contentOrNull?.toLongOrNull(),
            displays = displays,
            text = json["text"]?.jsonPrimitive?.contentOrNull,
        )
    }

    fun metadata(bytes: ByteArray): Metadata? = runCatching {
        val element = kotlinx.serialization.json.Json.parseToJsonElement(
            bytes.toString(Charsets.UTF_8)
        )
        metadata(element.jsonObject)
    }.getOrNull()

    data class AudioChunk(val channels: Int, val sampleRate: Int, val frames: Int, val pcm: ByteArray) {
        override fun equals(other: Any?): Boolean =
            other is AudioChunk && channels == other.channels && sampleRate == other.sampleRate &&
                frames == other.frames && pcm.contentEquals(other.pcm)

        override fun hashCode(): Int = channels * 31 + pcm.contentHashCode()
    }

    fun audio(data: ByteArray): AudioChunk? {
        if (data.size < 16) return null
        if (data[0] != 'T'.code.toByte() || data[1] != 'A'.code.toByte() ||
            data[2] != 'U'.code.toByte() || data[3] != 'D'.code.toByte()
        ) return null
        if (data[4] != 1.toByte()) return null
        val channels = data[5].toInt() and 0xFF
        val rate = u32(data, 8)
        val frames = u32(data, 12)
        val samples = frames.toLong() * channels
        if (channels !in 1..8 || rate <= 0 || frames <= 0) return null
        if (data.size.toLong() != 16L + samples * 2) return null
        return AudioChunk(channels, rate, frames, data.copyOfRange(16, data.size))
    }


    fun move(x: Double, y: Double): String =
        buildJsonObject { put("type", "move"); put("x", x); put("y", y) }.toString()

    fun click(x: Double, y: Double, button: Int, count: Int): String =
        buildJsonObject {
            put("type", "click"); put("x", x); put("y", y)
            put("button", button); put("clickCount", count)
            put("flags", 0L)
        }.toString()

    fun click(x: Double, y: Double, button: Int, count: Int, flags: Long): String =
        buildJsonObject {
            put("type", "click"); put("x", x); put("y", y)
            put("button", button); put("clickCount", count)
            put("flags", flags)
        }.toString()

    fun press(x: Double, y: Double, down: Boolean): String =
        buildJsonObject {
            put("type", "mouse"); put("x", x); put("y", y)
            put("button", 0); put("down", down)
        }.toString()

    fun scroll(x: Double, y: Double, dx: Double, dy: Double): String =
        buildJsonObject {
            put("type", "scroll"); put("x", x); put("y", y)
            put("dx", dx); put("dy", dy)
        }.toString()

    fun key(code: Int, down: Boolean, flags: Long): String =
        buildJsonObject {
            put("type", "key"); put("keyCode", code)
            put("down", down); put("flags", flags)
        }.toString()

    fun text(text: String, flags: Long): String =
        buildJsonObject { put("type", "text"); put("text", text); put("flags", flags) }.toString()

    fun display(id: Long): String =
        buildJsonObject { put("type", "display"); put("id", id) }.toString()

    fun clipboard(text: String): String =
        buildJsonObject { put("type", "clipboard"); put("text", text) }.toString()

    fun heartbeat(): String =
        buildJsonObject { put("type", "heartbeat") }.toString()

    fun transportLabel(raw: String?): String = when (raw) {
        "direct" -> L10n.text("android.screenframes.direct_connection.28d0ad54")
        "relay" -> L10n.text("android.screenframes.encrypted_relay.153d7b1c")
        else -> raw ?: L10n.text("android.screenframes.waiting.612ffc5c")
    }
}

object ScreenKey {
    const val ESCAPE = 53
    const val TAB = 48
    const val DELETE = 51
    const val RETURN = 36
    const val LEFT = 123
    const val RIGHT = 124
    const val DOWN = 125
    const val UP = 126

    private val LETTERS = mapOf(
        'a' to 0, 's' to 1, 'd' to 2, 'f' to 3, 'h' to 4, 'g' to 5, 'z' to 6, 'x' to 7,
        'c' to 8, 'v' to 9, 'b' to 11, 'q' to 12, 'w' to 13, 'e' to 14, 'r' to 15,
        'y' to 16, 't' to 17, 'o' to 31, 'u' to 32, 'i' to 34, 'p' to 35, 'l' to 37,
        'j' to 38, 'k' to 40, 'n' to 45, 'm' to 46,
    )

    fun code(character: Char): Int? = LETTERS[character.lowercaseChar()]
}

object ScreenFlag {
    const val SHIFT = 1L shl 17
    const val CONTROL = 1L shl 18
    const val OPTION = 1L shl 19
    const val COMMAND = 1L shl 20
}

enum class ScreenPointerMode(val title: String) {
    Trackpad(L10n.text("android.screenframes.trackpad.2fb10776")),

    Direct(L10n.text("android.screenframes.direct.002c7c68")),
}

enum class ScreenQuality(val title: String, val detail: String) {
    Auto(L10n.text("android.screenframes.automatic.d461a493"), L10n.text("android.screenframes.best_the_connection_allows.6532539b")),
    Sharp(L10n.text("android.screenframes.sharp.1a3c4b30"), L10n.text("android.screenframes.every_detail_on_a_fast_link.ef30d0aa")),
    Smooth(L10n.text("android.screenframes.smooth.da519387"), L10n.text("android.screenframes.steady_over_the_relay.6391fb1b")),
    DataSaver(L10n.text("android.screenframes.data_saver.5b444f24"), L10n.text("android.screenframes.least_data_softest_picture.383ee72b"));

    val wire: String?
        get() = when (this) {
            Auto -> null
            Sharp -> "sharp"
            Smooth -> "smooth"
            DataSaver -> "dataSaver"
        }
}
