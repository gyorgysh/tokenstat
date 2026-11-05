// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.workspace

import ai.tokenstat.tokenstat.core.CoreFailure
import kotlinx.coroutines.*
import kotlinx.coroutines.test.*
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class ChatInspectionPollingTest {
    @Test fun unsupportedHostsAreReadOncePerVisibleLease() = runTest {
        var calls = 0
        var failures = 0
        val poll = backgroundScope.launch {
            pollChatInspection({ calls++; throw CoreFailure("unknown_method", "unsupported") },
                { fail("Unsupported method published a snapshot") }, { failures++ })
        }
        runCurrent(); advanceTimeBy(30_000); runCurrent()
        assertEquals("Unsupported hosts should not receive repeated inspection reads", 1, calls)
        assertEquals(1, failures)
        assertTrue(poll.isCompleted)
        backgroundScope.launch { pollChatInspection({ calls++; throw CoreFailure("unknown_method", "unsupported") }, {}, {}) }
        runCurrent()
        assertEquals("A new visibility or owner lease probes capabilities again", 2, calls)
    }
    @Test fun transientFailuresKeepTheLastSnapshotAndRecoverOnSchedule() = runTest {
        var calls = 0
        var failures = 0
        val published = mutableListOf<JsonObject?>()
        val poll = backgroundScope.launch {
            pollChatInspection({
                calls++
                if (calls == 2) throw CoreFailure("offline", "connection unavailable")
                buildJsonObject { put("generation", calls) }
            }, { published += it }, { failures++ })
        }
        runCurrent()
        advanceTimeBy(4999); runCurrent(); assertEquals(1, calls)
        advanceTimeBy(1); runCurrent()
        assertEquals(1, failures); assertEquals(1, published.size)
        advanceTimeBy(5000); runCurrent()
        assertEquals(3, calls); assertEquals(2, published.size)
        assertEquals(3, published.last()?.get("generation")?.jsonPrimitive?.int)
        poll.cancel()
    }

    @Test fun cancelledNativeReadsCannotPublishSuccessOrFailure() = runTest {
        for (failRead in listOf(false, true)) {
            val finish = CompletableDeferred<Unit>()
            var publishes = 0
            val poll = backgroundScope.launch {
                pollChatInspection({
                    withContext(NonCancellable) {
                        finish.await()
                        if (failRead) throw CoreFailure("offline", "old response")
                        buildJsonObject { put("backend", "claude") }
                    }
                }, { publishes++ }, { publishes++ })
            }
            runCurrent(); poll.cancel(); finish.complete(Unit); runCurrent()
            assertTrue(poll.isCompleted)
            assertEquals("Retired native replies must not change the view", 0, publishes)
        }
    }

    @Test fun cancellingDuringTheDelayStopsFurtherReads() = runTest {
        var calls = 0
        val poll = backgroundScope.launch { pollChatInspection({ calls++; null }, {}, {}) }
        runCurrent(); poll.cancel(); advanceTimeBy(30_000); runCurrent()
        assertEquals(1, calls)
    }

    @Test fun arbitraryErrorMessagesDoNotDisableInspection() = runTest {
        var calls = 0
        val poll = backgroundScope.launch {
            pollChatInspection({ calls++; throw CoreFailure("offline", "unknown method in a provider message") }, {}, {})
        }
        runCurrent(); advanceTimeBy(5000); runCurrent()
        assertEquals(2, calls)
        poll.cancel()
    }

}
