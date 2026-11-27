// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.screen

import android.media.MediaCodec
import android.media.MediaFormat
import android.os.Build
import android.util.Log
import android.view.Surface

class ScreenDecoder {
    private var codec: MediaCodec? = null
    private var configuredSurface: Surface? = null
    private var csd0: ByteArray? = null
    private var csd1: ByteArray? = null

    @Volatile var surface: Surface? = null

    @Volatile var decodedPictures = 0L

    fun reset() {
        runCatching { codec?.stop() }
        runCatching { codec?.release() }
        codec = null
        configuredSurface = null
        csd0 = null
        csd1 = null
        decodedPictures = 0
    }

    fun release() {
        reset()
        surface = null
    }

    fun decode(frame: ScreenFrames.VideoFrame): Boolean {
        if (surface !== configuredSurface && codec != null) reset()
        if (frame.keyframe) {
            val units = ScreenFrames.splitAnnexB(frame.payload)
            val sps = units.firstOrNull { ScreenFrames.nalType(it) == 7 }
            val pps = units.firstOrNull { ScreenFrames.nalType(it) == 8 }
            if (sps != null && pps != null && !sameCsd(sps, pps)) {
                configure(sps, pps, frame.width, frame.height)
            }
        }
        val active = codec
        if (active == null || csd0 == null) return false
        return try {
            if (!feed(active, frame.payload, frame.keyframe, frame.timestampUs)) return false
            drain(active, FIRST_DRAIN_US) > 0
        } catch (e: Exception) {
            Log.w(TAG, "decode failed, resetting", e)
            reset()
            false
        }
    }

    private fun sameCsd(sps: ByteArray, pps: ByteArray): Boolean =
        csd0?.contentEquals(ScreenFrames.toAnnexB(listOf(sps))) == true &&
            csd1?.contentEquals(ScreenFrames.toAnnexB(listOf(pps))) == true

    private fun configure(sps: ByteArray, pps: ByteArray, width: Int, height: Int) {
        val target = surface
        reset()
        if (target == null || !target.isValid) return
        val spsStream = ScreenFrames.toAnnexB(listOf(sps))
        val ppsStream = ScreenFrames.toAnnexB(listOf(pps))
        try {
            val format = MediaFormat.createVideoFormat(
                MediaFormat.MIMETYPE_VIDEO_AVC,
                width.coerceAtLeast(1),
                height.coerceAtLeast(1),
            )
            format.setByteBuffer("csd-0", java.nio.ByteBuffer.wrap(spsStream))
            format.setByteBuffer("csd-1", java.nio.ByteBuffer.wrap(ppsStream))
            format.setInteger(MediaFormat.KEY_MAX_INPUT_SIZE, MAX_VIDEO_BYTES)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                format.setInteger(MediaFormat.KEY_LOW_LATENCY, 1)
            }
            val created = MediaCodec.createDecoderByType(MediaFormat.MIMETYPE_VIDEO_AVC)
            codec = created
            created.configure(format, target, null, 0)
            created.start()
            configuredSurface = target
            csd0 = spsStream
            csd1 = ppsStream
        } catch (e: Exception) {
            Log.w(TAG, "configure failed", e)
            reset()
        }
    }

    private fun feed(
        codec: MediaCodec,
        annexB: ByteArray,
        keyframe: Boolean,
        timestampUs: Long,
    ): Boolean {
        val target = surface
        if (target == null || !target.isValid || target != configuredSurface) return false
        val index = codec.dequeueInputBuffer(INPUT_TIMEOUT_US)
        if (index < 0) {
            drain(codec, 0)
            return false
        }
        val buffer = codec.getInputBuffer(index) ?: return false
        if (buffer.capacity() < annexB.size) {
            Log.w(TAG, "feed dropped: ${annexB.size} bytes over ${buffer.capacity()} capacity")
            codec.queueInputBuffer(index, 0, 0, 0, 0)
            return false
        }
        buffer.clear()
        buffer.put(annexB)
        codec.queueInputBuffer(
            index, 0, annexB.size,
            if (timestampUs > 0) timestampUs else System.nanoTime() / 1_000,
            if (keyframe) MediaCodec.BUFFER_FLAG_KEY_FRAME else 0,
        )
        return true
    }

    private fun drain(codec: MediaCodec, firstTimeoutUs: Long): Int {
        var released = 0
        val info = MediaCodec.BufferInfo()
        repeat(MAX_DRAIN) { pass ->
            val index = codec.dequeueOutputBuffer(info, if (pass == 0) firstTimeoutUs else 0)
            if (index < 0) return released
            codec.releaseOutputBuffer(index, true)
            if (info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG == 0) {
                decodedPictures++
                released++
            }
        }
        return released
    }

    private companion object {
        const val TAG = "ScreenDecoder"
        const val MAX_VIDEO_BYTES = 1_048_576
        const val INPUT_TIMEOUT_US = 10_000L
        const val FIRST_DRAIN_US = 20_000L
        const val MAX_DRAIN = 8
    }
}
