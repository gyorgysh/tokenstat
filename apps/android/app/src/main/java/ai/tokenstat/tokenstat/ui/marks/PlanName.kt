// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.marks

import ai.tokenstat.tokenstat.ui.localization.L10n

/**
 * What a plan is called where a person reads it.
 *
 * The account server and Play keep the original keys (`supporter`, `patron`,
 * `legend`) because product ids and existing subscriptions depend on them.
 * People see Plus, Pro and Elite, so a tier key is never capitalized into a
 * label: it goes through here.
 */
internal fun planTitle(tier: String): String = when (tier.lowercase()) {
    "free" -> L10n.text("common.plan.free")
    "supporter" -> L10n.text("common.plan.supporter")
    "patron" -> L10n.text("common.plan.patron")
    "legend" -> L10n.text("common.plan.legend")
    else -> tier.replaceFirstChar { it.uppercase() }
}
