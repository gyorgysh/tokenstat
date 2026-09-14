// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.screen

import android.media.MediaCodec
import android.media.MediaFormat
import android.util.Log
import android.view.Surface

/// H.264 Annex B pictures to a platform surface, the Android counterpart of
/// Apple `ScreenH264Decoder`.
///
/// The host sends VideoToolbox access units: SPS (NAL 7) and PPS (NAL 8) ride
/// on keyframes and build the format description, VCL units (NAL 1 to 5) are
/// the picture. Anything else (SEI, AUD) never reaches the codec, and a
/// session whose parameter sets change reconfigures rather than failing.
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
        val units = ScreenFrames.splitAnnexB(frame.payload)
        if (frame.keyframe) {
            val sps = units.firstOrNull { ScreenFrames.nalType(it) == 7 }
            val pps = units.firstOrNull { ScreenFrames.nalType(it) == 8 }
            if (sps != null && pps != null && !sameCsd(sps, pps)) {
                configure(sps, pps, frame.width, frame.height)
            }
        }
        val active = codec
        if (active == null || !hasFormat()) return false
        val pictures = units.filter { ScreenFrames.isPicture(it) }
        if (pictures.isEmpty()) return false
        return try {
            feed(active, ScreenFrames.toAvcc(pictures), frame.keyframe)
            drain(active)
            true
        } catch (e: Exception) {
            // A sick codec never recovers on its own. Drop it and let the
            // next keyframe rebuild from fresh parameter sets.
            Log.w(TAG, "decode failed, resetting", e)
            reset()
            false
        }
    }

    private fun hasFormat(): Boolean = csd0 != null

    private fun sameCsd(sps: ByteArray, pps: ByteArray): Boolean =
        csd0?.contentEquals(sps) == true && csd1?.contentEquals(pps) == true

    private fun configure(sps: ByteArray, pps: ByteArray, width: Int, height: Int) {
        val target = surface
        reset()
        if (target == null || !target.isValid) return
        try {
            val format = MediaFormat.createVideoFormat(
                MediaFormat.MIMETYPE_VIDEO_AVC,
                width.coerceAtLeast(1),
                height.coerceAtLeast(1),
            )
            format.setByteBuffer("csd-0", java.nio.ByteBuffer.wrap(sps))
            format.setByteBuffer("csd-1", java.nio.ByteBuffer.wrap(pps))
            format.setInteger(MediaFormat.KEY_MAX_INPUT_SIZE, MAX_VIDEO_BYTES)
            val created = MediaCodec.createDecoderByType(MediaFormat.MIMETYPE_VIDEO_AVC)
            created.configure(format, target, null, 0)
            created.start()
            codec = created
            configuredSurface = target
            csd0 = sps
            csd1 = pps
        } catch (e: Exception) {
            Log.w(TAG, "configure failed", e)
            reset()
        }
    }

    private fun feed(codec: MediaCodec, avcc: ByteArray, keyframe: Boolean): Boolean {
        // The surface may have gone away under a live codec (rotation tears
        // it down). Reconfigure on the next keyframe instead of feeding a
        // dead target.
        val target = surface
        if (target == null || !target.isValid || target != configuredSurface) return false
        val index = codec.dequeueInputBuffer(INPUT_TIMEOUT_US)
        if (index < 0) return false
        val buffer = codec.getInputBuffer(index) ?: return false
        if (buffer.capacity() < avcc.size) return false
        buffer.clear()
        buffer.put(avcc)
        codec.queueInputBuffer(
            index, 0, avcc.size,
            System.nanoTime() / 1_000,
            if (keyframe) MediaCodec.BUFFER_FLAG_KEY_FRAME else 0,
        )
        return true
    }

    private fun drain(codec: MediaCodec) {
        val info = MediaCodec.BufferInfo()
        repeat(MAX_DRAIN) {
            when (val index = codec.dequeueOutputBuffer(info, 0)) {
                MediaCodec.INFO_TRY_AGAIN_LATER -> return
                MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> return
                else -> if (index >= 0) {
                    codec.releaseOutputBuffer(index, true)
                    if (info.size > 0) decodedPictures++
                }
            }
        }
    }

    private companion object {
        const val TAG = "ScreenDecoder"
        const val MAX_VIDEO_BYTES = 1_048_576
        const val INPUT_TIMEOUT_US = 10_000L
        const val MAX_DRAIN = 8
    }
}
