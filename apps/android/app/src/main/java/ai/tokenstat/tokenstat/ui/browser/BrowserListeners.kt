// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.browser

import ai.tokenstat.tokenstat.ui.localization.L10n

import java.net.URI
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext

/// The host shares one listener per endpoint. Retirement and reacquisition
/// must finish in order, and releasing a lease twice must be harmless.
class BrowserListenerPool {
    data class Endpoint(val peer: String, val host: String, val port: Int)
    class Lease internal constructor(val endpoint: Endpoint, val listenerUrl: String, val accountScope: String)
    private class Held(val url: String, val accountScope: String, val retire: suspend () -> Unit) {
        val leases = mutableSetOf<Lease>()
    }
    private val gate = Mutex()
    private val held = mutableMapOf<Endpoint, Held>()

    companion object { val Shared = BrowserListenerPool() }

    suspend fun acquire(
        endpoint: Endpoint,
        accountScope: String,
        current: () -> Boolean,
        listen: suspend () -> String,
        retire: suspend () -> Unit,
    ): Lease? = gate.withLock {
        // An earlier close can hold the gate while the owner changes.
        if (!current()) return@withLock null
        require(accountScope.isNotBlank() && endpoint.peer.isNotBlank() && endpoint.host in setOf("127.0.0.1", "localhost") && endpoint.port in 1..65535)
        val existing = held[endpoint]
        var entry = existing
        if (existing != null && (existing.accountScope != accountScope || existing.leases.isEmpty())) {
            // The physical endpoint has no account namespace at the host.
            // Retire it before the next account may publish a replacement.
            withContext(NonCancellable) { existing.retire() }
            held.remove(endpoint)
            entry = null
            if (!current()) return@withLock null
        }
        if (entry == null) {
            val url = try {
                listen().also { require(validListener(it)) { L10n.text("android.browserlisteners.the_browser_listener_returned_an_invalid_a.a911e003") } }
            } catch (error: Exception) {
                val uncertain = Held("", accountScope, retire)
                held[endpoint] = uncertain
                withContext(NonCancellable) {
                    if (runCatching { retire() }.isSuccess) held.remove(endpoint)
                }
                throw error
            }
            if (!current()) {
                held[endpoint] = Held(url, accountScope, retire)
                withContext(NonCancellable) {
                    if (runCatching { retire() }.isSuccess) held.remove(endpoint)
                }
                return@withLock null
            }
            entry = Held(url, accountScope, retire)
            held[endpoint] = entry
        }
        val ready = entry
        Lease(endpoint, ready.url, accountScope).also { ready.leases.add(it) }
    }

    suspend fun release(lease: Lease): Unit = withContext(NonCancellable) {
        gate.withLock {
            val entry = held[lease.endpoint] ?: return@withLock
            if (!entry.leases.remove(lease) || entry.leases.isNotEmpty()) return@withLock
            // Keep the gate until the old host registration is retired.
            // Retain a failed retirement for a later account's retry.
            if (runCatching { entry.retire() }.isSuccess) held.remove(lease.endpoint)
        }
    }

    private fun validListener(url: String): Boolean = runCatching {
        val uri = URI(url)
        uri.scheme == "http" && uri.host in setOf("127.0.0.1", "localhost") &&
            uri.rawUserInfo == null && uri.port in 1..65535
    }.getOrDefault(false)
}

/// One screen holds at most one endpoint; old listener addresses remain only
/// as canonical mappings so WebView Back can acquire a fresh listener.
class BrowserListenerSession(
    target: BrowserTarget,
    initial: BrowserListenerPool.Lease,
    private val current: () -> Boolean,
    private val acquire: suspend (BrowserTarget, () -> Boolean) -> BrowserListenerPool.Lease?,
    private val pool: BrowserListenerPool = BrowserListenerPool.Shared,
) {
    private val gate = Mutex()
    @Volatile private var closed = false
    @Volatile private var live: BrowserListenerPool.Lease? = initial
    @Volatile private var mappings = listOf(BrowserBridge(target, initial.listenerUrl))
    private val peer = initial.endpoint.peer

    val isCurrent: Boolean get() = !closed && current()

    enum class Route { Direct, Open, Block }

    fun route(url: String?, mainFrame: Boolean, method: String?): Route = when {
        !isCurrent || !BrowserPolicy.allows(url) -> Route.Block
        original(url) == null || isCurrentProxy(url) -> Route.Direct
        mainFrame && method == "GET" -> Route.Open
        else -> Route.Block
    }

    fun original(url: String?): BrowserTarget? =
        mappings.firstNotNullOfOrNull { it.original(url) } ?: BrowserTarget.parse(url)

    fun isCurrentProxy(url: String?): Boolean = live?.let { lease ->
        mappings.firstOrNull { it.listenerUrl == lease.listenerUrl }?.original(url) != null
    } == true

    suspend fun open(target: BrowserTarget): String? = gate.withLock {
        if (!isCurrent) return@withLock null
        val old = live
        val endpoint = BrowserListenerPool.Endpoint(peer, target.host, target.port)
        val next = if (old != null && old.endpoint == endpoint) old else {
            live = null
            if (old != null) pool.release(old)
            if (!isCurrent) return@withLock null
            acquire(target) { isCurrent } ?: return@withLock null
        }
        if (!isCurrent) { pool.release(next); return@withLock null }
        live = next
        mappings = listOf(BrowserBridge(target, next.listenerUrl)) + mappings.filter { it.listenerUrl != next.listenerUrl }
        if (!isCurrent) {
            live = null
            pool.release(next)
            return@withLock null
        }
        target.through(next.listenerUrl)
    }

    suspend fun close() {
        closed = true
        gate.withLock {
            val old = live
            live = null
            if (old != null) pool.release(old)
        }
    }
}
