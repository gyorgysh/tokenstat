// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.logic

import ai.tokenstat.tokenstat.ui.localization.L10n

data class InsightFactPanel(
    val label: String,
    val value: String,
    val mark: String,
)

fun insightFactPanels(
    tokens: Long,
    events: Long,
    count: Int,
    countLabel: String,
    formatCompact: (Long) -> String,
): List<InsightFactPanel> = listOf(
    InsightFactPanel(label = L10n.text("android.insightfacts.tokens.a039dfb9"), value = formatCompact(tokens), mark = "mark_insights"),
    InsightFactPanel(label = L10n.text("android.insightfacts.events.8d14f6e7"), value = formatCompact(events), mark = "mark_activity"),
    InsightFactPanel(label = countLabel, value = count.toString(), mark = "mark_examples"),
)
