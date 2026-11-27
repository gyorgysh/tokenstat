// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.core

import ai.tokenstat.tokenstat.ui.localization.L10n

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

object NetworkGate {
    private val flag = AtomicBoolean(false)

    var isOffline: Boolean
        get() = flag.get()
        set(value) = flag.set(value)
}

class ConnectivityMonitor(context: Context, private val scope: CoroutineScope) {
    companion object {
        const val RETRY_SECONDS = 30L
    }

    private val manager =
        context.applicationContext.getSystemService(ConnectivityManager::class.java)

    private val mutableStatus = MutableStateFlow(PathStatus.UNKNOWN)
    val status: StateFlow<PathStatus> = mutableStatus.asStateFlow()

    private val mutableRestored = MutableSharedFlow<Unit>(extraBufferCapacity = 1)
    val restored: SharedFlow<Unit> = mutableRestored.asSharedFlow()

    private var callback: ConnectivityManager.NetworkCallback? = null
    private var retryJob: Job? = null
    private var lastRouteKey = ""
    private var sawRoute = false
    private var lastRestoreAtMs = 0L

    fun start() {
        if (callback != null) return
        publish(read())
        val watcher = object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) {
                publish(read())
            }

            override fun onCapabilitiesChanged(network: Network, caps: NetworkCapabilities) {
                publish(classify(caps))
            }

            override fun onLost(network: Network) {
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
