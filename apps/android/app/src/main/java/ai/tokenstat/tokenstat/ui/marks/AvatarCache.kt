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

object AvatarCache {
    private const val MAX_COUNT = 128
    private const val MAX_BYTES = 64 * 1024 * 1024

    private const val BYTE_LIMIT = 4 * 1024 * 1024
    private const val TIMEOUT_MS = 10_000

    private val decoded = object : LruCache<String, Bitmap>(MAX_BYTES) {
        override fun sizeOf(key: String, value: Bitmap): Int = value.byteCount
    }

    private val pending = mutableMapOf<String, Deferred<Outcome>>()

    private sealed interface Outcome {
        data class Picture(val bitmap: Bitmap) : Outcome
        data object Missing : Outcome
        data object Unreachable : Outcome
    }
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    fun cached(url: String): Bitmap? = synchronized(decoded) { decoded.get(url.trim()) }

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

    private fun download(url: String): Outcome {
        val connection = runCatching { URL(url).openConnection() as HttpURLConnection }.getOrNull()
            ?: return Outcome.Missing
        return try {
            connection.connectTimeout = TIMEOUT_MS
            connection.readTimeout = TIMEOUT_MS
            connection.instanceFollowRedirects = true
            connection.connect()
            val status = connection.responseCode
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
            Outcome.Missing
        } catch (error: javax.net.ssl.SSLHandshakeException) {
            if (error.cause is java.security.cert.CertificateException) Outcome.Missing else Outcome.Unreachable
        } catch (_: java.net.ProtocolException) {
            Outcome.Missing
        } catch (_: java.net.UnknownServiceException) {
            Outcome.Missing
        } catch (_: java.io.IOException) {
            Outcome.Unreachable
        } catch (_: Exception) {
            Outcome.Missing
        } finally {
            connection.disconnect()
        }
    }
}
