// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.workspace

import android.content.ComponentCallbacks2
import android.content.Context
import android.content.res.Configuration
import android.graphics.Bitmap
import android.system.Os
import android.system.OsConstants
import android.util.LruCache
import java.io.File
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Deferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.sync.Semaphore
import kotlinx.coroutines.sync.withPermit
import kotlinx.coroutines.withContext
import kotlin.coroutines.coroutineContext

/** Lazy rows share bounded decoded previews instead of decoding on every return. */
internal class ChatImageDecodeCache(
    private val maxBytes: Int,
    private val decode: (File, Int) -> Bitmap = ::decodeChatImage,
) {
    private data class Version(
        val path: String, val device: Long, val inode: Long, val bytes: Long,
        val modifiedSeconds: Long, val modifiedNanos: Long,
        val changedSeconds: Long, val changedNanos: Long, val edge: Int,
    )
    private class Flight(val task: Deferred<Bitmap?>, var readers: Int = 0)
    private val lock = Any()
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val slots = Semaphore(2)
    private var generation = 0L
    private val pending = mutableMapOf<Version, Flight>()
    private val decoded = object : LruCache<Version, Bitmap>(maxBytes) {
        override fun sizeOf(key: Version, value: Bitmap) = value.allocationByteCount
    }

    init { require(maxBytes > 0) }

    suspend fun image(file: File, edge: Int): Bitmap? {
        require(edge in 1..4096)
        val version = withContext(Dispatchers.IO) { version(file, edge) } ?: return null
        val flight = synchronized(lock) {
            decoded.get(version)?.let { return it }
            val current = pending[version] ?: run {
                val stamp = generation
                val task = scope.async(start = CoroutineStart.LAZY) {
                    slots.withPermit {
                        coroutineContext.ensureActive()
                        val bitmap = try { decode(file, edge) }
                        catch (cancelled: CancellationException) { throw cancelled }
                        catch (_: Exception) { return@withPermit null }
                        coroutineContext.ensureActive()
                        // A replacement at the same path must never populate
                        // an older key. Originals on disk stay untouched.
                        if (version(file, edge) != version) return@withPermit null
                        synchronized(lock) {
                            if (generation == stamp && bitmap.allocationByteCount <= maxBytes) {
                                decoded.put(version, bitmap)
                            }
                        }
                        bitmap
                    }
                }
                Flight(task).also { pending[version] = it; task.start() }
            }
            current.readers++
            current
        }
        return try { flight.task.await() }
        finally {
            synchronized(lock) {
                if (pending[version] === flight && --flight.readers == 0) {
                    pending.remove(version)
                    // One disappearing row cannot cancel another reader.
                    // With none left, queued work should leave with the row.
                    flight.task.cancel()
                }
            }
        }
    }

    fun clear() = synchronized(lock) {
        generation++
        decoded.evictAll()
    }

    internal val retainedBytes: Int get() = synchronized(lock) { decoded.size() }
    internal val pendingReaders: Int get() = synchronized(lock) { pending.values.sumOf { it.readers } }

    private fun version(file: File, edge: Int): Version? = try {
        val path = file.absolutePath
        val stat = Os.stat(path)
        if (!OsConstants.S_ISREG(stat.st_mode)) null else Version(path, stat.st_dev, stat.st_ino,
            stat.st_size, stat.st_mtim.tv_sec, stat.st_mtim.tv_nsec,
            stat.st_ctim.tv_sec, stat.st_ctim.tv_nsec, edge)
    } catch (_: Exception) { null }
}

internal object ChatImageCache {
    private var installed = false
    private val cache = ChatImageDecodeCache(minOf(24L * 1024 * 1024,
        (Runtime.getRuntime().maxMemory() / 16).coerceAtLeast(4L * 1024 * 1024)).toInt())

    @Suppress("DEPRECATION", "OVERRIDE_DEPRECATION") // Still delivered on supported Android 9–13 devices.
    @Synchronized fun shared(context: Context): ChatImageDecodeCache {
        if (!installed) {
            context.applicationContext.registerComponentCallbacks(object : ComponentCallbacks2 {
                override fun onConfigurationChanged(configuration: Configuration) = Unit
                override fun onLowMemory() = cache.clear()
                override fun onTrimMemory(level: Int) {
                    if (level >= ComponentCallbacks2.TRIM_MEMORY_RUNNING_LOW) cache.clear()
                }
            })
            installed = true
        }
        return cache
    }
}
