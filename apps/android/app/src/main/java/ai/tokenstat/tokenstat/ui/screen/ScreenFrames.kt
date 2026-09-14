// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.screen

import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put

/// The bytes inside a `screen.viewer.read` answer, ported from Apple
/// `ScreenEncodedFrame` and the `ScreenViewerModel` input shapes in
/// `ScreenViewerView.swift`.
///
/// A frame arrives base64-encoded and starts with a 32-byte header: magic
/// `TSCR`, version 1, kind 1 (video), a keyframe bit, width and height, and
/// the payload length. The payload is H.264 Annex B. Input travels back as
/// base64 JSON through `screen.viewer.input`.
///
/// Kept free of Android imports so unit tests pin the same answers.
object ScreenFrames {
    const val HEADER_LEN = 32

    data class VideoFrame(
        val sequence: Long,
        val width: Int,
        val height: Int,
        val keyframe: Boolean,
        val payload: ByteArray,
    )

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
        if (data.size != HEADER_LEN + count) return null
        return VideoFrame(
            sequence = i64(data, 8),
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
    /// the Apple decoder looks for.
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

    /// Repack picture units as AVCC (four-byte big-endian lengths), the form
    /// fed to the platform decoder. Parameter sets and SEI stay out: they
    /// already live in the format description.
    fun toAvcc(pictures: List<ByteArray>): ByteArray {
        var total = 0
        pictures.forEach { total += 4 + it.size }
        val out = ByteArray(total)
        var at = 0
        for (unit in pictures) {
            out[at] = (unit.size shr 24).toByte()
            out[at + 1] = (unit.size shr 16).toByte()
            out[at + 2] = (unit.size shr 8).toByte()
            out[at + 3] = unit.size.toByte()
            unit.copyInto(out, at + 4)
            at += 4 + unit.size
        }
        return out
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
