// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.screen

import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioTrack
import android.util.Log

/// What the far end is playing, played here. The Android counterpart of Apple
/// `ScreenAudioPlayer`.
///
/// The host sends 16-bit interleaved PCM in `TAUD` chunks, so there is nothing
/// to decode: the track is opened on the first chunk's rate and channel count
/// and fed as the chunks arrive. Writes are non-blocking on purpose. Audio
/// that cannot keep up is dropped, because the alternative is a write that
/// stalls the loop reading the picture.
class ScreenAudio {
    private var track: AudioTrack? = null
    private var rate = 0
    private var channels = 0

    @get:Synchronized
    @set:Synchronized
    var muted: Boolean = false
        set(value) {
            field = value
            if (value) runCatching { track?.pause(); track?.flush() }
            else runCatching { track?.play() }
        }

    @Synchronized
    fun play(chunk: ScreenFrames.AudioChunk) {
        if (muted) return
        val active = open(chunk) ?: return
        runCatching {
            active.write(chunk.pcm, 0, chunk.pcm.size, AudioTrack.WRITE_NON_BLOCKING)
        }.onFailure { Log.w(TAG, "audio write failed", it) }
    }

    @Synchronized
    fun reset() {
        runCatching { track?.pause() }
        runCatching { track?.flush() }
        runCatching { track?.release() }
        track = null
        rate = 0
        channels = 0
    }

    private fun open(chunk: ScreenFrames.AudioChunk): AudioTrack? {
        val existing = track
        if (existing != null && rate == chunk.sampleRate && channels == chunk.channels) {
            if (existing.playState != AudioTrack.PLAYSTATE_PLAYING) runCatching { existing.play() }
            return existing
        }
        reset()
        val mask = when (chunk.channels) {
            1 -> AudioFormat.CHANNEL_OUT_MONO
            2 -> AudioFormat.CHANNEL_OUT_STEREO
            // Said out loud: anything else is permanent silence, and silence
            // with nothing in the log is undebuggable.
            else -> {
                Log.w(TAG, "unsupported channel count: ${chunk.channels}")
                return null
            }
        }
        return runCatching {
            val minimum = AudioTrack.getMinBufferSize(
                chunk.sampleRate, mask, AudioFormat.ENCODING_PCM_16BIT
            )
            if (minimum <= 0) return null
            val created = AudioTrack.Builder()
                .setAudioAttributes(
                    AudioAttributes.Builder()
                        .setUsage(AudioAttributes.USAGE_MEDIA)
                        .setContentType(AudioAttributes.CONTENT_TYPE_MOVIE)
                        .build()
                )
                .setAudioFormat(
                    AudioFormat.Builder()
                        .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                        .setSampleRate(chunk.sampleRate)
                        .setChannelMask(mask)
                        .build()
                )
                // Two buffers' worth. One is a click every time a chunk
                // arrives late, and a deep buffer is lip sync nobody asked
                // for on a screen being driven from here.
                .setBufferSizeInBytes(minimum * 2)
                .setTransferMode(AudioTrack.MODE_STREAM)
                .build()
            track = created // Retain ownership before play(), which may throw.
            created.play()
            rate = chunk.sampleRate
            channels = chunk.channels
            created
        }.onFailure {
            Log.w(TAG, "audio track failed", it)
            reset()
        }.getOrNull()
    }

    private companion object {
        const val TAG = "ScreenAudio"
    }
}
