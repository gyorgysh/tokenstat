// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.logic

import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.async
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonPrimitive
import org.junit.Assert.*
import org.junit.Test

@OptIn(kotlinx.coroutines.ExperimentalCoroutinesApi::class)
class PlanLimitsReaderTest {
    private fun value(n: Int) = JsonArray(listOf(JsonPrimitive(n)))

    @Test fun simultaneousReadersShareARequestAndOnlyForceBypassesTheThirtySecondCache() = runTest {
        var calls = 0
        var milliseconds = 0L
        val pending = CompletableDeferred<JsonArray>()
        val published = mutableListOf<JsonArray>()
        val reader = PlanLimitsReader(backgroundScope, { "account" }, { force ->
            calls++; if (calls == 1) pending.await() else value(if (force) 2 else 3)
        }, { published += it.getOrThrow() }, { milliseconds })
        val home = async { reader.refresh() }
        val chat = async { reader.refresh() }
        val explicitRefresh = async { reader.refresh(true) }
        runCurrent()
        assertEquals(1, calls)
        pending.complete(value(1))
        home.await(); chat.await(); explicitRefresh.await()
        assertEquals(listOf(value(1)), published)
        repeat(100) { reader.refresh() }
        assertEquals(1, calls)
        reader.refresh(true)
        assertEquals(value(2), published.last())
        milliseconds = 30_000
        reader.refresh()
        assertEquals(value(3), published.last())
        assertEquals(3, calls)
    }

    @Test fun leavingOneScreenDoesNotCancelTheSharedRead() = runTest {
        var calls = 0
        val pending = CompletableDeferred<JsonArray>()
        val results = mutableListOf<JsonArray>()
        val reader = PlanLimitsReader(backgroundScope, { "account" }, { calls++; pending.await() }, { results += it.getOrThrow() })
        val leaving = async { reader.refresh() }
        val staying = async { reader.refresh() }
        runCurrent(); leaving.cancel(); runCurrent()
        pending.complete(value(1)); staying.await()
        assertEquals(1, calls)
        assertEquals(listOf(value(1)), results)
    }

    @Test fun lateResultsCannotCrossAccountOrLoginEpochChanges() = runTest {
        var owner: String? = "account-a/1"
        val old = CompletableDeferred<JsonArray>()
        val fresh = CompletableDeferred<JsonArray>()
        val results = mutableListOf<JsonArray>()
        var calls = 0
        val reader = PlanLimitsReader(backgroundScope, { owner }, {
            calls++
            // A native response may return even after its caller was cancelled.
            withContext(NonCancellable) { if (calls == 1) old.await() else fresh.await() }
        }, { results += it.getOrThrow() })
        val first = async { reader.refresh() }; runCurrent()
        owner = "account-a/2"
        val second = async { reader.refresh() }; runCurrent()
        fresh.complete(value(2)); second.await()
        old.complete(value(1)); runCurrent()
        assertEquals(listOf(value(2)), results)
        owner = null
        reader.refresh(true)
        assertEquals(2, calls)
        first.cancel()
    }

    @Test fun failedReadsAreThrottledButExplicitRetryCanRecover() = runTest {
        var calls = 0
        val results = mutableListOf<Result<JsonArray>>()
        val reader = PlanLimitsReader(backgroundScope, { "account" }, {
            if (++calls == 1) error("offline") else value(2)
        }, { results += it })
        reader.refresh(); reader.refresh()
        assertEquals(1, calls)
        assertTrue(results.single().isFailure)
        reader.refresh(true)
        assertEquals(value(2), results.last().getOrThrow())
    }
    @Test fun anOwnerChangeRejectsSuccessAndFailureWithoutAnotherRefresh() = runTest {
        for (failure in listOf(false, true)) {
            var owner: String? = "old-account"
            val pending = CompletableDeferred<JsonArray>()
            val results = mutableListOf<Result<JsonArray>>()
            val reader = PlanLimitsReader(backgroundScope, { owner }, { pending.await() }, { results += it })
            val read = async { reader.refresh() }; runCurrent()
            owner = "new-account"
            if (failure) pending.completeExceptionally(IllegalStateException("old failure")) else pending.complete(value(1))
            read.await()
            assertTrue(results.isEmpty())
        }
    }

    @Test fun logoutCancelsTheReadAndANewLoginDoesNotWaitForTheCache() = runTest {
        val first = CompletableDeferred<JsonArray>()
        var calls = 0
        val results = mutableListOf<JsonArray>()
        val reader = PlanLimitsReader(backgroundScope, { "account" }, {
            if (++calls == 1) first.await() else value(2)
        }, { results += it.getOrThrow() })
        val read = async { reader.refresh() }; runCurrent()
        reader.retire(); runCurrent()
        assertTrue(read.isCancelled)
        reader.refresh()
        assertEquals(2, calls)
        assertEquals(listOf(value(2)), results)
    }

    @Test fun aRetiredNativeReadCannotPublishEvenIfItSwallowsCancellation() = runTest {
        val pending = CompletableDeferred<JsonArray>()
        val results = mutableListOf<JsonArray>()
        val reader = PlanLimitsReader(backgroundScope, { "account" }, {
            try { pending.await() }
            catch (_: kotlinx.coroutines.CancellationException) { value(1) }
        }, { results += it.getOrThrow() })
        val caller = async { reader.refresh() }; runCurrent()
        reader.retire(); runCurrent()
        assertTrue(caller.isCancelled)
        assertTrue(results.isEmpty())
    }

}
