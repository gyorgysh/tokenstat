// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.workspace

import kotlinx.coroutines.*
import kotlinx.coroutines.test.*
import org.junit.Assert.*
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class ChatPollReadsTest {
    @Test fun independentReadsOverlapWithoutChangingTheCatchupHint() = runTest {
        val started = currentTime
        val more = chatPollReads(
            events = { delay(200); true }, // History and approval round trips.
            status = { delay(100) },
        )
        assertTrue(more)
        assertEquals(200L, currentTime - started)
    }

    @Test fun queueWorkWaitsForBothReads() = runTest {
        val releaseEvents = CompletableDeferred<Unit>()
        val releaseStatus = CompletableDeferred<Unit>()
        var eventsStarted = false
        var statusStarted = false
        var queueWork = false
        val poll = launch {
            val more = chatPollReads(
                { eventsStarted = true; releaseEvents.await(); false },
                { statusStarted = true; releaseStatus.await() },
            )
            assertFalse(more)
            queueWork = true
        }
        runCurrent()
        assertTrue(eventsStarted && statusStarted)
        releaseEvents.complete(Unit); runCurrent()
        assertFalse(queueWork)
        releaseStatus.complete(Unit); poll.join()
        assertTrue(queueWork)
    }

    @Test fun cancellationStopsBothReadsAndDoesNotDrainQueue() = runTest {
        var eventsStopped = false
        var statusStopped = false
        var queueWork = false
        val poll = launch {
            chatPollReads(
                { try { awaitCancellation() } finally { eventsStopped = true } },
                { try { awaitCancellation() } finally { statusStopped = true } },
            )
            queueWork = true
        }
        runCurrent(); poll.cancelAndJoin()
        assertTrue(eventsStopped && statusStopped)
        assertFalse(queueWork)
    }
}
