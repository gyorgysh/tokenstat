// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.logic

import ai.tokenstat.tokenstat.ui.localization.L10n

import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.longOrNull

/// Shared host contract constants. Mirrors Apple `Bridge.swift`
/// `expectedProtocolVersion` and `RemoteHostFeature` minimums, plus the
/// `insights.snapshot` (proto 5) shape the Mac uses.
object HostContracts {
    const val PROTOCOL_VERSION = "30"
    const val WORKTREES_MIN_PROTOCOL = 24
    const val CHAT_MIN_PROTOCOL = 4
    const val CHAT_FORK_MIN_PROTOCOL = 26
    const val CHAT_REMOVE_ALL_MIN_PROTOCOL = 26
    fun supportsChatFork(protocol: Long?): Boolean = protocol != null && protocol >= CHAT_FORK_MIN_PROTOCOL
    fun supportsPullCreation(protocol: Long?): Boolean = protocol != null && protocol >= PULL_CREATION_MIN_PROTOCOL
    fun supportsChatRemoveAll(protocol: Long?): Boolean = protocol != null && protocol >= CHAT_REMOVE_ALL_MIN_PROTOCOL
    const val PULLS_MIN_PROTOCOL = 3
    const val PULL_CREATION_MIN_PROTOCOL = 28
    const val CHAT_QUESTIONS_MIN_PROTOCOL = 29

    /// Version 29 records the agent's questions and takes their answers. An
    /// older host never records one, so this guards the answer, not the card.
    fun supportsChatQuestions(protocol: Long?): Boolean =
        protocol != null && protocol >= CHAT_QUESTIONS_MIN_PROTOCOL

    /// Version 30 adds the reviewed fast-forward pull and `pulls.branch`,
    /// and conversations carry their branch with its pull request.
    const val REVIEWED_PULL_MIN_PROTOCOL = 30

    fun supportsReviewedPull(protocol: Long?): Boolean =
        protocol != null && protocol >= REVIEWED_PULL_MIN_PROTOCOL

    fun protocolOf(status: JsonObject?): Long? {
        fun version(key: String): Long? =
            (status?.get(key) as? JsonPrimitive)?.longOrNull?.takeIf { it > 0 }
        return version("protocol") ?: version("protocolVersion")
    }

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
    /// Version 25 adds a short note that rides the next tool step.
    const val TASK_EDITING_MIN_PROTOCOL = 17
    const val TASK_DELETION_MIN_PROTOCOL = 18
    const val TASK_CREATION_MIN_PROTOCOL = 19
    const val TASK_EXECUTION_MIN_PROTOCOL = 20
    const val AUTOMATION_RECEIPTS_MIN_PROTOCOL = 21
    const val WORKFLOW_EDITING_MIN_PROTOCOL = 22
    const val STEER_MIN_PROTOCOL = 25

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

    fun supportsSteer(protocol: Long?): Boolean =
        protocol == null || protocol >= STEER_MIN_PROTOCOL

    /// Version 6 added asking the host to read an agent's model list again,
    /// mirroring `RemoteHostFeature.modelRefresh`. An older host still lists
    /// the models it cached, so only the Refresh goes away.
    const val MODEL_REFRESH_MIN_PROTOCOL = 6

    fun supportsModelRefresh(protocol: Long?): Boolean =
        protocol == null || protocol >= MODEL_REFRESH_MIN_PROTOCOL

    /// Version 10 added `clientMessageId` on `chat.send` and `chat.receipt`,
    /// and version 14 added the send revision, mirroring
    /// `RemoteHostFeature.confirmedSend`. A host below 14 refuses an id
    /// without the revision, so sending needs all of 14 while reading an
    /// older receipt only needs 10.
    const val RECEIPT_MIN_PROTOCOL = 10
    const val CONFIRMED_SEND_MIN_PROTOCOL = 14

    fun supportsReceipt(protocol: Long?): Boolean =
        protocol == null || protocol >= RECEIPT_MIN_PROTOCOL

    fun supportsConfirmedSend(protocol: Long?): Boolean =
        protocol == null || protocol >= CONFIRMED_SEND_MIN_PROTOCOL

    /// Version 14 added the host self-update check and apply, mirroring
    /// `RemoteHostFeature.hostUpdate`.
    const val HOST_UPDATE_MIN_PROTOCOL = 14

    fun supportsHostUpdate(protocol: Long?): Boolean =
        protocol == null || protocol >= HOST_UPDATE_MIN_PROTOCOL

    /// A transport error fails open, preserving the screen's offline and
    /// retry behaviour. Only a definite older protocol becomes the update
    /// state, mirroring `RemoteHostFeatureGate`.
    fun updateMessage(feature: String, hostName: String, hostProtocol: Long?, minimum: Long): String? {
        if (hostProtocol == null || hostProtocol >= minimum) return null
        val computer = hostName.ifBlank { L10n.text("android.hostcontracts.this_computer.058bf37c") }
        return L10n.text("android.hostcontracts.update_0_to_use_1_it_speaks_protocol_2_and.1240aa62", "${computer}", "${feature}", "${hostProtocol}", "${minimum}")
    }
}

/// Relative time, port of Apple `RelativeTimeText.swift` (single 15s tick).
/// Returns a short string; callers re-compose on a 15s ticker.
object RelativeClock {
    private fun unit(count: Long, unit: String): String = when (unit) {
        "second" -> if (count == 1L) L10n.text("android.hostcontracts.second_one", count)
            else L10n.text("android.hostcontracts.second_other", count)
        "minute" -> if (count == 1L) L10n.text("android.hostcontracts.minute_one", count)
            else L10n.text("android.hostcontracts.minute_other", count)
        "hour" -> if (count == 1L) L10n.text("android.hostcontracts.hour_one", count)
            else L10n.text("android.hostcontracts.hour_other", count)
        "day" -> if (count == 1L) L10n.text("android.hostcontracts.day_one", count)
            else L10n.text("android.hostcontracts.day_other", count)
        "week" -> if (count == 1L) L10n.text("android.hostcontracts.week_one", count)
            else L10n.text("android.hostcontracts.week_other", count)
        "month" -> if (count == 1L) L10n.text("android.hostcontracts.month_one", count)
            else L10n.text("android.hostcontracts.month_other", count)
        "year" -> if (count == 1L) L10n.text("android.hostcontracts.year_one", count)
            else L10n.text("android.hostcontracts.year_other", count)
        else -> error("Unknown relative time unit: $unit")
    }

    /// "3 days ago", in full words the way Foundation's numeric relative
    /// style phrases it: seconds, minutes, hours, days, then weeks to months
    /// to years, each rounded to the nearest rather than floored, so a reset
    /// 2.8 days out reads "in 3 days" here and on the Apple client alike.
    fun label(epochMillis: Long, nowMillis: Long = System.currentTimeMillis()): String {
        val delta = ((nowMillis - epochMillis) / 1000).coerceAtLeast(0)
        if (delta < 5) return L10n.text("android.hostcontracts.now.ed5eb9a3")
        if (delta < 60) return L10n.text("android.hostcontracts.0_ago.cace2682", "${unit(delta, "second")}")
        val minutes = (delta + 30) / 60
        if (minutes < 60) return L10n.text("android.hostcontracts.0_ago.cace2682", "${unit(minutes, "minute")}")
        val hours = (delta + 1800) / 3600
        if (hours < 24) return L10n.text("android.hostcontracts.0_ago.cace2682", "${unit(hours, "hour")}")
        val days = (delta + 43200) / 86400
        if (days < 7) return L10n.text("android.hostcontracts.0_ago.cace2682", "${unit(days, "day")}")
        if (days < 30) return L10n.text("android.hostcontracts.0_ago.cace2682", "${unit((days + 3) / 7, "week")}")
        if (days < 365) return L10n.text("android.hostcontracts.0_ago.cace2682", "${unit((days + 15) / 30, "month")}")
        return L10n.text("android.hostcontracts.0_ago.cace2682", "${unit((days + 182) / 365, "year")}")
    }

    /// "4h ago", the tightest form, for a row that already carries a title
    /// and an agent name beside it. The iPhone's conversation list uses this
    /// one: "5 hours ago" spent a third of the row saying what "5h ago"
    /// says, and the row has better uses for the width.
    fun compact(epochMillis: Long, nowMillis: Long = System.currentTimeMillis()): String {
        val delta = ((nowMillis - epochMillis) / 1000).coerceAtLeast(0)
        if (delta < 60) return "now"
        val minutes = (delta + 30) / 60
        if (minutes < 60) return L10n.text("android.hostcontracts.0_m_ago.80e8bfb2", "${minutes}")
        val hours = (delta + 1800) / 3600
        if (hours < 24) return L10n.text("android.hostcontracts.0_h_ago.4dcb4701", "${hours}")
        val days = (delta + 43200) / 86400
        if (days < 7) return L10n.text("android.hostcontracts.0_d_ago.1fccd42c", "${days}")
        if (days < 30) return L10n.text("android.hostcontracts.0_w_ago.ac944c0b", "${(days + 3) / 7}")
        if (days < 365) return L10n.text("android.hostcontracts.0_mo_ago.cff21a7f", "${(days + 15) / 30}")
        return L10n.text("android.hostcontracts.0_y_ago.cd926fc6", "${(days + 182) / 365}")
    }

    /// "3 min ago", for chat rows and run times. The same abbreviated
    /// units Foundation's abbreviated style draws: seconds, minutes and
    /// hours shorten, days stay written out, weeks and up shorten again.
    fun abbreviated(epochMillis: Long, nowMillis: Long = System.currentTimeMillis()): String {
        val delta = (nowMillis - epochMillis) / 1000
        if (delta >= 0 && delta < 1) return L10n.text("android.hostcontracts.just_now.7ddb44d8")
        if (delta < 0) return abbreviatedFuture(-delta)
        if (delta < 60) return L10n.text("android.hostcontracts.0_sec_ago.c7378507", "${delta}")
        val minutes = (delta + 30) / 60
        if (minutes < 60) return L10n.text("android.hostcontracts.0_min_ago.dcf6607f", "${minutes}")
        val hours = (delta + 1800) / 3600
        if (hours < 24) return L10n.text("android.hostcontracts.0_hr_ago.b7fe402d", "${hours}")
        val days = (delta + 43200) / 86400
        if (days < 7) return L10n.text("android.hostcontracts.0_ago.cace2682", "${unit(days, "day")}")
        if (days < 30) return L10n.text("android.hostcontracts.0_wk_ago.fab70bb9", "${(days + 3) / 7}")
        if (days < 365) return L10n.text("android.hostcontracts.0_mo_ago.04b80750", "${(days + 15) / 30}")
        return L10n.text("android.hostcontracts.0_yr_ago.74473101", "${(days + 182) / 365}")
    }

    private fun abbreviatedFuture(delta: Long): String {
        if (delta < 60) return L10n.text("android.hostcontracts.in_0_sec.f5785258", "${delta}")
        val minutes = (delta + 30) / 60
        if (minutes < 60) return L10n.text("android.hostcontracts.in_0_min.c07b3a18", "${minutes}")
        val hours = (delta + 1800) / 3600
        if (hours < 24) return L10n.text("android.hostcontracts.in_hours", hours)
        val days = (delta + 43200) / 86400
        if (days < 7) return L10n.text("android.hostcontracts.in_unit", unit(days, "day"))
        if (days < 30) return L10n.text("android.hostcontracts.in_weeks", (days + 3) / 7)
        if (days < 365) return L10n.text("android.hostcontracts.in_months", (days + 15) / 30)
        return L10n.text("android.hostcontracts.in_years", (days + 182) / 365)
    }

    /// Future mirror of `label`: "in 3 days", for limit reset dates.
    fun until(epochMillis: Long, nowMillis: Long = System.currentTimeMillis()): String {
        val delta = (epochMillis - nowMillis) / 1000
        if (delta < 0) return label(epochMillis, nowMillis)
        if (delta < 5) return L10n.text("android.hostcontracts.now.ed5eb9a3")
        if (delta < 60) return L10n.text("android.hostcontracts.in_unit", unit(delta, "second"))
        val minutes = (delta + 30) / 60
        if (minutes < 60) return L10n.text("android.hostcontracts.in_unit", unit(minutes, "minute"))
        val hours = (delta + 1800) / 3600
        if (hours < 24) return L10n.text("android.hostcontracts.in_unit", unit(hours, "hour"))
        val days = (delta + 43200) / 86400
        if (days < 7) return L10n.text("android.hostcontracts.in_unit", unit(days, "day"))
        if (days < 30) return L10n.text("android.hostcontracts.in_unit", unit((days + 3) / 7, "week"))
        if (days < 365) return L10n.text("android.hostcontracts.in_unit", unit((days + 15) / 30, "month"))
        return L10n.text("android.hostcontracts.in_unit", unit((days + 182) / 365, "year"))
    }
}
