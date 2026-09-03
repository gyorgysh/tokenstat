// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.logic

import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.longOrNull

/// Shared host contract constants. Mirrors Apple `Bridge.swift`
/// `expectedProtocolVersion` and `RemoteHostFeature` minimums, plus the
/// `insights.snapshot` (proto 5) shape the Mac uses.
object HostContracts {
    const val PROTOCOL_VERSION = "5"
    const val CHAT_MIN_PROTOCOL = 4
    const val PULLS_MIN_PROTOCOL = 3

    fun protocolOf(status: kotlinx.serialization.json.JsonObject?): Long? =
        status?.get("protocol")?.jsonPrimitive?.longOrNull
            ?: status?.get("protocolVersion")?.jsonPrimitive?.longOrNull

    fun supportsChat(protocol: Long?): Boolean =
        protocol == null || protocol >= CHAT_MIN_PROTOCOL

    fun supportsPulls(protocol: Long?): Boolean =
        protocol == null || protocol >= PULLS_MIN_PROTOCOL
}

/// Relative time, port of Apple `RelativeTimeText.swift` (single 15s tick).
/// Returns a short string; callers re-compose on a 15s ticker.
object RelativeClock {
    fun label(epochMillis: Long, nowMillis: Long = System.currentTimeMillis()): String {
        val delta = (nowMillis - epochMillis) / 1000
        if (delta < 5) return "now"
        if (delta < 60) return "${delta}s ago"
        val minutes = delta / 60
        if (minutes < 60) return "${minutes}m ago"
        val hours = minutes / 60
        if (hours < 24) return "${hours}h ago"
        val days = hours / 24
        if (days < 7) return "${days}d ago"
        return java.text.SimpleDateFormat("MMM d", java.util.Locale.US)
            .format(java.util.Date(epochMillis))
    }
}

/// Run outcome tints, port of Apple `RunVisuals` (outcome tints only;
/// history strip and duration bar remain simplified).
object RunVisuals {
    fun succeeded(status: String?): Boolean =
        status.equals("succeeded", true) || status.equals("ok", true) || status.equals("done", true)
    fun failed(status: String?): Boolean =
        status.equals("failed", true) || status.equals("error", true)
}
