// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.screen

import java.io.ByteArrayInputStream
import java.io.InputStream
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.runTest
import org.junit.Assert.*
import org.junit.Test

class ScreenFileHashTest {
    @Test fun hashingRunsOffTheCallerAndReadsProvidersReturningZero() = runTest {
        val caller = Thread.currentThread()
        var worker: Thread? = null
        var closed = false
        val result = hashScreenFile {
            worker = Thread.currentThread()
            object : ByteArrayInputStream("abc".toByteArray()) {
                override fun read(bytes: ByteArray, offset: Int, length: Int) = 0
                override fun close() { closed = true; super.close() }
            }
        }
        assertNotSame(caller, worker)
        assertTrue(closed)
        assertEquals(3L, result.size)
        assertEquals("ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", result.sha256)
    }

    @Test fun cancellationClosesAnUnendingProvider() = runTest {
        val opened = CompletableDeferred<Unit>()
        val closed = CompletableDeferred<Unit>()
        val job = launch {
            hashScreenFile {
                object : InputStream() {
                    init { opened.complete(Unit) }
                    override fun read() = 1
                    override fun read(bytes: ByteArray, offset: Int, length: Int): Int {
                        bytes[offset] = 1
                        return 1
                    }
                    override fun close() { closed.complete(Unit) }
                }
            }
        }
        opened.await()
        job.cancelAndJoin()
        assertTrue(closed.isCompleted)
    }
}
