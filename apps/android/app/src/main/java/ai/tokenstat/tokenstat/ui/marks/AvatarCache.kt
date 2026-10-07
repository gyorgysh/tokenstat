// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.marks

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.util.LruCache
import android.util.AtomicFile
import java.io.ByteArrayOutputStream
import java.io.File
import java.net.HttpURLConnection
import java.net.URL
import java.security.MessageDigest
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Deferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlin.coroutines.coroutineContext

/// One decoded profile picture per URL, for the life of the process and on
/// disk across launches. Ported from `AvatarCache` in `Marks.swift`: the
/// picture must be a plain bitmap by the time it reaches the layout, and the
/// same face is drawn in the top bar and on the account sheet, so reads are
/// synchronous and fetches are deduped. A fresh composable for an already
/// fetched URL paints the picture on its first frame instead of flashing the
/// monogram while a new fetch spins up.
object AvatarCache {
    private const val MAX_COUNT = 128
    private const val MAX_BYTES = 64 * 1024 * 1024

    /// Avatars are small uploads. Four megabytes is already absurd; more than
    /// that is a response doing something other than showing a face.
    private const val BYTE_LIMIT = 4 * 1024 * 1024
    private const val TIMEOUT_MS = 10_000

    private val decoded = object : LruCache<String, Bitmap>(MAX_BYTES) {
        override fun sizeOf(key: String, value: Bitmap): Int = value.byteCount
    }

    /// In-flight fetches, so two seats for one account share a single request
    /// instead of racing each other.
    private val pending = mutableMapOf<String, Deferred<Outcome>>()

    /// A picture, no picture, or no answer. Only the last is worth asking
    /// again: a 404 or a body that is not an image will say the same thing.
    private sealed interface Outcome {
        data class Picture(val bitmap: Bitmap) : Outcome
        data object Missing : Outcome
        data object Unreachable : Outcome
    }
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    /// Already decoded, or nil. Synchronous so the first frame can paint the
    /// picture instead of the letter when it is a cache hit.
    fun cached(url: String): Bitmap? = synchronized(decoded) { decoded.get(url.trim()) }

    /// The picture, asked for again while it cannot be reached.
    ///
    /// One timeout used to leave the letter on screen until something
    /// recomposed with a new key. A picture that is not there stops at once.
    /// One that could not be reached waits and tries again, backing off to
    /// every thirty seconds, for as long as the caller's coroutine runs. The
    /// composable's effect ends it when the avatar leaves the screen.
    suspend fun image(context: Context, url: String): Bitmap? {
        val key = url.trim()
        if (key.isEmpty()) return null
        var wait = 2_000L
        while (coroutineContext.isActive) {
            when (val outcome = attempt(context, key)) {
                is Outcome.Picture -> return outcome.bitmap
                Outcome.Missing -> return null
                Outcome.Unreachable -> {
                    delay(wait)
                    wait = (wait * 2).coerceAtMost(30_000L)
                }
            }
        }
        return null
    }

    private suspend fun attempt(context: Context, key: String): Outcome {
        cached(key)?.let { return Outcome.Picture(it) }
        val app = context.applicationContext
        val job = synchronized(pending) {
            pending[key] ?: scope.async(start = CoroutineStart.LAZY) {
                load(app, key)
            }.also { task ->
                pending[key] = task
                task.invokeOnCompletion {
                    synchronized(pending) { if (pending[key] === task) pending.remove(key) }
                }
                task.start()
            }
        }
        return job.await()
    }

    private fun load(context: Context, key: String): Outcome {
        cached(key)?.let { return Outcome.Picture(it) }
        val disk = diskFile(context, key)
        if (disk != null && disk.isFile) {
            val bitmap = runCatching {
                if (disk.length() > BYTE_LIMIT) null else decode(disk.readBytes())
            }.getOrNull()
            if (bitmap != null) {
                disk.setLastModified(System.currentTimeMillis())
                store(key, bitmap)
                return Outcome.Picture(bitmap)
            }
            disk.delete()
        }
        val fetched = download(key)
        if (fetched !is Outcome.Picture) return fetched
        val bitmap = fetched.bitmap
        store(key, bitmap)
        if (disk != null) runCatching {
            disk.parentFile?.mkdirs()
            val atomic = AtomicFile(disk)
            val output = atomic.startWrite()
            try {
                check(bitmap.compress(Bitmap.CompressFormat.PNG, 100, output))
                atomic.finishWrite(output)
            } catch (error: Exception) {
                atomic.failWrite(output)
                throw error
            }
            disk.parentFile?.listFiles()?.filter { it.isFile && !it.name.endsWith(".new") }
                ?.sortedByDescending { it.lastModified() }?.drop(MAX_COUNT)?.forEach { it.delete() }
        }
        return fetched
    }

    private fun decode(bytes: ByteArray): Bitmap? {
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeByteArray(bytes, 0, bytes.size, bounds)
        val sample = AvatarImageLimits.sampleSize(bounds.outWidth, bounds.outHeight) ?: return null
        return BitmapFactory.decodeByteArray(bytes, 0, bytes.size,
            BitmapFactory.Options().apply { inSampleSize = sample })
    }

    private fun store(key: String, bitmap: Bitmap) {
        synchronized(decoded) {
            decoded.put(key, bitmap)
            // LruCache trims by bytes on its own; the count cap trims the
            // eldest entries by hand, one per excess key.
            while (decoded.snapshot().size > MAX_COUNT && decoded.size() > 0) {
                decoded.trimToSize(decoded.size() - 1)
            }
        }
    }

    private fun diskFile(context: Context, key: String): File? {
        val digest = runCatching {
            MessageDigest.getInstance("SHA-256").digest(key.toByteArray(Charsets.UTF_8))
        }.getOrNull() ?: return null
        val name = digest.joinToString("") { "%02x".format(it) }
        return File(File(context.applicationContext.cacheDir, "avatars"), name)
    }

    /// Fetch and decode one avatar off the caller's thread. The download
    /// streams with a cap, so a body larger than the limit is rejected by its
    /// size before any of it is read into memory and decoded.
    private fun download(url: String): Outcome {
        val connection = runCatching { URL(url).openConnection() as HttpURLConnection }.getOrNull()
            ?: return Outcome.Missing
        return try {
            connection.connectTimeout = TIMEOUT_MS
            connection.readTimeout = TIMEOUT_MS
            connection.instanceFollowRedirects = true
            connection.connect()
            val status = connection.responseCode
            // Busy, rate limited or failing on the server's side: the same
            // request can succeed in a moment.
            if (status == 408 || status == 429 || status >= 500) return Outcome.Unreachable
            if (status !in 200..299) return Outcome.Missing
            val declared = connection.contentLengthLong
            if (declared > BYTE_LIMIT) return Outcome.Missing
            val out = ByteArrayOutputStream()
            connection.inputStream.use { input ->
                val buffer = ByteArray(32 * 1024)
                var total = 0L
                while (true) {
                    val read = input.read(buffer)
                    if (read < 0) break
                    total += read
                    if (total > BYTE_LIMIT) return Outcome.Missing
                    out.write(buffer, 0, read)
                }
            }
            val bytes = out.toByteArray()
            if (bytes.isEmpty()) return Outcome.Missing
            decode(bytes)?.let { Outcome.Picture(it) } ?: Outcome.Missing
        } catch (_: javax.net.ssl.SSLPeerUnverifiedException) {
            // A certificate the host cannot prove. Asking again gets the same.
            Outcome.Missing
        } catch (error: javax.net.ssl.SSLHandshakeException) {
            // A rejected certificate is permanent. A handshake cut short is
            // the network, and worth asking again.
            if (error.cause is java.security.cert.CertificateException) Outcome.Missing else Outcome.Unreachable
        } catch (_: java.net.ProtocolException) {
            // A redirect loop, or a 401 that offers no way to answer it.
            Outcome.Missing
        } catch (_: java.net.UnknownServiceException) {
            // A scheme this connection cannot speak, such as cleartext http.
            Outcome.Missing
        } catch (_: java.io.IOException) {
            // No route, a timeout, a dropped connection.
            Outcome.Unreachable
        } catch (_: Exception) {
            Outcome.Missing
        } finally {
            connection.disconnect()
        }
    }
}
