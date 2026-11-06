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
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withTimeout
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonNull
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
    @Test fun consoleStatusCanFinishWithoutAnEofCapability() = runBlocking {
        val bridge = TerminalBridge()
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
        var reads = 0
        try {
            val job = bridge.startReadLoop("fixture", scope, request = { method, _ ->
                check(method == "pty.read") { "Read status needs no separate info call" }
                reads++
                delay(10)
                buildJsonObject { put("data", ""); put("nextOffset", 0); put("exitCode", 0) }
            }, output = { error("The console produced no output") })
            withTimeout(3_000) { job.join() }
            assertEquals(1, reads)
            assertEquals(0, bridge.exitCode)
        } finally { scope.cancel() }
    }

    @Test fun updatedHostsNeedNoSeparateStatusRequest() = runBlocking {
        val bridge = TerminalBridge()
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
        val expected = "Updated host ✓\n".toByteArray()
        val received = ByteArrayOutputStream()
        var quietReads = 0
        var infoReads = 0
        try {
            val job = bridge.startReadLoop("fixture", scope, request = { method, params ->
                when (method) {
                    "pty.read" -> {
                        val offset = (params["offset"] as JsonPrimitive).content.toInt()
                        if (offset > 0) { delay(40); quietReads++ }
                        buildJsonObject {
                            put("data", Base64.encodeToString(expected.copyOfRange(offset, expected.size), Base64.NO_WRAP))
                            put("nextOffset", expected.size)
                            if (offset > 0) {
                                if (quietReads < 3) {
                                    put("exitCode", JsonNull); put("outputEndOffset", JsonNull)
                                } else {
                                    put("exitCode", 0); put("outputEndOffset", expected.size)
                                }
                            }
                        }
                    }
                    "pty.info" -> {
                        infoReads++
                        if (quietReads < 3) buildJsonObject { put("alive", true) } else endedInfo()
                    }
                    else -> error("Unexpected request $method")
                }
            }, output = { received.write(Base64.decode(it, Base64.DEFAULT)) })
            withTimeout(3_000) { job.join() }
            assertArrayEquals(expected, received.toByteArray())
            assertEquals(0, infoReads)
            assertEquals(0, bridge.exitCode)
        } finally { scope.cancel() }
    }

    @Test fun parentExitDoesNotDiscardOutputFromAnOpenStream() = runBlocking {
        val bridge = TerminalBridge()
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
        val early = "early café\n".toByteArray()
        val late = "late 日本語\n".toByteArray()
        val expected = early + late
        val received = ByteArrayOutputStream()
        var quietReads = 0
        try {
            val job = bridge.startReadLoop("fixture", scope, request = { method, params ->
                check(method == "pty.read") { "Known status requires no separate query" }
                val offset = (params["offset"] as JsonPrimitive).content.toInt()
                if (offset == early.size) { delay(40); quietReads++ }
                val bytes = when {
                    offset == 0 -> early
                    offset == early.size && quietReads >= 4 -> late
                    else -> byteArrayOf()
                }
                // Process metadata can precede closure of inherited output.
                bridge.readInfo(endedInfo())
                buildJsonObject {
                    put("data", Base64.encodeToString(bytes, Base64.NO_WRAP))
                    put("nextOffset", offset + bytes.size)
                    if (bytes.isEmpty()) {
                        put("exitCode", 0)
                        if (offset < expected.size) put("outputEndOffset", JsonNull)
                        else put("outputEndOffset", expected.size)
                    }
                }
            }, output = { received.write(Base64.decode(it, Base64.DEFAULT)) })
            withTimeout(3_000) { job.join() }
            assertArrayEquals(expected, received.toByteArray())
            assertTrue(quietReads >= 4)
        } finally { scope.cancel() }
    }

    @Test fun unchangedStatusDoesNotRedrawTheTerminal() {
        val bridge = TerminalBridge()
        var changes = 0
        bridge.onProgress = { changes++ }
        bridge.readInfo(buildJsonObject { put("alive", true) })
        assertEquals(0, changes)
        val running = buildJsonObject {
            put("command", "shell")
            put("cwd", "/fixture")
            put("alive", true)
        }
        bridge.readInfo(running)
        assertEquals(1, changes)
        bridge.readInfo(running)
        assertEquals(1, changes)
        bridge.readInfo(endedInfo())
        assertEquals(2, changes)
        bridge.readInfo(endedInfo())
        bridge.readInfo(null)
        assertEquals(2, changes)
    }

    @Test fun aNaturalExitIsDetectedAfterSuccessfulReads() = runBlocking {
        val bridge = TerminalBridge()
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
        val received = ByteArrayOutputStream()
        val expected = "Natural exit ✓\n".toByteArray()
        var infoReads = 0
        try {
            val job = bridge.startReadLoop("fixture", scope, request = { method, params ->
                when (method) {
                    "pty.info" -> { infoReads++; endedInfo() }
                    "pty.read" -> {
                        val offset = (params["offset"] as JsonPrimitive).content.toInt()
                        if (offset == expected.size) delay(40)
                        buildJsonObject {
                            put("data", Base64.encodeToString(expected.copyOfRange(offset, expected.size), Base64.NO_WRAP))
                            put("nextOffset", expected.size)
                        }
                    }
                    else -> error("Unexpected request $method")
                }
            }, output = { received.write(Base64.decode(it, Base64.DEFAULT)) })
            withTimeout(2_000) { job.join() }
            assertArrayEquals(expected, received.toByteArray())
            assertEquals(1, infoReads)
            assertEquals(0, bridge.exitCode)
            assertTrue(!bridge.alive)
        } finally { scope.cancel() }
    }

    @Test fun failedMetadataIsRetriedWithoutFloodingOrEndingSuccessfulReads() = runBlocking {
        val bridge = TerminalBridge()
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
        val infoTimes = mutableListOf<Long>()
        try {
            val job = bridge.startReadLoop("fixture", scope, request = { method, _ ->
                when (method) {
                    "pty.read" -> {
                        delay(40)
                        buildJsonObject { put("data", ""); put("nextOffset", 0) }
                    }
                    "pty.info" -> {
                        infoTimes.add(System.nanoTime())
                        if (infoTimes.size == 1) throw java.io.IOException("Synthetic metadata failure")
                        endedInfo()
                    }
                    else -> error("Unexpected request $method")
                }
            }, output = { error("No output was produced") })
            withTimeout(4_000) { job.join() }
            assertEquals(2, infoTimes.size)
            assertTrue("Metadata checks must stay bounded", infoTimes[1] - infoTimes[0] >= 800_000_000L)
            assertEquals(0, bridge.exitCode)
            assertEquals(null, bridge.transportError)
        } finally { scope.cancel() }
    }

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
        for (pendingMethod in listOf("pty.read", "pty.info")) {
            val bridge = TerminalBridge()
            val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
            val started = CompletableDeferred<Unit>()
            var writes = 0
            var changes = 0
            bridge.onProgress = { changes++ }
            try {
                val job = bridge.startReadLoop("fixture", scope, request = { method, _ ->
                    if (method == pendingMethod) {
                        started.complete(Unit)
                        suspendCancellableCoroutine { }
                    } else buildJsonObject { put("data", ""); put("nextOffset", 0) }
                }, output = { writes++ })
                withTimeout(5_000) { started.await() }
                bridge.stopJobs()
                withTimeout(5_000) { job.join() }
                assertTrue(job.isCancelled)
                assertEquals(0, writes)
                assertEquals(0, changes)
                assertEquals(null, bridge.exitCode)
                assertEquals(null, bridge.transportError)
            } finally { scope.cancel() }
        }
    }

    @Test fun aLateReplyCannotWriteIntoTheReplacementPage() = runBlocking {
        for (pendingMethod in listOf("pty.read", "pty.info")) {
            val bridge = TerminalBridge()
            val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
            val pending = CompletableDeferred<Continuation<kotlinx.serialization.json.JsonElement>>()
            var writes = 0
            var changes = 0
            bridge.onProgress = { changes++ }
            try {
                val job = bridge.startReadLoop("fixture", scope, request = { method, _ ->
                    if (method == pendingMethod) suspendCoroutine { pending.complete(it) }
                    else buildJsonObject { put("data", ""); put("nextOffset", 0) }
                }, output = { writes++ })
                val release = withTimeout(5_000) { pending.await() }
                bridge.stopJobs()
                release.resume(if (pendingMethod == "pty.info") endedInfo() else buildJsonObject {
                    put("data", Base64.encodeToString("old output".toByteArray(), Base64.NO_WRAP))
                    put("nextOffset", 10)
                })
                withTimeout(5_000) { job.join() }
                assertTrue(job.isCancelled)
                assertEquals(0, writes)
                assertEquals(0, changes)
                assertEquals(null, bridge.exitCode)
                assertEquals(null, bridge.transportError)
            } finally { scope.cancel() }
        }
    }

    private fun endedInfo(): JsonObject = buildJsonObject {
        put("alive", false)
        put("exitCode", 0)
    }
}
