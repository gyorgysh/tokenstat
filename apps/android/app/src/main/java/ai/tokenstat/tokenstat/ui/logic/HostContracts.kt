// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.logic

import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.longOrNull

/// Shared host contract constants. Mirrors Apple `Bridge.swift`
/// `expectedProtocolVersion` and `RemoteHostFeature` minimums, plus the
/// `insights.snapshot` (proto 5) shape the Mac uses.
object HostContracts {
    const val PROTOCOL_VERSION = "22"
    const val CHAT_MIN_PROTOCOL = 4
    const val PULLS_MIN_PROTOCOL = 3

    fun protocolOf(status: kotlinx.serialization.json.JsonObject?): Long? =
        status?.get("protocol")?.jsonPrimitive?.longOrNull
            ?: status?.get("protocolVersion")?.jsonPrimitive?.longOrNull

    fun supportsChat(protocol: Long?): Boolean =
        protocol == null || protocol >= CHAT_MIN_PROTOCOL

    fun supportsPulls(protocol: Long?): Boolean =
        protocol == null || protocol >= PULLS_MIN_PROTOCOL

    /// Version 15 added reviewed selected-file commits and outcome
    /// recovery. Version 16 added reviewed branch push and recovery.
    const val SELECTED_COMMIT_MIN_PROTOCOL = 15
    const val REVIEWED_PUSH_MIN_PROTOCOL = 16

    fun supportsSelectedCommit(protocol: Long?): Boolean =
        protocol == null || protocol >= SELECTED_COMMIT_MIN_PROTOCOL

    fun supportsReviewedPush(protocol: Long?): Boolean =
        protocol == null || protocol >= REVIEWED_PUSH_MIN_PROTOCOL

    /// Version 17 added revision-checked task editing. Version 18 added
    /// checked task deletion. Version 19 added create-once tasks. Version
    /// 20 added checked task runs, exact-run stops and launch receipts.
    /// Version 21 added revision-checked automation edits and create/run
    /// receipts. Version 22 added revision-checked workflow edits.
    const val TASK_EDITING_MIN_PROTOCOL = 17
    const val TASK_DELETION_MIN_PROTOCOL = 18
    const val TASK_CREATION_MIN_PROTOCOL = 19
    const val TASK_EXECUTION_MIN_PROTOCOL = 20
    const val AUTOMATION_RECEIPTS_MIN_PROTOCOL = 21
    const val WORKFLOW_EDITING_MIN_PROTOCOL = 22

    fun supportsTaskEditing(protocol: Long?): Boolean =
        protocol == null || protocol >= TASK_EDITING_MIN_PROTOCOL

    fun supportsTaskDeletion(protocol: Long?): Boolean =
        protocol == null || protocol >= TASK_DELETION_MIN_PROTOCOL

    fun supportsTaskCreation(protocol: Long?): Boolean =
        protocol == null || protocol >= TASK_CREATION_MIN_PROTOCOL

    fun supportsTaskExecution(protocol: Long?): Boolean =
        protocol == null || protocol >= TASK_EXECUTION_MIN_PROTOCOL

    fun supportsAutomationReceipts(protocol: Long?): Boolean =
        protocol == null || protocol >= AUTOMATION_RECEIPTS_MIN_PROTOCOL

    fun supportsWorkflowEditing(protocol: Long?): Boolean =
        protocol == null || protocol >= WORKFLOW_EDITING_MIN_PROTOCOL

    /// A transport error fails open, preserving the screen's offline and
    /// retry behaviour. Only a definite older protocol becomes the update
    /// state, mirroring `RemoteHostFeatureGate`.
    fun updateMessage(feature: String, hostName: String, hostProtocol: Long?, minimum: Long): String? {
        if (hostProtocol == null || hostProtocol >= minimum) return null
        val computer = hostName.ifBlank { "this computer" }
        return "Update $computer to use $feature. It speaks protocol $hostProtocol and needs $minimum or later."
    }
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

