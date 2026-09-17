// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.screen

import android.media.MediaCodec
import android.media.MediaFormat
import android.os.Build
import android.util.Log
import android.view.Surface

/// H.264 Annex B pictures to a platform surface, the Android counterpart of
/// Apple `ScreenH264Decoder`.
///
/// The host sends an Annex B byte stream: SPS (NAL 7) and PPS (NAL 8) ride on
/// keyframes and build the format, and the picture follows behind its own
/// start codes. That is the form MediaCodec reads, so the payload goes to the
/// codec as it arrived rather than being repacked. The Apple decoder repacks
/// to AVCC because VideoToolbox is told to expect four-byte lengths; doing the
/// same here is not a slower path but no path at all, and the platform decoder
/// answers it with "No start code is found" over a black surface.
class ScreenDecoder {
    private var codec: MediaCodec? = null
    private var configuredSurface: Surface? = null
    private var csd0: ByteArray? = null
    private var csd1: ByteArray? = null

    @Volatile var surface: Surface? = null

    /// Pictures handed to the surface since the last reset. The viewer reads
    /// this to tell "connected" from "streaming".
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

    /// True when a picture was actually queued for the surface.
    fun decode(frame: ScreenFrames.VideoFrame): Boolean {
        // Rotation tears the surface down under a live codec. Drop it and let
        // the next keyframe rebuild against the new one.
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
            // The payload verbatim. It is already the byte stream MediaCodec
            // reads, parameter sets and all, and a keyframe carrying its own
            // SPS/PPS is how the decoder recovers from a picture it missed.
            if (!feed(active, frame.payload, frame.keyframe, frame.timestampUs)) return false
            drain(active, FIRST_DRAIN_US) > 0
        } catch (e: Exception) {
            // A sick codec never recovers on its own. Drop it and let the
            // next keyframe rebuild from fresh parameter sets.
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
        // Parameter sets carry their start codes here too: `csd-0` and `csd-1`
        // are byte-stream fragments, not bare payloads.
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
            // A desktop being driven from here is worth more as a fast
            // picture than as a smooth one: a decoder holding three frames
            // to reorder them puts that much lag between a finger and what
            // it moved. The stream has no B-frames to reorder anyway.
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                format.setInteger(MediaFormat.KEY_LOW_LATENCY, 1)
            }
            val created = MediaCodec.createDecoderByType(MediaFormat.MIMETYPE_VIDEO_AVC)
            created.configure(format, target, null, 0)
            created.start()
            codec = created
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
        // The surface may have gone away under a live codec (rotation tears
        // it down). Reconfigure on the next keyframe instead of feeding a
        // dead target.
        val target = surface
        if (target == null || !target.isValid || target != configuredSurface) return false
        val index = codec.dequeueInputBuffer(INPUT_TIMEOUT_US)
        if (index < 0) {
            // Every input buffer is still holding a picture the codec has not
            // finished with. Take the output side down a notch and let the
            // next frame in rather than dropping this one silently.
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

    /// Output pictures released to the surface, so the caller knows a picture
    /// actually rendered rather than that bytes went in. The first poll waits
    /// briefly: a zero timeout asks whether a picture is ready in the same
    /// breath as the bytes went in, which on a slow device is never.
    private fun drain(codec: MediaCodec, firstTimeoutUs: Long): Int {
        var released = 0
        val info = MediaCodec.BufferInfo()
        repeat(MAX_DRAIN) { pass ->
            val index = codec.dequeueOutputBuffer(info, if (pass == 0) firstTimeoutUs else 0)
            if (index < 0) return released
            codec.releaseOutputBuffer(index, true)
            // A surface render carries no bytes: `size` is zero on every real
            // picture, so the codec-config flag is what separates pictures
            // from setup, not the byte count.
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
