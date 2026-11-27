// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.marks

import ai.tokenstat.tokenstat.ui.localization.L10n

internal fun planTitle(tier: String): String = when (tier.lowercase()) {
    "free" -> L10n.text("common.plan.free")
    "supporter" -> L10n.text("common.plan.supporter")
    "patron" -> L10n.text("common.plan.patron")
    "legend" -> L10n.text("common.plan.legend")
    else -> tier.replaceFirstChar { it.uppercase() }
}
