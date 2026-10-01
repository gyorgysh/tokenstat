// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.logic

import ai.tokenstat.tokenstat.ui.localization.L10n

/// What one device contributed, port of `MachineUsage` in
/// `Bridge/Models.swift`. The account's machine id is the map key at the
/// call site, so it is not repeated here.
data class DeviceUsage(
    val valueMicros: Long,
    val events: Long,
    val activeDays: Int,
    val days: Int,
)

/// How far back a tier's device spend looks, port of `DeviceHistory.days`.
/// Free a month, supporter a year, patron and legend everything the series
/// still holds. The host clamps the upper bound; the server still enforces
/// each account's own depth.
fun deviceHistoryDays(tier: String?): Int = when (tier?.lowercase()) {
    "legend", "patron" -> 3650
    "supporter" -> 365
    else -> 30
}

/// Human window for labels, port of `DeviceHistory.windowPhrase`:
/// "all time", "the last year", "the last day", "the last N days".
fun deviceWindowPhrase(days: Int): String = when {
    days >= 1000 -> L10n.text("android.devicehistory.all_time.c79ddf2b")
    days >= 360 -> L10n.text("android.devicehistory.the_last_year.ce4cc449")
    days == 1 -> L10n.text("android.devicehistory.the_last_day.8319fd61")
    else -> L10n.text("android.devicehistory.the_last_0_days.1bfce3a7", "${days}")
}

/// The line under a device's spend figure, port of the `detail` builder in
/// `ClientDeviceDetailView`: active days, events, and the share of the
/// account when the account total is known. Events keep their full digits
/// with separators, the way `events.formatted()` renders them.
fun deviceSpendDetail(
    usage: DeviceUsage,
    accountTotalMicros: Long,
    formatEvents: (Long) -> String = { "%,d".format(it) },
): String {
    val parts = mutableListOf(
        if (usage.activeDays == 1) L10n.text("android.devicehistory.1_active_day.1b05d320") else L10n.text("android.devicehistory.0_active_days.16d30c85", "${usage.activeDays}"),
        L10n.text("android.devicehistory.0_events.a7742aab", "${formatEvents(usage.events)}"),
    )
    if (accountTotalMicros > 0) {
        val share = usage.valueMicros.toDouble() / accountTotalMicros * 100
        parts.add(L10n.text("android.devicehistory.0f_of_the_account.ed5d357e").format(share))
    }
    return parts.joinToString(", ")
}
