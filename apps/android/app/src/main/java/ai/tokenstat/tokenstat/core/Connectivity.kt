// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.core

import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import ai.tokenstat.tokenstat.ui.logic.PathStatus
import java.util.concurrent.atomic.AtomicBoolean
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asSharedFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch

/// The offline flag, readable from anywhere without a coroutine.
///
/// The place that needs this answer is a call about to leave the process on
/// an IO thread. One bool behind an atomic is cheaper than making every call
/// ask the view model what it already knows. Port of `NetworkGate` in
/// `ConnectivityModel.swift`.
object NetworkGate {
    private val flag = AtomicBoolean(false)

    var isOffline: Boolean
        get() = flag.get()
        set(value) = flag.set(value)
}

/// Whether this device can reach the internet, and the watch that notices it
/// coming back. Port of `ConnectivityModel`.
///
/// **The platform already answers this, so the app does not probe.** Android
/// runs its own captive-portal check continuously and publishes the verdict
/// as `NET_CAPABILITY_VALIDATED`, which is the same question iOS has to ask
/// `captive.apple.com` itself. Reading a capability costs nothing, sends
/// nothing, and cannot be fooled by a portal. What it can be is wrong in the
/// other direction, on a network that blocks the system probe but carries
/// traffic fine, which is why an unvalidated network is reported as
/// `UNVALIDATED` rather than as offline and `ConnectionTracker` waits for the
/// app's own calls to agree.
///
/// A route change (Wi-Fi to cellular) is still "online", but the tunnel
/// socket is bound to the old route, so it is announced as a restore: that is
/// exactly when the tunnel must redial rather than wait for a keepalive to
/// time out.
class ConnectivityMonitor(context: Context, private val scope: CoroutineScope) {
    companion object {
        /// How long an offline stretch waits before reading the path again.
        /// Reading is local and free, so this is a safety net rather than a
        /// poll: the callback is what normally wakes the app.
        const val RETRY_SECONDS = 30L
    }

    private val manager =
        context.applicationContext.getSystemService(ConnectivityManager::class.java)

    private val mutableStatus = MutableStateFlow(PathStatus.UNKNOWN)
    val status: StateFlow<PathStatus> = mutableStatus.asStateFlow()

    /// The network came back, or moved to a different route. Anything waiting
    /// on the internet refreshes now instead of on its own next tick.
    private val mutableRestored = MutableSharedFlow<Unit>(extraBufferCapacity = 1)
    val restored: SharedFlow<Unit> = mutableRestored.asSharedFlow()

    private var callback: ConnectivityManager.NetworkCallback? = null
    private var retryJob: Job? = null
    private var lastRouteKey = ""
    private var sawRoute = false
    /// A VPN flap can fire several capability updates. One redial per burst.
    private var lastRestoreAtMs = 0L

    fun start() {
        if (callback != null) return
        // Read once before registering. The callback's first update lands
        // asynchronously, and a launch with no internet has to say so on the
        // first frame rather than after the first failed call.
        publish(read())
        val watcher = object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) {
                // A network that returns with the same capabilities fires no
                // capability change, so arrival alone re-reads the path.
                publish(read())
            }

            override fun onCapabilitiesChanged(network: Network, caps: NetworkCapabilities) {
                publish(classify(caps))
            }

            override fun onLost(network: Network) {
                // Losing the default network does not always mean there is no
                // other one, so ask rather than assume.
                publish(read())
            }

            override fun onUnavailable() {
                publish(PathStatus.OFFLINE)
            }
        }
        callback = watcher
        runCatching { manager?.registerDefaultNetworkCallback(watcher) }
        retryJob = scope.launch {
            while (true) {
                delay(RETRY_SECONDS * 1000)
                if (mutableStatus.value != PathStatus.ONLINE) publish(read())
            }
        }
    }

    fun stop() {
        callback?.let { watcher -> runCatching { manager?.unregisterNetworkCallback(watcher) } }
        callback = null
        retryJob?.cancel()
        retryJob = null
    }

    /// An immediate re-read from a "Try now" control, without waiting for the
    /// retry tick.
    fun checkNow() {
        publish(read())
    }

    private fun read(): PathStatus {
        val active = manager?.activeNetwork ?: return PathStatus.OFFLINE
        val caps = manager?.getNetworkCapabilities(active) ?: return PathStatus.OFFLINE
        return classify(caps)
    }

    private fun classify(caps: NetworkCapabilities): PathStatus = when {
        !caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET) -> PathStatus.OFFLINE
        caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED) -> PathStatus.ONLINE
        else -> PathStatus.UNVALIDATED
    }

    private fun publish(status: PathStatus) {
        val was = mutableStatus.value
        mutableStatus.value = status
        // `NetworkGate` is written by the one place that folds this together
        // with what the app's own calls saw. Two writers to one flag is how a
        // gate starts contradicting the screen above it.
        if (status != PathStatus.ONLINE) return
        val route = routeKey()
        val changed = sawRoute && route != lastRouteKey
        sawRoute = true
        lastRouteKey = route
        if (was == PathStatus.ONLINE && !changed) return
        val now = System.currentTimeMillis()
        if (now - lastRestoreAtMs < 2000) return
        lastRestoreAtMs = now
        mutableRestored.tryEmit(Unit)
    }

    /// Enough of the path to tell one network from another. The id is what
    /// catches a move between two access points, which the tunnel feels as
    /// much as a move between interfaces; the transports stay so the key
    /// still reads when the id is missing. Quality flaps on the same
    /// network keep the key and must not look like a new route.
    private fun routeKey(): String {
        val active = manager?.activeNetwork ?: return ""
        val caps = manager?.getNetworkCapabilities(active) ?: return ""
        val parts = buildList {
            add("net$active")
            if (caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI)) add("wifi")
            if (caps.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR)) add("cell")
            if (caps.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET)) add("eth")
            if (caps.hasTransport(NetworkCapabilities.TRANSPORT_VPN)) add("vpn")
        }
        return parts.joinToString(",")
    }
}
