// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.workspace

import ai.tokenstat.tokenstat.ui.logic.HostContracts
import java.io.IOException
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.currentTime
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

@OptIn(kotlinx.coroutines.ExperimentalCoroutinesApi::class)
class WorkspaceHostProtocolTest {
    private val currentHost = Json.parseToJsonElement("""{"protocolVersion":"30","coreVersion":"1.2.0"}""")

    @Test
    fun `live daemon response enables controls absent from account machine record`() = runTest {
        val machine = Json.parseToJsonElement("""{"id":"computer-1","kind":"host"}""").jsonObject
        assertNull(HostContracts.protocolOf(machine))
        var protocol: Long? = null
        probeWorkspaceHostProtocol(read = { currentHost }, onRead = { protocol = it })
        assertTrue(HostContracts.supportsReviewedPull(protocol))
        assertTrue(HostContracts.supportsPullCreation(protocol))
        assertTrue(HostContracts.supportsChatQuestions(protocol))
    }

    @Test
    fun `known older computer keeps only its supported controls without retrying`() = runTest {
        var reads = 0
        var protocol: Long? = null
        probeWorkspaceHostProtocol(
            read = { reads++; Json.parseToJsonElement("""{"protocolVersion":"28"}""") },
            onRead = { protocol = it },
        )
        assertEquals(1, reads)
        assertTrue(HostContracts.supportsPullCreation(protocol))
        assertFalse(HostContracts.supportsReviewedPull(protocol))
        assertFalse(HostContracts.supportsChatQuestions(protocol))
    }

    @Test
    fun `temporary tunnel failure retries and enables controls in the same visit`() = runTest {
        var reads = 0
        var protocol: Long? = null
        probeWorkspaceHostProtocol(
            read = { if (++reads == 1) throw IOException("tunnel unavailable") else currentHost },
            onRead = { protocol = it },
        )
        assertEquals(2, reads)
        assertEquals(1_000L, currentTime)
        assertEquals(30L, protocol)
    }

    @Test
    fun `missing or malformed replies retry without opening unsupported controls`() = runTest {
        val replies = listOf(null, Json.parseToJsonElement("[]"),
            Json.parseToJsonElement("""{"protocolVersion":{}}"""), currentHost)
        var reads = 0
        var protocol: Long? = null
        probeWorkspaceHostProtocol(
            read = {
                assertFalse(HostContracts.supportsReviewedPull(protocol))
                replies[reads++]
            },
            onRead = { protocol = it },
        )
        assertEquals(4, reads)
        assertEquals(30L, protocol)
    }

    @Test
    fun `repeated failures back off to avoid polling a sleeping computer rapidly`() = runTest {
        val times = mutableListOf<Long>()
        probeWorkspaceHostProtocol(
            read = { times.add(currentTime); if (times.size < 8) null else currentHost },
            onRead = {},
        )
        assertEquals(listOf(0L, 1_000L, 3_000L, 7_000L, 15_000L, 25_000L, 35_000L, 45_000L), times)
    }

    @Test
    fun `leaving during backoff stops reads and leaves capabilities unknown`() = runTest {
        var reads = 0
        var protocol: Long? = null
        val job = launch {
            probeWorkspaceHostProtocol(read = { reads++; null }, onRead = { protocol = it })
        }
        runCurrent()
        job.cancel()
        advanceTimeBy(60_000)
        runCurrent()
        assertEquals(1, reads)
        assertNull(protocol)
        assertTrue(job.isCancelled)
    }

    @Test
    fun `late native response cannot publish after account or computer changes`() = runTest {
        val reply = CompletableDeferred<Unit>()
        var protocol: Long? = null
        val job = launch {
            probeWorkspaceHostProtocol(
                read = { withContext(NonCancellable) { reply.await(); currentHost } },
                onRead = { protocol = it },
            )
        }
        runCurrent()
        job.cancel()
        reply.complete(Unit)
        job.join()
        assertTrue(job.isCancelled)
        assertNull(protocol)
    }

    @Test
    fun `read cancellation propagates without retrying`() = runTest {
        var reads = 0
        try {
            probeWorkspaceHostProtocol(
                read = { reads++; throw CancellationException("visit ended") },
                onRead = { fail("Cancelled read published capabilities") },
            )
            fail("Cancellation was swallowed")
        } catch (cancelled: CancellationException) {
            assertEquals("visit ended", cancelled.message)
        }
        assertEquals(1, reads)
    }
}
