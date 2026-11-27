// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.billing

import ai.tokenstat.tokenstat.ui.localization.L10n

fun humanizeBillingPeriod(period: String, cycles: Int = 1): String {
    val match = Regex("^P(\\d+)([DWMY])$").matchEntire(period.trim().uppercase()) ?: return period
    val count = (match.groupValues[1].toIntOrNull() ?: return period) * cycles.coerceAtLeast(1)
    val unit = when (match.groupValues[2]) {
        "D" -> if (count == 1) "day" else "days"
        "W" -> if (count == 1) "week" else "weeks"
        "M" -> if (count == 1) "month" else "months"
        "Y" -> if (count == 1) "year" else "years"
        else -> return period
    }
    return "$count $unit"
}

data class PhaseView(val formattedPrice: String, val billingPeriod: String, val cycles: Int = 1)

fun intervalOfBasePlan(basePlanId: String, billingPeriod: String): String? {
    when (Regex("^P\\d+([DWMY])$").matchEntire(billingPeriod.trim().uppercase())?.groupValues?.get(1)) {
        "M" -> return "month"
        "Y" -> return "year"
        "D", "W" -> return null
    }
    return when (basePlanId.trim().lowercase()) {
        "monthly" -> "month"
        "annual", "yearly" -> "year"
        else -> null
    }
}

fun introCaption(phases: List<PhaseView>): String? {
    if (phases.size < 2) return null
    val intro = phases.first()
    val regular = phases.last()
    return L10n.text("android.billingphases.0_for_1_then_2.dba51e31", "${intro.formattedPrice}", "${humanizeBillingPeriod(intro.billingPeriod, intro.cycles)}", "${regular.formattedPrice}")
}

const val PROMO_OFFER_TAG = "promo"

data class OfferView(val offerId: String?, val tags: List<String>, val firstPriceMicros: Long)

fun <T> bestOffer(group: List<T>, trialUsed: Boolean, view: (T) -> OfferView): T? {
    val base = group.firstOrNull { view(it).offerId == null } ?: return null
    val basePrice = view(base).firstPriceMicros
    return group
        .filter {
            val offer = view(it)
            offer.offerId != null &&
                offer.tags.any { tag -> tag.equals(PROMO_OFFER_TAG, ignoreCase = true) } &&
                !(trialUsed && offer.firstPriceMicros == 0L) &&
                offer.firstPriceMicros < basePrice
        }
        .minByOrNull { view(it).firstPriceMicros }
        ?: base
}
