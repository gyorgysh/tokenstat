// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.logic

/// Why a call failed, decided once instead of by each screen. Port of
/// `NetworkFailureKind` in `ConnectionModel.swift`.
///
/// Every screen used to read a sentence and guess. The sentence is still what
/// gets shown, and `friendlyError` still writes it, but what the app
/// *believes* about the network is decided here, from the error code where
/// there is one.
enum class NetworkFailureKind {
    /// This device has no working internet.
    OFFLINE,
    /// Reached nothing in time.
    TIMED_OUT,
    /// Name resolution, TLS, or a refused connection: the service is not
    /// answering the way it should.
    SERVICE,
    /// The machine is not on the tunnel right now.
    PEER_ABSENT,
    /// The account is not signed in, or is not allowed to do this. Not a
    /// network problem, and must not be reported as one.
    ACCOUNT,
    /// Something else entirely. Never moves the indicator: a folder that does
    /// not exist is not a network fault.
    OTHER,
    ;

    /// Whether this says something about the network as opposed to about the
    /// request.
    val isNetwork: Boolean
        get() = this == OFFLINE || this == TIMED_OUT || this == SERVICE || this == PEER_ABSENT
}

/// Which plane a call was on, because the two fail independently.
enum class NetworkPlane {
    /// The account: usage, plan, machines. Needs the internet.
    ACCOUNT,

    /// A machine over the tunnel. Needs the internet **and** the machine.
    PEER,
    ;

    companion object {
        /// Account calls whose real work is local, so being offline must not
        /// refuse them and their outcome says nothing about the network.
        ///
        /// Signing out clears this device's stored login whether or not the
        /// server hears about it, and the core already gives that request a
        /// short budget so a dead path cannot hold it up. Refusing it offline
        /// would leave somebody unable to sign out on a plane, which is the
        /// opposite of what the gate is for.
        private val localAccountMethods = setOf("account.logout", "account.cancelLogin")

        /// Which plane a core method is on, or null for one that says nothing
        /// about the network.
        ///
        /// A local call that fails is a bug or a missing file, not a
        /// connection fault, and letting one move the indicator would teach
        /// people to ignore it. Only the calls that actually leave the device
        /// count.
        fun of(method: String): NetworkPlane? = when {
            method == "remote.call" -> PEER
            method in localAccountMethods -> null
            method.startsWith("account.") || method.startsWith("sync") -> ACCOUNT
            else -> null
        }
    }
}

/// Classify a failure from a call. Port of `NetworkClassifier`.
///
/// Codes first, sentences second. The core already returns
/// `{"ok": false, "error": {"code", "message"}}` and `CoreFailure` keeps the
/// code, so the robust half of this carries as much as it can. A phrasing
/// that falls through lands in `OTHER`, which moves nothing, rather than
/// being mapped to the wrong advice.
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

/// What the app believes about the network right now, folded from three
/// places that can each break on their own. Port of `ConnectionModel`.
///
/// - **Internet**: the platform's own answer, from `ConnectivityMonitor`.
/// - **Service**: whether tokenstat.ai is answering. Derived from the calls
///   the app is already making rather than from a poll, because a poll would
///   ask a question the app asks anyway.
/// - **Peer**: whether the machine being addressed is on the tunnel.
///
/// One tracker so two screens cannot say different things about one failure.
///
/// Every method is synchronized, because the thing that feeds it is every
/// call leaving the process and those finish on an IO thread while the
/// screen that reads the answer lives on the main one. A lock around a
/// handful of counters is cheaper than hopping a coroutine per call, which
/// a chat poll would do every two seconds.
class ConnectionTracker {
    /// How many failures in a row before a plane is called unwell.
    ///
    /// One failure is a request, not a state. Two in a row with nothing
    /// succeeding in between is a pattern, and a pattern is worth a word on
    /// screen.
    companion object {
        const val FAILURES_BEFORE_UNWELL = 2
    }

    private var path: PathStatus = PathStatus.UNKNOWN
    private var serviceFailing = false
    private var serviceFailures = 0

    /// Failures in a row that named no internet, on either plane.
    ///
    /// The platform's own verdict is the fast one, but a network that blocks
    /// the system probe reports itself as unvalidated for good, and a core
    /// that already answered "offline" knows more than a capability bit. Two
    /// of those in a row is the app's own evidence.
    private var offlineFailures = 0
    private var lastServiceSuccessMs: Long? = null
    private var lastPeerSuccessMs: Long? = null

    /// Failures in a row, per machine.
    ///
    /// Per machine and not one number, because a machine asleep in a bag was
    /// speaking for the one being worked on: the app dials every approved
    /// peer on a loop, so a laptop that is off failed every thirty seconds
    /// and kept a single shared counter above the threshold for good.
    private val peerFailures = mutableMapOf<String, Int>()

    /// Machines that have answered at least once since this app opened.
    ///
    /// A machine is only worth a warning if it *was* reachable and stopped.
    /// One that has never answered is not news, it is a machine that is off,
    /// and Devices says so in the place somebody goes to ask.
    private val peersSeenWorking = mutableSetOf<String>()
    private val unreachablePeers = mutableSetOf<String>()

    /// Key to the name its owner gave it, so the card can say which machine.
    /// Empty until something that lists peers hands them over.
    private val peerNames = mutableMapOf<String, String>()

    /// The most recent answer from either plane, or null when nothing has
    /// answered since the app opened. Said by leaving it out rather than by
    /// inventing a date.
    val lastGoodMs: Long?
        get() = synchronized(this) {
            listOfNotNull(lastServiceSuccessMs, lastPeerSuccessMs).maxOrNull()
        }

    /// Whether this device can reach the internet.
    ///
    /// Three clauses, each with its own reason. No network at all is certain.
    /// A network the platform declines to validate is only offline once the
    /// app's own account calls agree, because a network that blocks the
    /// system probe still carries traffic and must not strand anybody behind
    /// a permanent offline card. And a core that answered "offline" twice is
    /// evidence in its own right.
    val offline: Boolean
        get() = synchronized(this) { offlineLocked }

    private val offlineLocked: Boolean
        get() = path == PathStatus.OFFLINE ||
            (path == PathStatus.UNVALIDATED && serviceFailures >= FAILURES_BEFORE_UNWELL) ||
            offlineFailures >= FAILURES_BEFORE_UNWELL

    /// What the platform says about the route right now.
    @Synchronized
    fun setPath(status: PathStatus) {
        path = status
        // A path that came back is not evidence about the calls that failed
        // while it was down. Those counters described a network that no
        // longer exists.
        if (status == PathStatus.ONLINE) offlineFailures = 0
    }

    /// Names for the machines this app knows about. Cheap to hand over on
    /// every peer load, and it is what lets the card say "Studio" rather than
    /// "Computer", which is the difference between news and a puzzle when an
    /// account has four machines.
    @Synchronized
    fun setPeerNames(names: Map<String, String>) {
        names.forEach { (key, label) ->
            if (label.isNotBlank()) peerNames[key.lowercase()] = label
        }
    }

    /// A call came back. Success clears what it proves and nothing else: one
    /// good answer from a machine proves that machine, not the next one.
    @Synchronized
    fun note(plane: NetworkPlane, peerKey: String?, kind: NetworkFailureKind?, nowMs: Long) {
        // Peer identities reach this from several call sites and the case is
        // not guaranteed to match between them.
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
        // A peer that is absent says nothing about the service, and a service
        // that is down says nothing about that one machine.
        if (plane == NetworkPlane.PEER || kind == NetworkFailureKind.PEER_ABSENT) {
            if (peer == null) return
            val failures = (peerFailures[peer] ?: 0) + 1
            peerFailures[peer] = failures
            // Never seen working: it is off, not unreachable. Raising this for
            // a machine that has been asleep all along is how an ambient
            // warning becomes something people learn to ignore.
            if (!peersSeenWorking.contains(peer)) return
            if (failures >= FAILURES_BEFORE_UNWELL) unreachablePeers.add(peer)
            return
        }
        if (plane == NetworkPlane.ACCOUNT) {
            serviceFailures += 1
            serviceFailing = serviceFailures >= FAILURES_BEFORE_UNWELL
        }
    }

    /// The network came back, or the person pressed Try now. Nothing is known
    /// again until the next call answers, which is honest: the counters were
    /// evidence about a network that no longer exists.
    ///
    /// What each machine had proved is kept: a machine that answered five
    /// minutes ago is still one this app has seen working, and forgetting
    /// that would put every peer back behind the never-seen rule after any
    /// press of Try now.
    @Synchronized
    fun reset() {
        serviceFailures = 0
        serviceFailing = false
        offlineFailures = 0
        peerFailures.clear()
        unreachablePeers.clear()
    }

    /// The machine this card is about, when exactly one is unreachable and
    /// its name is known.
    private val unreachableName: String?
        get() = unreachablePeers.singleOrNull()?.let { peerNames[it] }


    /// Four words at most for the chip, one sentence for the dialog, folded
    /// into the shape the chrome already reads.
    @Synchronized
    fun ui(): ConnectionUiState {
        if (offlineLocked) {
            return ConnectionUiState(
                ok = false,
                down = true,
                offline = true,
                title = "Offline",
                detail = "This device cannot reach the internet. It checks again by itself, " +
                    "and everything comes back on its own.",
                lastGoodMs = lastGoodMs,
            )
        }
        if (serviceFailing) {
            return ConnectionUiState(
                ok = false,
                down = true,
                service = true,
                title = "No connection",
                detail = "Signed in, but tokenstat is not answering. Your numbers are the " +
                    "last ones this device read.",
                lastGoodMs = lastGoodMs,
            )
        }
        if (unreachablePeers.isNotEmpty()) {
            val name = unreachableName
            return ConnectionUiState(
                ok = false,
                down = false,
                title = when {
                    name != null -> "$name unreachable"
                    unreachablePeers.size > 1 -> "Computers unreachable"
                    else -> "Computer unreachable"
                },
                detail = "The internet is fine and ${name ?: "the computer"} stopped " +
                    "answering. It is asleep, or tokenstat is not running there.",
                lastGoodMs = lastGoodMs,
            )
        }
        return ConnectionUiState(lastGoodMs = lastGoodMs)
    }
}

/// What the platform says about the route, before the app's own calls have
/// a word in it.
enum class PathStatus {
    /// Nothing asked yet.
    UNKNOWN,

    /// No network, or one that does not claim to carry internet traffic.
    OFFLINE,

    /// A network that claims internet but that the platform has not
    /// validated. Not offline on its own: the system's own probe is blocked
    /// on some networks that work perfectly well.
    UNVALIDATED,

    /// A network the platform validated.
    ONLINE,
}

/// One honest answer about the network, in the shape the chrome reads.
data class ConnectionUiState(
    val ok: Boolean = true,
    val down: Boolean = false,
    val offline: Boolean = false,
    val service: Boolean = false,
    val title: String = "",
    val detail: String = "",
    val lastGoodMs: Long? = null,
)
