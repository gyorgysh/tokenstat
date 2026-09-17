// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.logic

/// One fact under Insights' "This period" total: which figure it is, the
/// already formatted value, and the house mark drawn on its trailing tile.
/// Port of the tuples `ClientInsightFacts.panels` returns.
data class InsightFactPanel(
    val label: String,
    val value: String,
    val mark: String,
)

/// The three figures under Insights' "This period" total, in display order.
/// Port of `ClientInsightFacts.panels`: tokens, events, then the current
/// cut's own count (models, harnesses or days). The compact formatter is
/// injected for both tokens and events, so a 125,844 reading becomes "126k"
/// and fits the same panel width as "26.9B".
fun insightFactPanels(
    tokens: Long,
    events: Long,
    count: Int,
    countLabel: String,
    formatCompact: (Long) -> String,
): List<InsightFactPanel> = listOf(
    InsightFactPanel(label = "Tokens", value = formatCompact(tokens), mark = "mark_insights"),
    InsightFactPanel(label = "Events", value = formatCompact(events), mark = "mark_activity"),
    InsightFactPanel(label = countLabel, value = count.toString(), mark = "mark_examples"),
)
