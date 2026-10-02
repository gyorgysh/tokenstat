// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.ssh

import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.withContext
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class VaultOperationGuardTest {
    @Test fun accountChangeDuringReadDoesNotPublishOrWrite() = runTest {
        var currentOwner = "first"
        val guard = VaultOperationGuard { currentOwner == "first" }
        val entered = CompletableDeferred<Unit>()
        val released = CompletableDeferred<Unit>()
        var published = false
        var writes = 0
        val task = launch {
            guard.run { entered.complete(Unit); released.await(); "old account records" }
            published = true
            guard.run { writes += 1 }
        }
        entered.await()
        currentOwner = "second"
        released.complete(Unit)
        task.join()
        assertTrue(task.isCancelled)
        assertFalse(published)
        assertEquals(0, writes)
    }

    @Test fun staleSheetDoesNotStartARequest() = runTest {
        val guard = VaultOperationGuard { false }
        var requests = 0
        val task = launch { guard.run { requests += 1 } }
        task.join()
        assertTrue(task.isCancelled)
        assertEquals(0, requests)
    }

    @Test fun canceledScreenCannotContinueEvenIfItsReadIgnoresCancellation() = runTest {
        val guard = VaultOperationGuard { true }
        val entered = CompletableDeferred<Unit>()
        val released = CompletableDeferred<Unit>()
        var readFinished = false
        var published = false
        var writes = 0
        val task = launch {
            guard.run {
                withContext(NonCancellable) {
                    entered.complete(Unit)
                    released.await()
                    readFinished = true
                }
            }
            published = true
            guard.run { writes += 1 }
        }
        entered.await()
        task.cancel()
        released.complete(Unit)
        task.join()
        assertTrue(readFinished)
        assertTrue(task.isCancelled)
        assertFalse(published)
        assertEquals(0, writes)
    }
}
