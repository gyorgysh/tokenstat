// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.logic

import ai.tokenstat.tokenstat.ui.browser.BrowserPolicy
import ai.tokenstat.tokenstat.ui.screen.ScreenFrames
import ai.tokenstat.tokenstat.ui.ssh.SnippetRun
import ai.tokenstat.tokenstat.ui.terminal.TerminalKeysLogic
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.Json
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/// Pins the machine-plane ports to the same answers the Apple client's
/// Swift originals produce: key-bar folds, TSCR frames, browser URL policy,
/// and snippet placeholder rules.
class MachinePlaneTest {

    // TerminalKeysLogic, from ClientTerminalKeys / TerminalControlCode.fold.

    @Test
    fun controlFoldMatchesApple() {
        assertEquals(0x01, TerminalKeysLogic.controlCode('a'.code))
        assertEquals(0x01, TerminalKeysLogic.controlCode('A'.code))
        assertEquals(0x1B, TerminalKeysLogic.controlCode('['.code))
        assertEquals(0x00, TerminalKeysLogic.controlCode(' '.code))
        assertNull(TerminalKeysLogic.controlCode('1'.code))
        assertNull(TerminalKeysLogic.controlCode(0x09))
    }

    @Test
    fun backTabIsCsiZ() {
        assertTrue(TerminalKeysLogic.backTab.contentEquals(byteArrayOf(0x1B, 0x5B, 0x5A)))
    }

    @Test
    fun spokenNamesGlyphs() {
        assertEquals("Tab", TerminalKeysLogic.spoken("⇥"))
        assertEquals("Shift Tab", TerminalKeysLogic.spoken("⇧⇥"))
        assertEquals("Right arrow", TerminalKeysLogic.spoken("→"))
        assertEquals("Pipe", TerminalKeysLogic.spoken("|"))
        assertEquals("kb", TerminalKeysLogic.spoken("kb"))
    }

    @Test
    fun basenameKeepsTheLabelOffStorage() {
        assertEquals("bash", TerminalKeysLogic.basename("/bin/bash"))
        assertEquals("tokenstat", TerminalKeysLogic.basename("/Users/someone/work/tokenstat/"))
    }

    // ScreenFrames, from ScreenEncodedFrame and ScreenViewerModel inputs.

    private fun envelope(payload: ByteArray, keyframe: Boolean = true): ByteArray {
        val out = ByteArray(32 + payload.size)
        out[0] = 'T'.code.toByte()
        out[1] = 'S'.code.toByte()
        out[2] = 'C'.code.toByte()
        out[3] = 'R'.code.toByte()
        out[4] = 1
        out[5] = 1
        out[6] = if (keyframe) 1 else 0
        out[7] = 0
        for (i in 0..<8) out[8 + i] = ((99L shr (8 * (7 - i))) and 0xFF).toByte()
        out[24] = 0
        out[25] = 100
        out[26] = 0
        out[27] = 50
        val n = payload.size
        out[28] = ((n shr 24) and 0xFF).toByte()
        out[29] = ((n shr 16) and 0xFF).toByte()
        out[30] = ((n shr 8) and 0xFF).toByte()
        out[31] = (n and 0xFF).toByte()
        payload.copyInto(out, 32)
        return out
    }

    @Test
    fun frameParsesAndRefuses() {
        val payload = byteArrayOf(0, 0, 0, 1, 0x67, 0x42, 0x01)
        val frame = ScreenFrames.parse(envelope(payload))!!
        assertEquals(99L, frame.sequence)
        assertEquals(100, frame.width)
        assertEquals(50, frame.height)
        assertTrue(frame.keyframe)
        assertTrue(frame.payload.contentEquals(payload))

        assertNull(ScreenFrames.parse(ByteArray(10)))
        val badMagic = envelope(payload).also { it[0] = 'X'.code.toByte() }
        assertNull(ScreenFrames.parse(badMagic))
        val badKind = envelope(payload).also { it[5] = 2 }
        assertNull(ScreenFrames.parse(badKind))
        val short = envelope(payload).copyOf(40)
        assertNull(ScreenFrames.parse(short))
    }

    @Test
    fun annexBSplitsOnFourByteCodesLikeApple() {
        val sps = byteArrayOf(0x67, 0x42, 0x01)
        val pps = byteArrayOf(0x68, 0x01)
        val idr = byteArrayOf(0x65, 0x02)
        val payload = byteArrayOf(0, 0, 0, 1) + sps + byteArrayOf(0, 0, 0, 1) + pps +
            byteArrayOf(0, 0, 0, 1) + idr
        val units = ScreenFrames.splitAnnexB(payload)
        assertEquals(3, units.size)
        assertTrue(units[0].contentEquals(sps))
        assertEquals(7, ScreenFrames.nalType(units[0]))
        assertEquals(8, ScreenFrames.nalType(units[1]))
        assertTrue(ScreenFrames.isPicture(units[2]))
        assertFalse(ScreenFrames.isPicture(units[0]))
        assertTrue(ScreenFrames.isParameterSet(units[1]))
    }

    /// MediaCodec reads the byte stream, so units are repacked behind start
    /// codes. Four-byte lengths are what VideoToolbox is told to expect, and
    /// feeding them here is what left every Android picture black.
    @Test
    fun annexBPrefixesStartCodes() {
        val a = byteArrayOf(0x65, 0x02)
        val b = byteArrayOf(0x61, 0x03, 0x04)
        val stream = ScreenFrames.toAnnexB(listOf(a, b))
        assertEquals(4 + 2 + 4 + 3, stream.size)
        assertEquals(listOf<Byte>(0, 0, 0, 1), stream.take(4))
        assertEquals(listOf<Byte>(0, 0, 0, 1), stream.drop(6).take(4))
        assertEquals(0x65, stream[4].toInt())
        assertEquals(0x61, stream[10].toInt())
    }

    @Test
    fun inputShapesMatchTheHostContract() {
        val move = Json.parseToJsonElement(ScreenFrames.move(0.5, 0.25)).jsonObject
        assertEquals("move", move["type"]?.jsonPrimitive?.content)
        assertEquals(0.5, move["x"]?.jsonPrimitive?.content?.toDouble()!!, 0.0)

        val click = Json.parseToJsonElement(ScreenFrames.click(0.5, 0.5, 0, 1)).jsonObject
        assertEquals(1, click["clickCount"]?.jsonPrimitive?.content?.toInt())

        val press = Json.parseToJsonElement(ScreenFrames.press(0.1, 0.2, true)).jsonObject
        assertEquals("mouse", press["type"]?.jsonPrimitive?.content)
        assertEquals(true, press["down"]?.jsonPrimitive?.content?.toBoolean())

        val scroll = Json.parseToJsonElement(ScreenFrames.scroll(0.5, 0.5, 0.0, -0.1)).jsonObject
        assertEquals("scroll", scroll["type"]?.jsonPrimitive?.content)

        val key = Json.parseToJsonElement(ScreenFrames.key(8, true, 0)).jsonObject
        assertEquals(8, key["keyCode"]?.jsonPrimitive?.content?.toInt())

        val beat = Json.parseToJsonElement(ScreenFrames.heartbeat()).jsonObject
        assertEquals("heartbeat", beat["type"]?.jsonPrimitive?.content)
    }

    @Test
    fun transportLabelStaysHonest() {
        assertEquals("Direct connection", ScreenFrames.transportLabel("direct"))
        assertEquals("Encrypted relay", ScreenFrames.transportLabel("relay"))
        assertEquals("Waiting…", ScreenFrames.transportLabel(null))
    }

    // BrowserPolicy, from ClientWebView.allows.

    @Test
    fun browserAllowsTunnelAndSite() {
        assertTrue(BrowserPolicy.allows("http://127.0.0.1:52341/"))
        assertTrue(BrowserPolicy.allows("https://localhost:3000/app"))
        assertTrue(BrowserPolicy.allows("about:blank"))
        assertTrue(BrowserPolicy.allows("https://tokenstat.ai/delete"))
        assertTrue(BrowserPolicy.allows("https://app.tokenstat.ai/"))
    }

    @Test
    fun browserRefusesTheRest() {
        assertFalse(BrowserPolicy.allows("mailto:someone@example.com"))
        assertFalse(BrowserPolicy.allows("tel:+123"))
        assertFalse(BrowserPolicy.allows("http://tokenstat.ai/"))
        assertFalse(BrowserPolicy.allows("https://example.com/"))
        assertFalse(BrowserPolicy.allows("http://evil.com/?next=http://127.0.0.1/"))
        assertFalse(BrowserPolicy.allows(null))
        assertFalse(BrowserPolicy.allows("not a url"))
    }

    @Test
    fun browserTitleFallsBackToProduct() {
        assertEquals("127.0.0.1", BrowserPolicy.title("http://127.0.0.1:3000/"))
        assertEquals("tokenstat.ai", BrowserPolicy.title(null))
    }

    // SnippetRun, from SSHSnippet.bytesToRun and placeholders.

    @Test
    fun placeholdersKeepOrderAndDropDupes() {
        assertEquals(
            listOf("host", "path"),
            SnippetRun.placeholders("scp {{host}}:{{ path }} {{host}}"),
        )
        assertTrue(SnippetRun.placeholders("uptime").isEmpty())
        assertTrue(SnippetRun.placeholders("broken {{host").isEmpty())
    }

    @Test
    fun fillReplacesEverySpellingAndKeepsUnknowns() {
        assertEquals(
            "scp db:/var/log {{missing}}",
            SnippetRun.fill("scp {{host}}:{{ path }} {{missing}}", mapOf("host" to "db", "path" to "/var/log")),
        )
        // A value holding `$` stays literal, never a group reference.
        assertEquals("echo \$HOME", SnippetRun.fill("echo {{v}}", mapOf("v" to "\$HOME")))
    }

    @Test
    fun runBytesTypeReturn() {
        assertTrue(SnippetRun.runBytes("uptime").contentEquals("uptime\r".toByteArray(Charsets.UTF_8)))
    }
}
