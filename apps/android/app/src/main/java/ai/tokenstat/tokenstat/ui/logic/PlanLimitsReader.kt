// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.logic

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Deferred
import kotlinx.coroutines.async
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.serialization.json.JsonArray

/** Account-owned quota reads shared by Home and chat. A dismissed reader does not cancel other readers. */
internal class PlanLimitsReader<Owner : Any>(
    private val scope: CoroutineScope,
    private val owner: () -> Owner?,
    private val read: suspend (force: Boolean) -> JsonArray,
    private val publish: (Result<JsonArray>) -> Unit,
    private val now: () -> Long = { System.nanoTime() / 1_000_000 },
) {
    private data class Flight<Owner>(val owner: Owner, val task: Deferred<Unit>)
    private val mutex = Mutex()
    private var flight: Flight<Owner>? = null
    private var attemptedOwner: Owner? = null
    private var attemptedAt: Long? = null

    suspend fun retire() = mutex.withLock {
        flight?.task?.cancel()
        flight = null
        attemptedOwner = null
        attemptedAt = null
    }

    suspend fun refresh(force: Boolean = false) {
        val requested = owner() ?: return
        val task = mutex.withLock {
            if (owner() != requested) return@withLock null
            flight?.takeIf { it.owner == requested && !it.task.isCompleted }?.let { return@withLock it.task }
            val age = attemptedAt?.let { now() - it }
            if (!force && attemptedOwner == requested && age != null && age in 0 until 30_000) return@withLock null
            flight?.takeIf { it.owner != requested }?.task?.cancel()
            attemptedOwner = requested
            attemptedAt = now()
            val next = scope.async(start = CoroutineStart.LAZY) {
                if (owner() != requested) return@async
                val result = try { Result.success(read(force)) }
                catch (cancelled: CancellationException) { throw cancelled }
                catch (error: Exception) { Result.failure(error) }
                currentCoroutineContext().ensureActive()
                if (owner() == requested) publish(result)
            }
            flight = Flight(requested, next)
            next.start()
            next
        }
        task?.await()
    }
}
