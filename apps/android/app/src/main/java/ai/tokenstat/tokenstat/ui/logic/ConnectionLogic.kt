// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.logic

import ai.tokenstat.tokenstat.ui.localization.L10n

enum class NetworkFailureKind {
    OFFLINE,
    TIMED_OUT,
    SERVICE,
    PEER_ABSENT,
    ACCOUNT,
    OTHER,
    ;

    val isNetwork: Boolean
        get() = this == OFFLINE || this == TIMED_OUT || this == SERVICE || this == PEER_ABSENT
}

enum class NetworkPlane {
    ACCOUNT,

    PEER,
    ;

    companion object {
        private val localMethods = setOf("account.logout", "account.cancelLogin", "sync.scheduleStatus")

        fun of(method: String): NetworkPlane? = when {
            method == "remote.call" -> PEER
            method in localMethods -> null
            method.startsWith("account.") || method.startsWith("sync") -> ACCOUNT
            else -> null
        }
    }
}

object NetworkClassifier {
    fun kind(code: String, message: String): NetworkFailureKind {
        when (code) {
            "offline" -> return NetworkFailureKind.OFFLINE
            "host_timeout" -> return NetworkFailureKind.TIMED_OUT
            "host_unreachable" -> return NetworkFailureKind.SERVICE
            "no_such_peer", "peer_absent", "tunnel_disconnected" ->
                return NetworkFailureKind.PEER_ABSENT
            "not_signed_in", "unauthorized", "not_approved", "not_on_this_plan" ->
                return NetworkFailureKind.ACCOUNT
        }
        val lower = message.lowercase()
        if (lower.contains("no_such_peer") || lower.contains("not on the tunnel") ||
            lower.contains("tunnel is not connected") || lower.contains("tunnel disconnected") ||
            lower.contains("did not pair the channel")
        ) {
            return NetworkFailureKind.PEER_ABSENT
        }
        if (lower.contains("offline") || lower.contains("not connected to the internet") ||
            lower.contains("unable to resolve") || lower.contains("enotconn")
        ) {
            return NetworkFailureKind.OFFLINE
        }
        if (lower.contains("timed out") || lower.contains("timeout")) {
            return NetworkFailureKind.TIMED_OUT
        }
        if (lower.contains("could not resolve") || lower.contains("connection refused") ||
            lower.contains("certificate") || lower.contains("tls") ||
            lower.contains("bad gateway") || lower.contains("relay")
        ) {
            return NetworkFailureKind.SERVICE
        }
        if (lower.contains("sign in") || lower.contains("not approved")) {
            return NetworkFailureKind.ACCOUNT
        }
        return NetworkFailureKind.OTHER
    }
}

class ConnectionTracker {
    companion object {
        const val FAILURES_BEFORE_UNWELL = 2
    }

    private var path: PathStatus = PathStatus.UNKNOWN
    private var serviceFailing = false
    private var serviceFailures = 0

    private var offlineFailures = 0
    private var lastServiceSuccessMs: Long? = null
    private var lastPeerSuccessMs: Long? = null

    private val peerFailures = mutableMapOf<String, Int>()

    private val peersSeenWorking = mutableSetOf<String>()
    private val unreachablePeers = mutableSetOf<String>()

    private val peerNames = mutableMapOf<String, String>()

    val lastGoodMs: Long?
        get() = synchronized(this) {
            listOfNotNull(lastServiceSuccessMs, lastPeerSuccessMs).maxOrNull()
        }

    val offline: Boolean
        get() = synchronized(this) { offlineLocked }

    private val offlineLocked: Boolean
        get() = path == PathStatus.OFFLINE ||
            (path == PathStatus.UNVALIDATED && serviceFailures >= FAILURES_BEFORE_UNWELL) ||
            offlineFailures >= FAILURES_BEFORE_UNWELL

    @Synchronized
    fun setPath(status: PathStatus) {
        path = status
        if (status == PathStatus.ONLINE) offlineFailures = 0
    }

    @Synchronized
    fun setPeerNames(names: Map<String, String>) {
        names.forEach { (key, label) ->
            if (label.isNotBlank()) peerNames[key.lowercase()] = label
        }
    }

    @Synchronized
    fun note(plane: NetworkPlane, peerKey: String?, kind: NetworkFailureKind?, nowMs: Long) {
        val peer = peerKey?.lowercase()
        if (kind == null) {
            offlineFailures = 0
            when (plane) {
                NetworkPlane.ACCOUNT -> {
                    serviceFailures = 0
                    serviceFailing = false
                    lastServiceSuccessMs = nowMs
                }
                NetworkPlane.PEER -> {
                    lastPeerSuccessMs = nowMs
                    if (peer == null) return
                    peerFailures[peer] = 0
                    peersSeenWorking.add(peer)
                    unreachablePeers.remove(peer)
                }
            }
            return
        }
        if (!kind.isNetwork) return
        if (kind == NetworkFailureKind.OFFLINE) offlineFailures += 1
        if (plane == NetworkPlane.PEER || kind == NetworkFailureKind.PEER_ABSENT) {
            if (peer == null) return
            val failures = (peerFailures[peer] ?: 0) + 1
            peerFailures[peer] = failures
            if (!peersSeenWorking.contains(peer)) return
            if (failures >= FAILURES_BEFORE_UNWELL) unreachablePeers.add(peer)
            return
        }
        if (plane == NetworkPlane.ACCOUNT) {
            serviceFailures += 1
            serviceFailing = serviceFailures >= FAILURES_BEFORE_UNWELL
        }
    }

    @Synchronized
    fun reset() {
        serviceFailures = 0
        serviceFailing = false
        offlineFailures = 0
        peerFailures.clear()
        unreachablePeers.clear()
    }

    private val unreachableName: String?
        get() = unreachablePeers.singleOrNull()?.let { peerNames[it] }


    @Synchronized
    fun ui(): ConnectionUiState {
        if (offlineLocked) {
            return ConnectionUiState(
                ok = false,
                down = true,
                offline = true,
                title = L10n.text("common.offline"),
                detail = L10n.text("android.connectionlogic.this_device_cannot_reach_the_internet_it_c.c95f0743"),
                lastGoodMs = lastGoodMs,
            )
        }
        if (serviceFailing) {
            return ConnectionUiState(
                ok = false,
                down = true,
                service = true,
                title = L10n.text("android.connectionlogic.no_connection.c9e1a200"),
                detail = L10n.text("android.connectionlogic.signed_in_but_tokenstat_is_not_answering_y.0b89409f"),
                lastGoodMs = lastGoodMs,
            )
        }
        if (unreachablePeers.isNotEmpty()) {
            val name = unreachableName
            return ConnectionUiState(
                ok = false,
                down = false,
                title = when {
                    name != null -> L10n.text("android.connectionlogic.0_unreachable.c9592a5e", "${name}")
                    unreachablePeers.size > 1 -> L10n.text("android.connectionlogic.computers_unreachable.5c57873d")
                    else -> L10n.text("android.connectionlogic.computer_unreachable.289a05cc")
                },
                detail = L10n.text("android.connectionlogic.the_internet_is_fine_and_0_stopped_answeri.ff980764", "${name ?: L10n.text("android.connectionlogic.the_computer.da52d93a")}"),
                lastGoodMs = lastGoodMs,
            )
        }
        return ConnectionUiState(lastGoodMs = lastGoodMs)
    }
}

enum class PathStatus {
    UNKNOWN,

    OFFLINE,

    UNVALIDATED,

    ONLINE,
}

data class ConnectionUiState(
    val ok: Boolean = true,
    val down: Boolean = false,
    val offline: Boolean = false,
    val service: Boolean = false,
    val title: String = "",
    val detail: String = "",
    val lastGoodMs: Long? = null,
)
