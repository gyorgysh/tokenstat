// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.screen

import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put

/// The bytes inside a `screen.viewer.read` answer, ported from Apple
/// `ScreenEncodedFrame` and the `ScreenViewerModel` input shapes in
/// `ScreenViewerView.swift`.
///
/// A frame arrives base64-encoded and starts with a 32-byte header: magic
/// `TSCR`, version 1, kind 1 (video), a keyframe bit, the sequence, the
/// presentation time, width and height, and the payload length. The payload is
/// H.264 Annex B. Metadata and audio arrive on their own fields of the same
/// answer. Input travels back as base64 JSON through `screen.viewer.input`.
///
/// Kept free of Android imports so unit tests pin the same answers.
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
        // A data class over a ByteArray gets reference equality for the array,
        // which is a trap rather than a meaning. Compared by contents or not
        // at all.
        override fun equals(other: Any?): Boolean =
            other is VideoFrame && sequence == other.sequence &&
                timestampUs == other.timestampUs && width == other.width &&
                height == other.height && keyframe == other.keyframe &&
                payload.contentEquals(other.payload)

        override fun hashCode(): Int = sequence.hashCode() * 31 + payload.contentHashCode()
    }

    /// Split the TSCR envelope. Anything that is not kind 1 video answers
    /// null, the way the Apple decoder declines it.
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

    /// Split Annex B into NAL units on four-byte start codes, the only form
    /// the host emits.
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

    /// Repack NAL units as Annex B, each behind a four-byte start code.
    ///
    /// The one place Android and Apple genuinely differ. VideoToolbox takes
    /// AVCC, four-byte big-endian lengths, because its format description
    /// says so. MediaCodec takes the byte stream: start codes in the input
    /// buffer and start codes in `csd-0` / `csd-1`. Handing it lengths is not
    /// a slower path, it is not a path at all, and the platform decoder says
    /// so by logging "No start code is found" over a black surface.
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

    // Metadata, the side channel the host uses to say what it has and what it
    // copied. Port of Apple `ScreenMetadata`.

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
                    name = row["name"]?.jsonPrimitive?.contentOrNull ?: "Display",
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

    /// Parse the metadata JSON the host base64s into the read answer.
    fun metadata(bytes: ByteArray): Metadata? = runCatching {
        val element = kotlinx.serialization.json.Json.parseToJsonElement(
            bytes.toString(Charsets.UTF_8)
        )
        metadata(element.jsonObject)
    }.getOrNull()

    /// A `TAUD` chunk: header big-endian, interleaved 16-bit samples little
    /// endian, exactly as `ScreenAudioPCM.encode` writes them.
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

    // Input events, in the shapes the host applies. Coordinates are
    // normalized to the remote display, which is the only thing that
    // survives two displays of different sizes.

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

    /// Wheel movement in pixels on the remote display. The host clamps these
    /// to whole numbers, so a normalized fraction scrolls nothing at all.
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

    /// The "still here" beat. Sent ungated by control mode: a passive
    /// watcher is the exact case the relay would otherwise cut off.
    fun heartbeat(): String =
        buildJsonObject { put("type", "heartbeat") }.toString()

    /// Missing stays missing: inventing "Encrypted relay" for a path nobody
    /// observed yet is the same lie the account card refuses to tell.
    fun transportLabel(raw: String?): String = when (raw) {
        "direct" -> "Direct connection"
        "relay" -> "Encrypted relay"
        else -> raw ?: "Waiting…"
    }
}

/// Virtual key codes the key row and the software keyboard send.
///
/// macOS numbers, because the host synthesises `CGEvent`s with them. Twin of
/// Apple `ScreenKey`.
object ScreenKey {
    const val ESCAPE = 53
    const val TAB = 48
    const val DELETE = 51
    const val RETURN = 36
    const val LEFT = 123
    const val RIGHT = 124
    const val DOWN = 125
    const val UP = 126

    /// A character typed with command or control has to reach the host as a
    /// key code, because the host synthesises a key event and not text.
    private val LETTERS = mapOf(
        'a' to 0, 's' to 1, 'd' to 2, 'f' to 3, 'h' to 4, 'g' to 5, 'z' to 6, 'x' to 7,
        'c' to 8, 'v' to 9, 'b' to 11, 'q' to 12, 'w' to 13, 'e' to 14, 'r' to 15,
        'y' to 16, 't' to 17, 'o' to 31, 'u' to 32, 'i' to 34, 'p' to 35, 'l' to 37,
        'j' to 38, 'k' to 40, 'n' to 45, 'm' to 46,
    )

    fun code(character: Char): Int? = LETTERS[character.lowercaseChar()]
}

/// Modifier bits shared with `CGEventFlags` on the host. Twin of Apple
/// `ScreenFlag`.
object ScreenFlag {
    const val SHIFT = 1L shl 17
    const val CONTROL = 1L shl 18
    const val OPTION = 1L shl 19
    const val COMMAND = 1L shl 20
}

/// How a finger maps onto the remote pointer. Twin of Apple
/// `ScreenPointerMode`.
enum class ScreenPointerMode(val title: String) {
    /// The finger drags the pointer from wherever it already is. What a
    /// laptop trackpad does, and the default on a phone.
    Trackpad("Trackpad"),

    /// The pointer goes where the finger touched.
    Direct("Direct"),
}

/// What the picture is asked to be worth. Twin of Apple
/// `ScreenQualityChoice`.
enum class ScreenQuality(val title: String, val detail: String) {
    Auto("Automatic", "Best the connection allows"),
    Sharp("Sharp", "Every detail, on a fast link"),
    Smooth("Smooth", "Steady over the relay"),
    DataSaver("Data saver", "Least data, softest picture");

    /// Null for automatic: the absence of a choice, rather than a choice
    /// called automatic.
    val wire: String?
        get() = when (this) {
            Auto -> null
            Sharp -> "sharp"
            Smooth -> "smooth"
            DataSaver -> "dataSaver"
        }
}
