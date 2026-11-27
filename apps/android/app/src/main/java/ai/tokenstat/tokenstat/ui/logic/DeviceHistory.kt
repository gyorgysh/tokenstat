// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.logic

import ai.tokenstat.tokenstat.ui.localization.L10n

data class DeviceUsage(
    val valueMicros: Long,
    val events: Long,
    val activeDays: Int,
    val days: Int,
)

fun deviceHistoryDays(tier: String?): Int = when (tier?.lowercase()) {
    "legend", "patron" -> 3650
    "supporter" -> 365
    else -> 30
}

fun deviceWindowPhrase(days: Int): String = when {
    days >= 1000 -> L10n.text("android.devicehistory.all_time.c79ddf2b")
    days >= 360 -> L10n.text("android.devicehistory.the_last_year.ce4cc449")
    days == 1 -> L10n.text("android.devicehistory.the_last_day.8319fd61")
    else -> L10n.text("android.devicehistory.the_last_0_days.1bfce3a7", "${days}")
}

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
