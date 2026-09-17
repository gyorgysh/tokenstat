// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.logic

import ai.tokenstat.tokenstat.ui.marks.formatServerDate
import kotlin.math.roundToInt

/// Home-plane pure logic ported 1:1 from the Apple client so both platforms
/// answer identically: the recents ranking (`ClientRecentChatsRanking.swift`),
/// the continue shelf (`ClientRecentPlaces.swift`), the pin shelf
/// (`PinnedWork.swift`), the arrangement (`HomeLayout.swift`), the device
/// sentences (`ClientDevicesView.swift` `DeviceCopy`), the limit ordering and
/// gauge severity (`ClientLimitsCard.swift` over `limits.rs` thresholds), and
/// the stats readings (`HostStatsBar.swift` `HostStatsFormat`).

/// How the Recents row is chosen: three newest by time stay on top, five more
/// follow ranked by what needs a look. Port of `ClientRecentChatsRanking`.
object RecentChatsRanking {
    const val RECENT_BY_TIME = 3
    const val MORE_BY_PRIORITY = 5
    const val WINDOW_MS = 7L * 24 * 60 * 60 * 1000

    data class Item(
        val id: String,
        val lastMessageAtMs: Long,
        val running: Boolean,
        val needsAttention: Boolean,
        val unread: Boolean,
    )

    fun visible(from: List<Item>, nowMs: Long): List<Item> {
        val cutoff = nowMs - WINDOW_MS
        val candidates = from.filter {
            it.needsAttention || it.running || it.unread || it.lastMessageAtMs >= cutoff
        }
        val newest = candidates.sortedByDescending { it.lastMessageAtMs }
        val head = newest.take(RECENT_BY_TIME)
        val headIds = head.map { it.id }.toSet()
        val rest = candidates
            .filter { it.id !in headIds }
            .sortedWith(compareByDescending<Item> { priority(it) }.thenByDescending { it.lastMessageAtMs })
        return head + rest.take(MORE_BY_PRIORITY)
    }

    /// Host-owned approvals first, then this device's unread replies, active
    /// work, and finally ordinary recency.
    fun priority(chat: Item): Int = when {
        chat.needsAttention -> 3
        chat.unread -> 2
        chat.running -> 1
        else -> 0
    }
}

/// Device furniture only: the folders and conversations this device opened.
/// Port of `ClientRecentPlaces`.
object RecentPlaces {
    const val CAPACITY = 20

    enum class Kind { WORKSPACE, CHAT, TERMINAL }

    data class PlaceId(
        val peer: String,
        val workspaceId: String?,
        val kind: Kind,
        val itemId: String?,
    )

    data class Place(
        val id: PlaceId,
        val workspaceName: String,
        val openedAtMs: Long,
    )

    /// Length-prefixed rather than encoded: no throwing, and "ab"+"c" never
    /// shares a key with "a"+"bc". The host and the account identity scope
    /// one account's places away from another's after a sign-out, the same
    /// key the Apple client reads and writes.
    fun scopeKey(host: String, handle: String): String =
        "client.recentPlaces.v1.${host.length}:$host${handle.length}:$handle"

    fun places(stored: List<Place>): List<Place> =
        stored.filter { valid(it.id) }
            .map { it.copy(workspaceName = safeName(it.workspaceName)) }
            .sortedByDescending { it.openedAtMs }
            .take(CAPACITY)

    fun record(
        stored: List<Place>,
        peer: String,
        workspaceId: String?,
        workspaceName: String,
        kind: Kind,
        itemId: String? = null,
        atMs: Long,
    ): List<Place> {
        val id = PlaceId(peer, workspaceId, kind, itemId)
        if (!valid(id)) return places(stored)
        val recent = places(stored).filter { it.id != id } +
            Place(id, safeName(workspaceName), atMs)
        return recent.sortedByDescending { it.openedAtMs }.take(CAPACITY)
    }

    fun valid(id: PlaceId): Boolean {
        val identifiers = listOfNotNull(id.peer, id.workspaceId, id.itemId)
        if (!identifiers.all { validIdentifier(it) }) return false
        return when (id.kind) {
            Kind.WORKSPACE -> !id.workspaceId.isNullOrEmpty() && id.itemId == null
            Kind.CHAT -> !id.workspaceId.isNullOrEmpty() && !id.itemId.isNullOrEmpty()
            Kind.TERMINAL -> !id.itemId.isNullOrEmpty()
        }
    }

    private fun validIdentifier(value: String): Boolean =
        value.isNotEmpty() && value.length <= 256 &&
            !value.contains("/") && !value.contains("\\") &&
            value.none { it.isISOControl() }

    fun safeName(name: String): String {
        val trimmed = name.trim()
        if (trimmed.isEmpty() || trimmed.contains("/") || trimmed.contains("\\") ||
            trimmed.any { it.isISOControl() }
        ) {
            return "Workspace"
        }
        return trimmed.take(80)
    }

    fun title(place: Place): String = when (place.id.kind) {
        Kind.WORKSPACE -> place.workspaceName
        Kind.CHAT -> "Chat in ${place.workspaceName}"
        Kind.TERMINAL -> if (place.id.workspaceId == null) "Terminal" else "Terminal in ${place.workspaceName}"
    }

    /// The handle when there is one, else the account id. Port of
    /// `WorkReference.Scope.accountIdentity`: the display name is a label,
    /// not an identity, and must never scope the store.
    fun accountIdentity(handle: String?, id: String?): String? {
        if (!handle.isNullOrBlank()) return handle.trim()
        if (!id.isNullOrBlank()) return id.trim()
        return null
    }
}

/// The work worth keeping: pinned folders and conversations, at most eight.
/// Port of `PinnedWork.swift`. Re-pinning updates the labels and moves the pin
/// to the top; a full shelf refuses with words rather than silently dropping
/// the oldest pin.
object PinnedWork {
    const val CAPACITY = 8

    enum class Kind { WORKSPACE, CONVERSATION }

    data class Pin(
        val scope: String,
        val hostIdentity: String,
        val workspaceId: String,
        val kind: Kind,
        val itemId: String?,
        val label: String,
        val folderName: String,
        val pinnedAtMs: Long,
    )

    /// Stable identity for one piece of work. Workspace pins name the folder;
    /// conversations name the item inside it. Segments are percent-encoded so
    /// a separator inside an id cannot forge a second pin's key.
    fun pinKey(scope: String, hostIdentity: String, workspaceId: String, kind: Kind, itemId: String?): String? {
        if (scope.isEmpty() || hostIdentity.isEmpty() || workspaceId.isEmpty()) return null
        if (!validIdentifier(hostIdentity) || !validIdentifier(workspaceId)) return null
        return when (kind) {
            Kind.WORKSPACE -> {
                if (itemId != null) return null
                "workspace|${encode(hostIdentity)}|${encode(workspaceId)}"
            }
            Kind.CONVERSATION -> {
                if (itemId == null || !validIdentifier(itemId)) return null
                "conversation|${encode(hostIdentity)}|${encode(workspaceId)}|${encode(itemId)}"
            }
        }
    }

    fun pins(stored: List<Pin>, scope: String): List<Pin> {
        if (scope.isEmpty()) return emptyList()
        val seen = mutableSetOf<String>()
        return stored.mapNotNull { pin ->
            val key = pinKey(pin.scope, pin.hostIdentity, pin.workspaceId, pin.kind, pin.itemId)
            if (pin.scope != scope || key == null || !seen.add(key)) return@mapNotNull null
            pin.copy(label = safeLabel(pin.label), folderName = safeLabel(pin.folderName))
        }.sortedByDescending { it.pinnedAtMs }
    }

    fun isPinned(stored: List<Pin>, scope: String, hostIdentity: String, workspaceId: String, kind: Kind, itemId: String?): Boolean {
        val key = pinKey(scope, hostIdentity, workspaceId, kind, itemId) ?: return false
        return pins(stored, scope).any {
            pinKey(it.scope, it.hostIdentity, it.workspaceId, it.kind, it.itemId) == key
        }
    }

    /// False when the shelf is full and this is new: the caller says so
    /// rather than the store choosing what goes.
    fun pin(
        stored: List<Pin>,
        scope: String,
        hostIdentity: String,
        workspaceId: String,
        kind: Kind,
        itemId: String?,
        label: String,
        folderName: String,
        atMs: Long,
    ): Pair<List<Pin>, Boolean> {
        if (scope.isEmpty()) return stored to false
        val key = pinKey(scope, hostIdentity, workspaceId, kind, itemId) ?: return stored to false
        val current = pins(stored, scope).toMutableList()
        val index = current.indexOfFirst {
            pinKey(it.scope, it.hostIdentity, it.workspaceId, it.kind, it.itemId) == key
        }
        if (index >= 0) {
            val old = current[index]
            current[index] = old.copy(label = safeLabel(label), folderName = safeLabel(folderName), pinnedAtMs = atMs)
        } else {
            if (current.size >= CAPACITY) return stored to false
            current.add(
                Pin(scope, hostIdentity, workspaceId, kind, itemId, safeLabel(label), safeLabel(folderName), atMs),
            )
        }
        return current.sortedByDescending { it.pinnedAtMs } to true
    }

    fun unpin(
        stored: List<Pin>,
        scope: String,
        hostIdentity: String,
        workspaceId: String,
        kind: Kind,
        itemId: String?,
    ): List<Pin> {
        val key = pinKey(scope, hostIdentity, workspaceId, kind, itemId) ?: return pins(stored, scope)
        return pins(stored, scope).filter {
            pinKey(it.scope, it.hostIdentity, it.workspaceId, it.kind, it.itemId) != key
        }
    }

    private fun validIdentifier(value: String): Boolean =
        value.isNotEmpty() && value.length <= 256 && value.none { it.isISOControl() }

    fun safeLabel(label: String): String {
        val trimmed = label.trim()
        if (trimmed.isEmpty() || trimmed.contains("/") || trimmed.contains("\\") ||
            trimmed.any { it.isISOControl() }
        ) {
            return "Pinned work"
        }
        return trimmed.take(80)
    }

    private fun encode(value: String): String = buildString {
        for (ch in value) {
            if (ch.isLetterOrDigit()) append(ch)
            else append("%" + ch.code.toString(16).uppercase().padStart(2, '0'))
        }
    }
}

/// How this device arranges Home. Port of `HomeLayout.swift`. The phone's
/// balanced order leads with the two figures: they are one line deep and read
/// at a glance, so they answer without pushing the work down a short screen.
enum class HomeSection(val key: String, val label: String, val detail: String) {
    CONTINUE("continue", "Continue", "The folders and conversations you were last in"),
    PINNED("pinned", "Pinned work", "Shortcuts to the folders and conversations you pinned"),
    MACHINES("machines", "Machines", "Which of your machines are awake"),
    USAGE("usage", "Today and this week", "What today and this week came to"),
    ACTIVITY("activity", "Activity", "The year, a square a day"),
    LIMITS("limits", "Plan limits", "How full each plan window is");

    companion object {
        fun of(key: String): HomeSection? = entries.find { it.key == key }
    }
}

enum class HomePreset(val label: String) {
    BALANCED("Balanced"),
    WORK("Work first"),
    USAGE("Usage first");

    val order: List<HomeSection>
        get() = when (this) {
            BALANCED -> listOf(HomeSection.USAGE, HomeSection.CONTINUE, HomeSection.MACHINES, HomeSection.PINNED, HomeSection.ACTIVITY, HomeSection.LIMITS)
            WORK -> listOf(HomeSection.CONTINUE, HomeSection.PINNED, HomeSection.MACHINES, HomeSection.LIMITS, HomeSection.USAGE, HomeSection.ACTIVITY)
            USAGE -> listOf(HomeSection.USAGE, HomeSection.LIMITS, HomeSection.ACTIVITY, HomeSection.CONTINUE, HomeSection.PINNED, HomeSection.MACHINES)
        }

    val hidden: Set<HomeSection>
        get() = emptySet()
}

/// Make a stored arrangement usable whatever is in it. A build that adds a
/// section must not disturb an order somebody chose, so new ones join at the
/// end. A name this build does not know is dropped, a name twice is kept
/// once, and hiding something that is not in the order is not a thing.
fun normalizeHomeLayout(stored: List<HomeSection>?, hidden: Set<HomeSection>): Pair<List<HomeSection>, Set<HomeSection>> {
    if (stored == null) return HomePreset.BALANCED.order to HomePreset.BALANCED.hidden
    val seen = mutableSetOf<HomeSection>()
    val order = stored.filter { seen.add(it) } +
        HomePreset.BALANCED.order.filter { it !in seen }
    return order to (hidden intersect order.toSet())
}

/// Every sentence the devices screens say about a device, in one place so the
/// list and the detail cannot describe the same machine differently. Port of
/// `DeviceCopy` in `ClientDevicesView.swift`.
object DeviceCopy {
    fun displayName(label: String?, platform: String?, isHost: Boolean): String {
        if (!label.isNullOrEmpty()) return label
        // What the machine says it is, before giving up. A CLI-only install
        // sends the platform at login, so "Linux computer" is usually
        // available where a name is not.
        val family = platform?.split("·")?.firstOrNull()
            ?.split(" ")?.firstOrNull()
            ?.takeIf { it.isNotEmpty() }
        if (family != null) return "$family ${if (isHost) "computer" else "device"}"
        return "Unnamed device"
    }

    /// The account directory does not publish Always-on host as a flag, so
    /// "Always on" is not claimed here. Online hosts read as awake; hosts
    /// with a connection key but offline read as asleep and ready; hosts
    /// without a key say so in one line.
    fun statusLine(
        isThisDevice: Boolean,
        online: Boolean?,
        isHost: Boolean,
        hasKey: Boolean,
        lastSeenText: String?,
    ): String {
        if (isThisDevice || online == true) return "Awake now"
        if (isHost) {
            if (hasKey) {
                return if (lastSeenText != null) "Asleep · last seen $lastSeenText" else "Asleep"
            }
            return "Not set up for remote"
        }
        return if (lastSeenText != null) "Last seen $lastSeenText" else "Has not reported in yet"
    }

    /// `m_c982…872c`. Long enough to be unique in a list of five, short
    /// enough to sit under a name.
    fun shortId(id: String): String {
        if (id.length <= 12) return id
        return "${id.take(6)}…${id.takeLast(4)}"
    }

    /// The second line: status alone on named rows, with a short id on
    /// unnamed ones so two "Linux computer" rows do not look identical.
    fun caption(label: String?, id: String?, status: String): String {
        if (!label.isNullOrEmpty() || id == null) return status
        return "${shortId(id)} · $status"
    }

    fun lastSync(reportsArchiveSync: Boolean, lastSyncAt: String?): String {
        if (!reportsArchiveSync) return "—"
        return formatServerDate(lastSyncAt) ?: "never"
    }

    /// Whether the account's platform string names a machine with no display
    /// layer, port of `isHeadlessPlatform`. Only the fallback: the live
    /// `host.provisionStatus` probe answers first, and this covers a host
    /// that cannot answer. Empty stays false, never hiding the row for a
    /// machine that never said what it runs.
    fun isHeadlessPlatform(platform: String?): Boolean {
        val lower = (platform ?: "").lowercase()
        if (lower.isEmpty()) return false
        if ("linux" in lower) return true
        return listOf("ubuntu", "debian", "fedora", "alpine", "arch", "centos", "rocky", "almalinux")
            .any { it in lower }
    }

    fun reach(isThisDevice: Boolean, online: Boolean?, hasKey: Boolean): String {
        if (isThisDevice) return "This is the device you are holding."
        if (online == true) {
            return "Awake and reachable through the tunnel from this device, and from any other device signed in to this account."
        }
        if (hasKey) {
            return "Asleep. It has a connection key, so it can be reached from this device once it is awake. Always-on host on that computer keeps it reachable after you quit the app there."
        }
        return "Not set up for remote reach. Turn on \"Reach devices from anywhere\" on that computer."
    }
}

/// Plan-limit ordering and gauge severity. Port of `ClientLimitsCard` sorting
/// over the `limits.rs` scale: thresholds are ours, not the vendor's, and are
/// the same for everything so that two providers side by side mean the same
/// thing by "warning".
object LimitLogic {
    enum class Severity { NORMAL, WARNING, CRITICAL }

    fun severityOf(raw: String?, percent: Double): Severity {
        when (raw?.lowercase()) {
            "critical" -> return Severity.CRITICAL
            "warning" -> return Severity.WARNING
            "normal" -> return Severity.NORMAL
        }
        return when {
            percent >= 90.0 -> Severity.CRITICAL
            percent >= 70.0 -> Severity.WARNING
            else -> Severity.NORMAL
        }
    }

    fun peakPercent(percents: List<Double>): Double = percents.maxOrNull() ?: -1.0

    /// Closest to full first. The window about to stop somebody working is
    /// the one worth the top of the card.
    fun <T> closestToFullFirst(rows: List<T>, peak: (T) -> Double): List<T> =
        rows.sortedByDescending(peak)
}

/// Stats readings in words. Port of `HostStatsFormat`. Missing readings stay
/// missing: a figure nobody measured is not a machine that is idle.
object HostStatsFormat {
    fun powerLabel(charging: Boolean, percent: Int?, power: String?, failed: Boolean, hadStats: Boolean): String {
        if (failed && !hadStats) return "n/a"
        if (!hadStats) return "…"
        if (charging && percent != null) return "$percent%"
        if (power == "ac" && percent == null) return "Plugged in"
        if (percent != null) return "$percent%"
        if (power == "battery") return "On battery"
        if (power == "ac") return "Plugged in"
        return "n/a"
    }

    fun ramLabel(usedBytes: Long, totalBytes: Long): String {
        val g = 1024.0 * 1024 * 1024
        val u = usedBytes / g
        val t = totalBytes / g
        return if (t >= 10) "%.0f / %.0f GB".format(u, t) else "%.1f / %.1f GB".format(u, t)
    }

    fun cpuLabel(cpu: Double): String = "${(cpu * 100).roundToInt()}%"

    /// Nil when this process has not yet observed a path, so a machine
    /// screen can stay quiet rather than invent Encrypted relay.
    fun routeLabel(route: String?): String? = when (route) {
        "direct" -> "Direct connection"
        "relay" -> "Encrypted relay"
        else -> null
    }
}
