// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.logic

import ai.tokenstat.tokenstat.ui.localization.L10n

import ai.tokenstat.tokenstat.ui.marks.formatServerDate
import kotlin.math.roundToInt


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

    fun priority(chat: Item): Int = when {
        chat.needsAttention -> 3
        chat.unread -> 2
        chat.running -> 1
        else -> 0
    }
}

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

    fun scopeKey(host: String, handle: String): String =
        "client.recentPlaces.v1.${host.length}:$host${handle.length}:$handle"

    fun places(stored: List<Place>): List<Place> =
        stored.filter { valid(it.id) }
            .map { it.copy(workspaceName = safeName(it.workspaceName)) }
            .sortedByDescending { it.openedAtMs }
            .take(CAPACITY)

    fun continuePlaces(stored: List<Place>): List<Place> {
        val recent = places(stored)
        val anchors = listOfNotNull(
            recent.firstOrNull { it.id.kind == Kind.WORKSPACE },
            recent.firstOrNull { it.id.kind == Kind.CHAT },
        )
        return if (anchors.isEmpty()) recent.take(1) else anchors.sortedByDescending { it.openedAtMs }
    }

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
        val sorted = recent.sortedByDescending { it.openedAtMs }
        val lastChat = sorted.firstOrNull { it.id.kind == Kind.CHAT }
        val newest = sorted.take(CAPACITY)
        return if (lastChat != null && lastChat !in newest) {
            (newest.take(CAPACITY - 1) + lastChat).sortedByDescending { it.openedAtMs }
        } else newest
    }

    fun valid(id: PlaceId): Boolean {
        if (id.workspaceId != null && (id.workspaceId.isEmpty() || id.workspaceId.length > 4096 ||
                id.workspaceId.any { it.isISOControl() })) return false
        if (!listOfNotNull(id.peer, id.itemId).all { validIdentifier(it) }) return false
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
            return L10n.text("android.homelogic.project.98595978")
        }
        return trimmed.take(80)
    }

    fun title(place: Place): String = when (place.id.kind) {
        Kind.WORKSPACE -> place.workspaceName
        Kind.CHAT -> L10n.text("android.homelogic.chat_in_0.83a947da", "${place.workspaceName}")
        Kind.TERMINAL -> if (place.id.workspaceId == null) L10n.text("android.homelogic.terminal.e0926fda") else L10n.text("android.homelogic.terminal_in_0.9d87a81b", "${place.workspaceName}")
    }

    fun accountIdentity(handle: String?, id: String?): String? = AccountIdentityPins.identity(handle, id)
}

object PinnedWork {
    const val CAPACITY = 8

    enum class Kind { WORKSPACE, CONVERSATION, TERMINAL }

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

    fun pinKey(scope: String, hostIdentity: String, workspaceId: String, kind: Kind, itemId: String?): String? {
        if (scope.isEmpty() || hostIdentity.isEmpty() || workspaceId.isEmpty()) return null
        if (!validIdentifier(hostIdentity) || !validIdentifier(workspaceId)) return null
        return when (kind) {
            Kind.WORKSPACE -> {
                if (itemId != null) return null
                "workspace|${encode(hostIdentity)}|${encode(workspaceId)}"
            }
            Kind.CONVERSATION, Kind.TERMINAL -> {
                if (itemId == null || !validIdentifier(itemId)) return null
                val name = if (kind == Kind.CONVERSATION) "conversation" else "terminal"
                "$name|${encode(hostIdentity)}|${encode(workspaceId)}|${encode(itemId)}"
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
            return L10n.text("android.homelogic.pinned_work.23dd8f45")
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

enum class HomeSection(val key: String, val label: String, val detail: String) {
    CONTINUE("continue", L10n.text("android.homelogic.continue.31fbef16"), L10n.text("android.homelogic.the_folders_and_conversations_you_were_las.611a8af7")),
    PINNED("pinned", L10n.text("android.homelogic.pinned_work.23dd8f45"), L10n.text("android.homelogic.shortcuts_to_the_folders_and_conversations.395d6781")),
    MACHINES("machines", L10n.text("android.homelogic.machines.c061da19"), L10n.text("android.homelogic.which_of_your_machines_are_awake.59492064")),
    USAGE("usage", L10n.text("android.homelogic.today_and_this_week.2cb0c4ae"), L10n.text("android.homelogic.what_today_and_this_week_came_to.e49c5c1c")),
    ACTIVITY("activity", L10n.text("android.homelogic.activity.38da1505"), L10n.text("android.homelogic.the_year_a_square_a_day.a3daad88")),
    LIMITS("limits", L10n.text("android.homelogic.plan_limits.925788cd"), L10n.text("android.homelogic.how_much_of_each_tool_s_subscription_is_le.16c87cc1"));

    companion object {
        fun of(key: String): HomeSection? = entries.find { it.key == key }
    }
}

enum class HomePreset(val label: String) {
    BALANCED(L10n.text("android.homelogic.balanced.5386ea5d")),
    WORK(L10n.text("android.homelogic.work_first.c3edce98")),
    USAGE(L10n.text("android.homelogic.usage_first.007ee7e0"));

    val order: List<HomeSection>
        get() = when (this) {
            BALANCED -> listOf(HomeSection.USAGE, HomeSection.CONTINUE, HomeSection.MACHINES, HomeSection.PINNED, HomeSection.ACTIVITY, HomeSection.LIMITS)
            WORK -> listOf(HomeSection.CONTINUE, HomeSection.PINNED, HomeSection.MACHINES, HomeSection.LIMITS, HomeSection.USAGE, HomeSection.ACTIVITY)
            USAGE -> listOf(HomeSection.USAGE, HomeSection.LIMITS, HomeSection.ACTIVITY, HomeSection.CONTINUE, HomeSection.PINNED, HomeSection.MACHINES)
        }

    val hidden: Set<HomeSection>
        get() = emptySet()
}

fun normalizeHomeLayout(stored: List<HomeSection>?, hidden: Set<HomeSection>): Pair<List<HomeSection>, Set<HomeSection>> {
    if (stored == null) return HomePreset.BALANCED.order to HomePreset.BALANCED.hidden
    val seen = mutableSetOf<HomeSection>()
    val order = stored.filter { seen.add(it) } +
        HomePreset.BALANCED.order.filter { it !in seen }
    return order to (hidden intersect order.toSet())
}

object DeviceCopy {
    fun displayName(label: String?, platform: String?, isHost: Boolean): String {
        if (!label.isNullOrEmpty()) return label
        val family = platform?.split("·")?.firstOrNull()
            ?.split(" ")?.firstOrNull()
            ?.takeIf { it.isNotEmpty() }
        if (family != null) return "$family ${if (isHost) L10n.text("android.homelogic.computer.aa973021") else L10n.text("android.homelogic.device.263a4dbe")}"
        return L10n.text("android.homelogic.unnamed_device.6aba593f")
    }

    fun statusLine(
        isThisDevice: Boolean,
        online: Boolean?,
        isHost: Boolean,
        hasKey: Boolean,
        lastSeenText: String?,
    ): String {
        if (isThisDevice || online == true) return L10n.text("android.homelogic.awake_now.64f95f4c")
        if (isHost) {
            if (hasKey) {
                return if (lastSeenText != null) L10n.text("android.homelogic.asleep_last_seen_0.6ef899b9", "${lastSeenText}") else L10n.text("android.homelogic.asleep.60135e8f")
            }
            return L10n.text("android.homelogic.not_set_up_for_remote.3db4bb28")
        }
        return if (lastSeenText != null) L10n.text("android.homelogic.last_seen_0.77ac00d1", "${lastSeenText}") else L10n.text("android.homelogic.has_not_reported_in_yet.88f189cb")
    }

    fun shortId(id: String): String {
        if (id.length <= 12) return id
        return "${id.take(6)}…${id.takeLast(4)}"
    }

    fun caption(label: String?, id: String?, status: String): String {
        if (!label.isNullOrEmpty() || id == null) return status
        return "${shortId(id)} · $status"
    }

    fun lastSync(reportsArchiveSync: Boolean, lastSyncAt: String?): String {
        if (!reportsArchiveSync) return "—"
        return formatServerDate(lastSyncAt) ?: "never"
    }

    fun isHeadlessPlatform(platform: String?): Boolean {
        val words = (platform ?: "").lowercase()
            .split(Regex("[^\\p{L}\\p{N}]+"))
            .filter { it.isNotEmpty() }
            .toSet()
        if (words.isEmpty()) return false
        if (words.any { it in DESKTOP_WORDS }) return false
        return words.any { it in LINUX_WORDS }
    }

    fun hostShowsScreen(screen: Boolean?, headless: Boolean?): Boolean? = screen ?: headless?.not()

    private val DESKTOP_WORDS = setOf("macos", "darwin", "osx", "windows", "win32")
    private val LINUX_WORDS = setOf(
        "linux", "ubuntu", "debian", "fedora", "alpine", "arch", "archlinux",
        "centos", "rocky", "almalinux", "rhel", "opensuse", "suse", "nixos", "gentoo", "mint",
    )

    fun reach(isThisDevice: Boolean, online: Boolean?, hasKey: Boolean): String {
        if (isThisDevice) return L10n.text("android.homelogic.this_is_the_device_you_are_holding.19fe2976")
        if (online == true) {
            return L10n.text("android.homelogic.awake_and_reachable_through_the_tunnel_fro.81ab5be0")
        }
        if (hasKey) {
            return L10n.text("android.homelogic.asleep_it_has_a_connection_key_so_it_can_b.8982cace")
        }
        return L10n.text("android.homelogic.not_set_up_for_remote_reach_turn_on_reach.9d22e688")
    }
}

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

    fun <T> closestToFullFirst(rows: List<T>, peak: (T) -> Double): List<T> =
        rows.sortedByDescending(peak)
}

object HostStatsFormat {
    fun powerLabel(charging: Boolean, percent: Int?, power: String?, failed: Boolean, hadStats: Boolean): String {
        if (failed && !hadStats) return L10n.text("android.homelogic.n_a.a683c5c5")
        if (!hadStats) return "…"
        if (charging && percent != null) return "$percent%"
        if (power == "ac" && percent == null) return L10n.text("android.homelogic.plugged_in.edefc1f9")
        if (percent != null) return "$percent%"
        if (power == "battery") return L10n.text("android.homelogic.on_battery.51d53044")
        if (power == "ac") return L10n.text("android.homelogic.plugged_in.edefc1f9")
        return L10n.text("android.homelogic.n_a.a683c5c5")
    }

    fun ramLabel(usedBytes: Long, totalBytes: Long): String {
        val g = 1024.0 * 1024 * 1024
        val u = usedBytes / g
        val t = totalBytes / g
        return if (t >= 10) L10n.text("android.homelogic.0f_0f_gb.196931f5").format(u, t) else L10n.text("android.homelogic.1f_1f_gb.520814df").format(u, t)
    }

    fun cpuLabel(cpu: Double): String = "${(cpu * 100).roundToInt()}%"

    fun routeLabel(route: String?): String? = when (route) {
        "direct" -> L10n.text("android.homelogic.direct_connection.28d0ad54")
        "relay" -> L10n.text("android.homelogic.encrypted_relay.153d7b1c")
        else -> null
    }
}
