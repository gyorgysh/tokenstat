// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.screen

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/// What the host sends and what goes back, pinned. The decoder itself needs a
/// device, so what can be tested here is the framing it hands to the platform.
/// `MachinePlaneTest` covers the envelope and the pointer shapes; this covers
/// the byte stream, the side channels and the keyboard.
class ScreenFramesTest {
    private fun videoFrame(
        payload: ByteArray,
        keyframe: Boolean = true,
        width: Int = 1920,
        height: Int = 1200,
        sequence: Long = 7,
        timestampUs: Long = 1_234_567,
    ): ByteArray {
        val out = ByteArray(ScreenFrames.HEADER_LEN + payload.size)
        "TSCR".forEachIndexed { index, char -> out[index] = char.code.toByte() }
        out[4] = 1
        out[5] = 1
        out[6] = if (keyframe) 1 else 0
        for (i in 0..<8) out[8 + i] = (sequence shr ((7 - i) * 8)).toByte()
        for (i in 0..<8) out[16 + i] = (timestampUs shr ((7 - i) * 8)).toByte()
        out[24] = (width shr 8).toByte()
        out[25] = width.toByte()
        out[26] = (height shr 8).toByte()
        out[27] = height.toByte()
        for (i in 0..<4) out[28 + i] = (payload.size shr ((3 - i) * 8)).toByte()
        payload.copyInto(out, ScreenFrames.HEADER_LEN)
        return out
    }

    @Test
    fun `a video frame carries its size, its keyframe bit and its timestamp`() {
        val payload = ScreenFrames.toAnnexB(listOf(byteArrayOf(0x67, 1, 2), byteArrayOf(0x65, 9)))
        val frame = ScreenFrames.parse(videoFrame(payload))!!
        assertEquals(7L, frame.sequence)
        assertEquals(1_234_567L, frame.timestampUs)
        assertEquals(1920, frame.width)
        assertEquals(1200, frame.height)
        assertTrue(frame.keyframe)
        assertTrue(payload.contentEquals(frame.payload))
    }

    /// The bug behind a black picture on every Android device: MediaCodec
    /// reads the byte stream, so units go in behind start codes and not
    /// behind four-byte lengths.
    @Test
    fun `units are repacked behind four-byte start codes, not lengths`() {
        val sps = byteArrayOf(0x67, 0x42, 0x00)
        val picture = byteArrayOf(0x65, 0x11, 0x22, 0x33)
        val stream = ScreenFrames.toAnnexB(listOf(sps, picture))
        assertEquals(
            listOf<Byte>(0, 0, 0, 1, 0x67, 0x42, 0x00, 0, 0, 0, 1, 0x65, 0x11, 0x22, 0x33),
            stream.toList(),
        )
    }

    @Test
    fun `an audio chunk reads its rate, its channels and its samples`() {
        val frames = 2
        val channels = 2
        val payload = ByteArray(16 + frames * channels * 2)
        "TAUD".forEachIndexed { index, char -> payload[index] = char.code.toByte() }
        payload[4] = 1
        payload[5] = channels.toByte()
        val rate = 48_000
        for (i in 0..<4) payload[8 + i] = (rate shr ((3 - i) * 8)).toByte()
        for (i in 0..<4) payload[12 + i] = (frames shr ((3 - i) * 8)).toByte()
        val chunk = ScreenFrames.audio(payload)!!
        assertEquals(48_000, chunk.sampleRate)
        assertEquals(2, chunk.channels)
        assertEquals(2, chunk.frames)
        assertEquals(8, chunk.pcm.size)
        assertNull(ScreenFrames.audio(payload.copyOf(payload.size - 2)))
    }

    @Test
    fun `display metadata names every screen and which one is live`() {
        val json = """
            {"type":"displays","selected":3,"displays":[
              {"id":1,"name":"Built-in","width":3024,"height":1964},
              {"id":3,"name":"Studio Display","width":5120,"height":2880}]}
        """.trimIndent()
        val metadata = ScreenFrames.metadata(json.toByteArray(Charsets.UTF_8))!!
        assertEquals("displays", metadata.type)
        assertEquals(3L, metadata.selected)
        assertEquals(listOf(1L, 3L), metadata.displays.map { it.id })
        assertEquals("Studio Display", metadata.displays[1].name)
        assertEquals(5120, metadata.displays[1].width)
    }

    @Test
    fun `clipboard metadata carries the text the host copied`() {
        val metadata = ScreenFrames.metadata(
            """{"type":"clipboard","text":"hello"}""".toByteArray(Charsets.UTF_8)
        )!!
        assertEquals("clipboard", metadata.type)
        assertEquals("hello", metadata.text)
    }

    @Test
    fun `metadata that cannot be read answers null`() {
        assertNull(ScreenFrames.metadata("not json".toByteArray(Charsets.UTF_8)))
        assertNull(ScreenFrames.metadata("""{"selected":1}""".toByteArray(Charsets.UTF_8)))
        assertNull(ScreenFrames.metadata("""[1,2]""".toByteArray(Charsets.UTF_8)))
    }

    /// Unknown types parse and fall through: the reader ignores what it does
    /// not know rather than failing the whole answer.
    @Test
    fun `an unknown metadata type parses and is ignored`() {
        val metadata = ScreenFrames.metadata(
            """{"type":"future","displays":[]}""".toByteArray(Charsets.UTF_8)
        )!!
        assertEquals("future", metadata.type)
        assertTrue(metadata.displays.isEmpty())
    }

    @Test
    fun `audio that is not a TAUD chunk answers null`() {
        fun chunk(mutate: (ByteArray) -> Unit): ByteArray {
            val payload = ByteArray(16 + 2 * 2)
            "TAUD".forEachIndexed { index, char -> payload[index] = char.code.toByte() }
            payload[4] = 1
            payload[5] = 1
            for (i in 0..<4) payload[8 + i] = (48_000 shr ((3 - i) * 8)).toByte()
            for (i in 0..<4) payload[12 + i] = (2 shr ((3 - i) * 8)).toByte()
            mutate(payload)
            return payload
        }
        assertNull(ScreenFrames.audio(chunk { it[0] = 'X'.code.toByte() }))
        assertNull(ScreenFrames.audio(chunk { it[4] = 2 }))
        assertNull(ScreenFrames.audio(chunk { it[5] = 0 }))
        assertNull(ScreenFrames.audio(chunk { it[5] = 9 }))
    }

    @Test
    fun `a payload with no start codes holds no units`() {
        assertTrue(ScreenFrames.splitAnnexB(byteArrayOf(1, 2, 3)).isEmpty())
        assertTrue(ScreenFrames.splitAnnexB(byteArrayOf()).isEmpty())
    }

    @Test
    fun `trailing bytes after the last start code belong to its unit`() {
        val payload = byteArrayOf(0, 0, 0, 1, 0x65, 9, 8, 7)
        val units = ScreenFrames.splitAnnexB(payload)
        assertEquals(1, units.size)
        assertEquals(listOf<Byte>(0x65, 9, 8, 7), units[0].toList())
    }

    @Test
    fun `every quality says its wire name`() {
        assertNull(ScreenQuality.Auto.wire)
        assertEquals("sharp", ScreenQuality.Sharp.wire)
        assertEquals("smooth", ScreenQuality.Smooth.wire)
        assertEquals("dataSaver", ScreenQuality.DataSaver.wire)
    }

    /// The host clamps wheel movement to whole pixels, so a scroll expressed
    /// as a fraction of the picture scrolls nothing at all.
    @Test
    fun `scroll carries pixels rather than a fraction of the picture`() {
        val json = ScreenFrames.scroll(0.5, 0.5, 0.0, -42.0)
        assertTrue(json, json.contains("\"dy\":-42.0"))
    }

    @Test
    fun `a click says which button and how many times`() {
        val json = ScreenFrames.click(0.25, 0.75, 1, 2, ScreenFlag.COMMAND)
        assertTrue(json, json.contains("\"button\":1"))
        assertTrue(json, json.contains("\"clickCount\":2"))
        assertTrue(json, json.contains("\"flags\":1048576"))
    }

    @Test
    fun `a letter typed with command reaches the host as a key code`() {
        assertEquals(9, ScreenKey.code('v'))
        assertEquals(8, ScreenKey.code('C'))
        assertNull(ScreenKey.code('1'))
    }
    @Test fun `overflowing audio dimensions cannot masquerade as a short frame`() {
        val bytes = ByteArray(20)
        "TAUD".forEachIndexed { i, c -> bytes[i] = c.code.toByte() }
        bytes[4] = 1
        bytes[5] = 2
        bytes[10] = 0xBB.toByte()
        bytes[11] = 0x80.toByte()
        bytes[12] = 0x40
        bytes[15] = 1
        assertNull(ScreenFrames.audio(bytes))
    }

    @Test fun `video with zero dimensions is rejected before codec creation`() {
        assertNull(ScreenFrames.parse(videoFrame(byteArrayOf(0, 0, 0, 1, 0x65), width = 0)))
    }

}
