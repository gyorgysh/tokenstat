// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.billing

/// Human words for a Play Billing ISO-8601 period (`P3D`, `P1W`, `P1M`,
/// `P1Y`, `P6M`). Unknown shapes pass through untouched rather than
/// rendering as a wrong duration.
fun humanizeBillingPeriod(period: String): String {
    val match = Regex("^P(\\d+)([DWMY])$").matchEntire(period.trim().uppercase()) ?: return period
    val count = match.groupValues[1].toIntOrNull() ?: return period
    val unit = when (match.groupValues[2]) {
        "D" -> if (count == 1) "day" else "days"
        "W" -> if (count == 1) "week" else "weeks"
        "M" -> if (count == 1) "month" else "months"
        "Y" -> if (count == 1) "year" else "years"
        else -> return period
    }
    return "$count $unit"
}

/// One Play pricing phase, as the caption needs it.
data class PhaseView(val formattedPrice: String, val billingPeriod: String)

/// Which paywall tab a base plan belongs on: "month", "year", or null when
/// it is neither. The billing period decides, not the base plan id: the
/// yearly plan is called `annual` on patron and supporter but `yearly` on
/// legend, and an id is only a name while the period is the fact. An
/// unreadable period falls back to the known ids rather than hiding a plan
/// Play is actually selling.
fun intervalOfBasePlan(basePlanId: String, billingPeriod: String): String? {
    when (Regex("^P\\d+([DWMY])$").matchEntire(billingPeriod.trim().uppercase())?.groupValues?.get(1)) {
        "M" -> return "month"
        "Y" -> return "year"
        // A weekly or daily plan is definitively neither tab: no id
        // fallback, or a misnamed id would put it on the wrong one.
        "D", "W" -> return null
    }
    return when (basePlanId.trim().lowercase()) {
        "monthly" -> "month"
        "annual", "yearly" -> "year"
        else -> null
    }
}

/// The trial line under a plan card, from the offer Play actually returned.
/// A single phase means no intro, so nothing renders: the sheet never
/// promises a trial Play did not configure.
fun introCaption(phases: List<PhaseView>): String? {
    if (phases.size < 2) return null
    val intro = phases.first()
    val regular = phases.last()
    return "${intro.formattedPrice} for ${humanizeBillingPeriod(intro.billingPeriod)}, then ${regular.formattedPrice}."
}
