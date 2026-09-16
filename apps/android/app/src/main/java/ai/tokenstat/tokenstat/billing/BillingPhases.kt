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

/// The trial line under a plan card, from the offer Play actually returned.
/// A single phase means no intro, so nothing renders: the sheet never
/// promises a trial Play did not configure.
fun introCaption(phases: List<PhaseView>): String? {
    if (phases.size < 2) return null
    val intro = phases.first()
    val regular = phases.last()
    return "${intro.formattedPrice} for ${humanizeBillingPeriod(intro.billingPeriod)}, then ${regular.formattedPrice}."
}
