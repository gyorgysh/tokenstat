// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.browser

import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.async
import kotlinx.coroutines.test.runTest
import org.junit.Assert.*
import org.junit.Test

@OptIn(kotlinx.coroutines.ExperimentalCoroutinesApi::class)
class BrowserListenersTest {
    private val first = BrowserTarget.port(3000)!!
    private fun endpoint(target: BrowserTarget) = BrowserListenerPool.Endpoint("peer", target.host, target.port)

    @Test fun `closing one of two shared leases and closing it twice keeps the other preview alive`() = runTest {
        val pool = BrowserListenerPool()
        var listens = 0
        var retires = 0
        suspend fun acquire() = pool.acquire(endpoint(first), "account-a", { true },
            { listens++; "http://127.0.0.1:49000/" }, { retires++ })!!
        val a = acquire()
        val b = acquire()
        assertEquals(1, listens)
        pool.release(a)
        pool.release(a)
        assertEquals(0, retires)
        pool.release(b)
        assertEquals(1, retires)
    }

    @Test fun `a reopened endpoint waits for the old unlisten to finish`() = runTest {
        val pool = BrowserListenerPool()
        val retiring = CompletableDeferred<Unit>()
        val finish = CompletableDeferred<Unit>()
        var listens = 0
        val old = pool.acquire(endpoint(first), "account-a", { true }, { listens++; "http://127.0.0.1:49000/" },
            { retiring.complete(Unit); finish.await() })!!
        val close = async { pool.release(old) }
        retiring.await()
        val reopen = async { pool.acquire(endpoint(first), "account-a", { true },
            { listens++; "http://127.0.0.1:49001/" }, {}) }
        testScheduler.runCurrent()
        assertEquals(1, listens)
        assertFalse(reopen.isCompleted)
        finish.complete(Unit)
        close.await()
        assertEquals("http://127.0.0.1:49001/", reopen.await()!!.listenerUrl)
        assertEquals(2, listens)
    }

    @Test fun `ownership is rechecked after waiting for an old endpoint retirement`() = runTest {
        val pool = BrowserListenerPool()
        val retiring = CompletableDeferred<Unit>()
        val finish = CompletableDeferred<Unit>()
        val old = pool.acquire(endpoint(first), "account-a", { true }, { "http://127.0.0.1:49000/" },
            { retiring.complete(Unit); finish.await() })!!
        val close = async { pool.release(old) }
        retiring.await()
        var current = true
        var listens = 0
        val reopen = async { pool.acquire(endpoint(first), "account-a", { current }, { listens++; "http://127.0.0.1:49001/" }, {}) }
        testScheduler.runCurrent()
        current = false
        finish.complete(Unit)
        close.await()
        assertNull(reopen.await())
        assertEquals(0, listens)
    }

    @Test fun `a listener arriving after ownership changes is retired without publishing a lease`() = runTest {
        val pool = BrowserListenerPool()
        val started = CompletableDeferred<Unit>()
        val finish = CompletableDeferred<Unit>()
        var current = true
        var retires = 0
        val pending = async { pool.acquire(endpoint(first), "account-a", { current },
            { started.complete(Unit); finish.await(); "http://127.0.0.1:49000/" }, { retires++ }) }
        started.await()
        current = false
        finish.complete(Unit)
        assertNull(pending.await())
        assertEquals(1, retires)
    }

    @Test fun `changing many ports holds one endpoint and Back reacquires the canonical original`() = runTest {
        val pool = BrowserListenerPool()
        val live = mutableSetOf<BrowserListenerPool.Endpoint>()
        var port = 49000
        suspend fun acquire(target: BrowserTarget, current: () -> Boolean): BrowserListenerPool.Lease? {
            val key = endpoint(target)
            return pool.acquire(key, "account-a", current, { assertTrue("Retire the old port before requesting another", live.isEmpty()); live.add(key); "http://127.0.0.1:${port++}/" }, { live.remove(key); Unit })
        }
        val initial = acquire(first) { true }!!
        val session = BrowserListenerSession(first, initial, { true }, ::acquire, pool)
        val originalProxy = first.through(initial.listenerUrl)!!
        for (number in 3001..3020) {
            session.open(BrowserTarget.port(number)!!)
            assertEquals(setOf(endpoint(BrowserTarget.port(number)!!)), live)
        }
        assertFalse(session.isCurrentProxy(originalProxy))
        assertEquals(BrowserListenerSession.Route.Open, session.route(originalProxy, true, "GET"))
        assertEquals(first, session.original(originalProxy))
        val reopened = session.open(session.original(originalProxy)!!)!!
        assertNotEquals(originalProxy, reopened)
        assertTrue(session.isCurrentProxy(reopened))
        assertEquals(first, session.original(reopened))
        assertEquals(setOf(endpoint(first)), live)
        session.close()
        assertTrue(live.isEmpty())
    }

    @Test fun `close during an acquisition retires the late result and rejects queued opens`() = runTest {
        val pool = BrowserListenerPool()
        val live = mutableSetOf<BrowserListenerPool.Endpoint>()
        val started = CompletableDeferred<Unit>()
        val finish = CompletableDeferred<Unit>()
        var listens = 0
        suspend fun acquire(target: BrowserTarget, current: () -> Boolean) = pool.acquire(endpoint(target), "account-a", current,
            {
                listens++
                if (target.port == 3001) { started.complete(Unit); finish.await() }
                live.add(endpoint(target))
                "http://127.0.0.1:${49000 + target.port}/"
            }, { live.remove(endpoint(target)); Unit })
        val initial = acquire(first) { true }!!
        val session = BrowserListenerSession(first, initial, { true }, ::acquire, pool)
        val pending = async { session.open(BrowserTarget.port(3001)!!) }
        started.await()
        val close = async { session.close() }
        val queued = async { session.open(BrowserTarget.port(3002)!!) }
        testScheduler.runCurrent()
        assertFalse(session.isCurrent)
        finish.complete(Unit)
        assertNull(pending.await())
        close.await()
        assertNull(queued.await())
        assertEquals(2, listens)
        assertTrue(live.isEmpty())
        assertNull(session.open(first))
    }

    @Test fun `only main frame GET may reopen unmapped loopback and live proxy requests retain their methods`() = runTest {
        val pool = BrowserListenerPool()
        val lease = pool.acquire(endpoint(first), "account-a", { true }, { "http://127.0.0.1:49000/" }, {})!!
        val session = BrowserListenerSession(first, lease, { true }, { _, _ -> error("Not opened") }, pool)
        assertEquals(BrowserListenerSession.Route.Open, session.route("http://localhost:5173/", true, "GET"))
        assertEquals(BrowserListenerSession.Route.Block, session.route("http://localhost:5173/", true, "POST"))
        assertEquals(BrowserListenerSession.Route.Block, session.route("http://localhost:5173/", false, "GET"))
        assertEquals(BrowserListenerSession.Route.Block, session.route("http://localhost:5173/", false, null))
        assertEquals(BrowserListenerSession.Route.Direct, session.route("http://127.0.0.1:49000/form", true, "POST"))
        assertEquals(BrowserListenerSession.Route.Direct, session.route("http://127.0.0.1:49000/frame", false, "GET"))
        assertEquals(BrowserListenerSession.Route.Direct, session.route("https://tokenstat.ai/", true, "GET"))
        session.close()
        assertEquals(BrowserListenerSession.Route.Block, session.route("http://127.0.0.1:49000/", true, "GET"))
    }


    @Test fun `another account retires the shared physical endpoint and stale release cannot close its replacement`() = runTest {
        val pool = BrowserListenerPool()
        var aRetires = 0
        var bRetires = 0
        val a = pool.acquire(endpoint(first), "account-a", { true }, { "http://127.0.0.1:49000/" }, { aRetires++ })!!
        val anotherProject = pool.acquire(endpoint(first), "account-a", { true }, { error("Same account must share") }, {})!!
        assertEquals(a.listenerUrl, anotherProject.listenerUrl)
        val b = pool.acquire(endpoint(first), "account-b", { true }, {
            assertEquals(1, aRetires)
            "http://127.0.0.1:49001/"
        }, { bRetires++ })!!
        assertNotEquals(a.listenerUrl, b.listenerUrl)
        pool.release(a)
        pool.release(anotherProject)
        assertEquals(0, bRetires)
        pool.release(b)
        assertEquals(1, bRetires)
    }


    @Test fun `account replacement checks ownership again after physical retirement`() = runTest {
        val pool = BrowserListenerPool()
        val retiring = CompletableDeferred<Unit>()
        val finish = CompletableDeferred<Unit>()
        val a = pool.acquire(endpoint(first), "account-a", { true }, { "http://127.0.0.1:49000/" },
            { retiring.complete(Unit); finish.await() })!!
        var current = true
        var bListens = 0
        val replacement = async { pool.acquire(endpoint(first), "account-b", { current },
            { bListens++; "http://127.0.0.1:49001/" }, {}) }
        retiring.await()
        current = false
        finish.complete(Unit)
        assertNull(replacement.await())
        assertEquals(0, bListens)
        pool.release(a)
    }


    @Test fun `uncertain listener cleanup must succeed before another account can acquire that endpoint`() = runTest {
        val pool = BrowserListenerPool()
        var refusesCleanup = true
        var bListens = 0
        val retire: suspend () -> Unit = { if (refusesCleanup) throw IllegalStateException("Cleanup unavailable") }
        assertTrue(runCatching {
            pool.acquire(endpoint(first), "account-a", { true }, { throw IllegalStateException("Answer lost") }, retire)
        }.isFailure)
        assertTrue(runCatching {
            pool.acquire(endpoint(first), "account-b", { true }, { bListens++; "http://127.0.0.1:49001/" }, {})
        }.isFailure)
        assertEquals(0, bListens)
        refusesCleanup = false
        val b = pool.acquire(endpoint(first), "account-b", { true }, { bListens++; "http://127.0.0.1:49001/" }, {})!!
        assertEquals(1, bListens)
        assertEquals("account-b", b.accountScope)
    }

    @Test fun `an invalid listener is retired instead of becoming a usable bridge`() = runTest {
        val pool = BrowserListenerPool()
        var retires = 0
        val failure = runCatching { pool.acquire(endpoint(first), "account-a", { true }, { "http://example.test:49000/" }, { retires++ }) }.exceptionOrNull()
        assertTrue(failure is IllegalArgumentException)
        assertEquals(1, retires)
    }
}
