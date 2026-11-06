// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.terminal

import android.util.Base64
import androidx.test.ext.junit.runners.AndroidJUnit4
import java.io.ByteArrayOutputStream
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withTimeout
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import kotlin.coroutines.Continuation
import kotlin.coroutines.resume
import kotlin.coroutines.suspendCoroutine

@RunWith(AndroidJUnit4::class)
class TerminalOutputDrainingTest {
    @Test fun exitedProcessRetainsEveryPageIncludingRecovery() = runBlocking {
        for (failuresAfterExit in listOf(0, 2, 8)) {
            val bridge = TerminalBridge()
            val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
            try {
                val expected = ("café 日本語 terminal output\n".repeat(16_000) + "FINAL MARKER\n").toByteArray()
                val received = ByteArrayOutputStream()
                var failures = 0
                var reads = 0
                val job = bridge.startReadLoop("fixture", scope, request = { method, params ->
                    when (method) {
                        "pty.info" -> endedInfo()
                        "pty.read" -> {
                            reads++
                            val offset = (params["offset"] as JsonPrimitive).content.toInt()
                            if (offset > 0 && failures < failuresAfterExit) {
                                failures++
                                throw IllegalStateException("Synthetic transport interruption")
                            }
                            val end = minOf(expected.size, offset + 64 * 1024)
                            bridge.readInfo(endedInfo())
                            buildJsonObject {
                                put("data", Base64.encodeToString(expected.copyOfRange(offset, end), Base64.NO_WRAP))
                                put("nextOffset", end)
                                put("dropped", 0)
                                put("paused", false)
                            }
                        }
                        else -> error("Unexpected request $method")
                    }
                }, output = { received.write(Base64.decode(it, Base64.DEFAULT)) })
                withTimeout(15_000) { job.join() }
                assertTrue("Must drain more than the first page", reads > 2)
                assertArrayEquals(expected, received.toByteArray())
                assertEquals(failuresAfterExit, failures)
                assertEquals(0, bridge.exitCode)
                assertEquals(null, bridge.transportError)
            } finally { scope.cancel() }
        }
    }

    @Test fun closingThePageCancelsAnOutstandingRead() = runBlocking {
        val bridge = TerminalBridge()
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
        val started = CompletableDeferred<Unit>()
        var writes = 0
        var changes = 0
        bridge.onProgress = { changes++ }
        try {
            val job = bridge.startReadLoop("fixture", scope, request = { _, _ ->
                started.complete(Unit)
                suspendCancellableCoroutine { }
            }, output = { writes++ })
            withTimeout(5_000) { started.await() }
            bridge.stopJobs()
            withTimeout(5_000) { job.join() }
            assertTrue(job.isCancelled)
            assertEquals(0, writes)
            assertEquals(0, changes)
            assertEquals(null, bridge.transportError)
        } finally { scope.cancel() }
    }

    @Test fun aLateReplyCannotWriteIntoTheReplacementPage() = runBlocking {
        val bridge = TerminalBridge()
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
        val pending = CompletableDeferred<Continuation<kotlinx.serialization.json.JsonElement>>()
        var writes = 0
        var changes = 0
        bridge.onProgress = { changes++ }
        try {
            val job = bridge.startReadLoop("fixture", scope, request = { _, _ ->
                suspendCoroutine { pending.complete(it) }
            }, output = { writes++ })
            val release = withTimeout(5_000) { pending.await() }
            bridge.stopJobs()
            release.resume(buildJsonObject {
                put("data", Base64.encodeToString("old output".toByteArray(), Base64.NO_WRAP))
                put("nextOffset", 10)
            })
            withTimeout(5_000) { job.join() }
            assertTrue(job.isCancelled)
            assertEquals(0, writes)
            assertEquals(0, changes)
            assertEquals(null, bridge.transportError)
        } finally { scope.cancel() }
    }

    private fun endedInfo(): JsonObject = buildJsonObject {
        put("alive", false)
        put("exitCode", 0)
    }
}
