// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.workspace

import android.graphics.Bitmap
import android.graphics.Color
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import java.io.File
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import kotlinx.coroutines.async
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class ChatImageDecodeCacheTest {
    private fun fixture(): File = File(InstrumentationRegistry.getInstrumentation().targetContext.cacheDir,
        "image-cache-${java.util.UUID.randomUUID()}.png")

    private fun write(file: File, color: Int, width: Int = 96) {
        val bitmap = Bitmap.createBitmap(width, 64, Bitmap.Config.ARGB_8888)
        try {
            bitmap.eraseColor(color)
            file.outputStream().use { assertTrue(bitmap.compress(Bitmap.CompressFormat.PNG, 100, it)) }
        } finally { bitmap.recycle() }
    }

    @Test fun repeatedRowsSharePixelsWithoutFlatteningAlphaOrChangingOriginals() = runBlocking {
        val file = fixture()
        val calls = AtomicInteger()
        val cache = ChatImageDecodeCache(1024 * 1024) { source, edge ->
            calls.incrementAndGet(); decodeChatImage(source, edge)
        }
        try {
            write(file, Color.argb(96, 12, 200, 56))
            val original = file.readBytes()
            val image = cache.image(file, 128)!!
            repeat(20) { assertSame(image, cache.image(file, 128)) }
            assertEquals(1, calls.get())
            assertTrue(image.hasAlpha())
            assertTrue(Color.alpha(image.getPixel(0, 0)) in 95..97)
            assertArrayEquals(original, file.readBytes())
            assertNotSame(image, cache.image(file, 64))
            assertEquals(2, calls.get())
            file.delete()
            assertNull(cache.image(file, 128))
        } finally { cache.clear(); file.delete() }
    }

    @Test fun replacingSamePathAndTimestampCannotReuseOldPixels() = runBlocking {
        val file = fixture()
        val replacement = fixture()
        val cache = ChatImageDecodeCache(1024 * 1024)
        try {
            write(file, Color.RED)
            val before = cache.image(file, 128)!!
            val stamp = file.lastModified()
            write(replacement, Color.BLUE)
            assertTrue(replacement.setLastModified(stamp))
            assertTrue(replacement.renameTo(file))
            assertEquals(stamp, file.lastModified())
            val after = cache.image(file, 128)!!
            assertNotSame(before, after)
            assertEquals(Color.RED, before.getPixel(0, 0))
            assertEquals(Color.BLUE, after.getPixel(0, 0))
        } finally { cache.clear(); file.delete(); replacement.delete() }
    }

    @Test fun canceledReaderDoesNotCancelAnotherAndPressureDoesNotRepopulate() = runBlocking {
        val file = fixture()
        val gate = CountDownLatch(1)
        val calls = AtomicInteger()
        val cache = ChatImageDecodeCache(1024 * 1024) { source, edge ->
            calls.incrementAndGet()
            check(gate.await(10, TimeUnit.SECONDS))
            decodeChatImage(source, edge)
        }
        try {
            write(file, Color.GREEN)
            val first = async { cache.image(file, 128) }
            val second = async { cache.image(file, 128) }
            withTimeout(10_000) { while (cache.pendingReaders != 2) delay(1) }
            first.cancelAndJoin()
            assertEquals(1, cache.pendingReaders)
            cache.clear()
            gate.countDown()
            assertNotNull(second.await())
            assertEquals(1, calls.get())
            assertEquals(0, cache.retainedBytes)
            assertNotNull(cache.image(file, 128))
            assertEquals(2, calls.get())
        } finally { gate.countDown(); cache.clear(); file.delete() }
    }

    @Test fun byteBudgetEvictsWithoutRecyclingImagesStillOnScreen() = runBlocking {
        val first = fixture(); val second = fixture()
        val cache = ChatImageDecodeCache(96 * 64 * 4)
        try {
            write(first, Color.RED); write(second, Color.BLUE)
            val visible = cache.image(first, 128)!!
            val another = cache.image(second, 128)!!
            assertTrue(cache.retainedBytes <= 96 * 64 * 4)
            assertNotSame(visible, cache.image(first, 128))
            assertFalse(visible.isRecycled)
            assertFalse(another.isRecycled)
            assertEquals(Color.RED, visible.getPixel(0, 0))
            cache.clear()
            assertEquals(0, cache.retainedBytes)
            assertFalse(visible.isRecycled)
        } finally { cache.clear(); first.delete(); second.delete() }
    }

    @Test fun leavingTheLastQueuedRowSkipsItsDecodeAndWorkersStayBounded() = runBlocking {
        val files = List(3) { fixture() }
        val gate = CountDownLatch(1)
        val calls = AtomicInteger()
        val cache = ChatImageDecodeCache(1024 * 1024) { source, edge ->
            calls.incrementAndGet()
            check(gate.await(10, TimeUnit.SECONDS))
            decodeChatImage(source, edge)
        }
        try {
            files.forEach { write(it, Color.GREEN) }
            val visible = files.take(2).map { file -> async { cache.image(file, 128) } }
            withTimeout(10_000) { while (calls.get() != 2) delay(1) }
            val leaving = async { cache.image(files[2], 128) }
            withTimeout(10_000) { while (cache.pendingReaders != 3) delay(1) }
            assertEquals("at most two decoders run together", 2, calls.get())
            leaving.cancelAndJoin()
            gate.countDown()
            visible.forEach { assertNotNull(it.await()) }
            assertEquals("a canceled queued row never starts its decode", 2, calls.get())
            assertEquals(0, cache.pendingReaders)
        } finally { gate.countDown(); cache.clear(); files.forEach { it.delete() } }
    }
}
