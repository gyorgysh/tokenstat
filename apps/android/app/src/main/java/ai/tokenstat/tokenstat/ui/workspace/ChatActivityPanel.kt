// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.workspace

import ai.tokenstat.tokenstat.ui.components.ActionIcon
import ai.tokenstat.tokenstat.ui.localization.L10n
import ai.tokenstat.tokenstat.ui.theme.LocalTsColors
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import java.text.NumberFormat
import java.text.DateFormat
import java.util.Date
import kotlinx.serialization.json.JsonObject

private fun activityText(key: String, vararg args: String): String {
    val resource = "common.chat.activity.$key"
    return L10n.text(resource, *args)
}
private fun activitySource(value: String) = if (value in listOf("agent", "tool")) activityText("source_$value") else value
private fun activityNumber(value: Double) = NumberFormat.getIntegerInstance().format(value)
private fun activityStatus(status: String, live: Boolean): String {
    val value = activityText("status_$status")
    return if (live) value else activityText("last_reported", value)
}
private fun activitySummary(data: ChatActivityData): String = buildList {
    data.goal?.let { goal ->
        add(activityStatus(goal.status, data.live))
        goal.tokenBudget?.let { budget -> add(activityText("tokens") + " " + activityText("progress", goal.tokensUsed?.let(::activityNumber) ?: "—", activityNumber(budget))) }
    }
    if (data.planReported && data.plan.isNotEmpty()) add(activityText("steps", "${data.completedSteps}", "${data.plan.size}"))
    if (data.agentsReported && data.agents.isNotEmpty()) add(data.runningAgents?.let { activityText("running_agents", "$it") }
        ?: activityText(if (data.agents.size == 1) "one_subagent" else "agents", "${data.agents.size}"))
    data.headline?.takeIf { it.isNotBlank() }?.let(::add)
}.joinToString(" · ").ifBlank { activityText("no_activity") }

@Composable internal fun ChatActivitySummary(data: ChatActivityData?, onOpen: () -> Unit) {
    if (data?.hasContent != true) return
    Surface(shape = RoundedCornerShape(8.dp), color = LocalTsColors.current.panel) {
        Row(Modifier.fillMaxWidth().clickable(onClick = onOpen).padding(horizontal = 10.dp, vertical = 8.dp),
            horizontalArrangement = Arrangement.spacedBy(7.dp), verticalAlignment = Alignment.CenterVertically) {
            Icon(ActionIcon.Plan.vector, null, Modifier.size(16.dp), tint = LocalTsColors.current.accent)
            Text(activityText("title"), style = MaterialTheme.typography.labelMedium, fontWeight = FontWeight.SemiBold)
            Text(activitySummary(data), Modifier.weight(1f), maxLines = 1, overflow = TextOverflow.Ellipsis,
                style = MaterialTheme.typography.labelSmall, color = LocalTsColors.current.textSecondary)
            Icon(ActionIcon.Disclosure.vector, activityText("details"), Modifier.size(16.dp), tint = LocalTsColors.current.textSecondary)
        }
    }
}

@Composable internal fun ChatPlanChecklist(data: ChatActivityData) {
    Surface(shape = RoundedCornerShape(10.dp), color = LocalTsColors.current.panel) {
        Column(Modifier.fillMaxWidth().padding(12.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                Text(activityText("plan"), Modifier.weight(1f), style = MaterialTheme.typography.bodySmall, fontWeight = FontWeight.Medium)
                ActivityNote(activityText("steps", "${data.completedSteps}", "${data.plan.size}"))
            }
            ActivityPlanSteps(data)
            if (!data.live) ActivityNote(activityText("report_only"))
        }
    }
}

@Composable private fun ActivityPlanSteps(data: ChatActivityData) {
    data.plan.forEach { step ->
        Row(Modifier.fillMaxWidth().padding(vertical = 3.dp), horizontalArrangement = Arrangement.spacedBy(7.dp)) {
            Icon(if (step.status == "completed") ActionIcon.Done.vector else if (step.status == "inProgress") ActionIcon.Run.vector else ActionIcon.Scheduled.vector,
                activityStatus(step.status, data.live), Modifier.size(16.dp),
                tint = if (data.live && step.status == "inProgress") LocalTsColors.current.accent else LocalTsColors.current.textSecondary)
            Text(step.text, style = MaterialTheme.typography.bodySmall,
                color = if (step.status == "completed") LocalTsColors.current.textSecondary else LocalTsColors.current.textPrimary)
        }
    }
}

@Composable internal fun ChatActivityPanel(inspection: JsonObject?, chat: JsonObject, initialSection: String? = null, initiallyExpanded: Boolean = false, loaded: Boolean = true) {
    val data = chatActivityData(inspection, chat)
    val owner = listOf(chat.str("id"), chat.str("backend"), chat.str("model"), chat["runRevision"])
    var expanded by remember(chat.str("id"), chat.str("backend"), chat.str("model"), initialSection) { mutableStateOf(initiallyExpanded || initialSection != null) }
    Surface(shape = RoundedCornerShape(10.dp), color = LocalTsColors.current.panel) {
        Column(Modifier.fillMaxWidth().padding(horizontal = 10.dp, vertical = 6.dp), verticalArrangement = Arrangement.spacedBy(5.dp)) {
            Row(Modifier.fillMaxWidth().heightIn(min = 36.dp).clickable { expanded = !expanded }
                .semantics { stateDescription = L10n.text(if (expanded) "common.collapse" else "common.expand") },
                horizontalArrangement = Arrangement.spacedBy(7.dp), verticalAlignment = Alignment.CenterVertically) {
                Icon(ActionIcon.Plan.vector, null, Modifier.size(16.dp), tint = LocalTsColors.current.accent)
                Text(activityText("title"), fontWeight = FontWeight.SemiBold, style = MaterialTheme.typography.bodySmall)
                Text(data?.let(::activitySummary).orEmpty(), Modifier.weight(1f), maxLines = 1, overflow = TextOverflow.Ellipsis,
                    style = MaterialTheme.typography.labelSmall, color = LocalTsColors.current.textSecondary)
                Icon(if (expanded) ActionIcon.Latest.vector else ActionIcon.Disclosure.vector, null, Modifier.size(16.dp))
            }
            if (expanded) {
                if (data == null) {
                    if (!loaded) CircularProgressIndicator(Modifier.size(16.dp), strokeWidth = 2.dp)
                    else ActivityNote(activityText("unavailable"))
                }
                else {
                    ActivityNote(activityText(if (data.live) "live" else "report_only"))
                    ActivitySection(activityText("goal"), initialSection == "goal" || initialSection in listOf(null, "all") && data.goal != null, owner = owner) {
                        val goal = data.goal
                        if (!data.goalReported) ActivityNote(activityText("not_reported"))
                        else if (goal == null) ActivityNote(activityText("none"))
                        else {
                            Text(goal.objective, style = MaterialTheme.typography.bodySmall)
                            ActivityNote(activityStatus(goal.status, data.live))
                            ActivityMetric("tokens", goal.tokensUsed, goal.tokenBudget)
                            ActivityMetric("time", goal.timeUsedSeconds, goal.timeBudgetSeconds, seconds = true)
                            goal.source?.let { ActivityNote(activityText("source", activitySource(it))) }
                        }
                    }
                    ActivitySection(activityText("plan"), initialSection == "plan" || initialSection in listOf(null, "all") && data.plan.isNotEmpty(), owner = owner) {
                        if (!data.planReported) ActivityNote(activityText("not_reported"))
                        else if (data.plan.isEmpty()) ActivityNote(activityText("none"))
                        else {
                            ActivityNote(activityText("steps", "${data.completedSteps}", "${data.plan.size}"))
                            ActivityProgress(data.completedSteps.toFloat() / data.plan.size)
                            ActivityPlanSteps(data)
                            data.planSource?.let { ActivityNote(activityText("source", activitySource(it))) }
                        }
                    }
                    ActivitySection(activityText("subagents"), initialSection == "subagents" || initialSection in listOf(null, "all") && data.agents.isNotEmpty(), owner = owner) {
                        if (!data.agentsReported) ActivityNote(activityText("not_reported"))
                        else if (data.agents.isEmpty()) ActivityNote(activityText("none"))
                        else data.agents.forEach { agent ->
                            ActivitySection(agent.name ?: agent.id, data.live && agent.status in listOf("running", "waiting"),
                                activityStatus(agent.displayStatus(data.live), data.live), owner = owner) {
                                if (agent.name != null) ActivityNote(agent.id)
                                agent.task?.let { Text(it, style = MaterialTheme.typography.bodySmall) }
                                agent.model?.let { ActivityNote(it) }
                                agent.source?.let { ActivityNote(activityText("source", activitySource(it))) }
                            }
                        }
                    }
                    if (data.partial) ActivityNote(activityText("partial"))
                    data.observedAtMs?.let { ActivityNote(activityText("last_reported", DateFormat.getDateTimeInstance(DateFormat.MEDIUM, DateFormat.SHORT).format(Date(it)))) }
                }
            }
        }
    }
}
@Composable private fun ActivityNote(value: String) { Text(value, style = MaterialTheme.typography.labelSmall, color = LocalTsColors.current.textSecondary) }
@Composable private fun ActivityMetric(label: String, used: Double?, budget: Double?, seconds: Boolean = false) {
    if (used == null && budget == null) return
    fun amount(value: Double?) = value?.let { if (seconds) activityText("seconds", activityNumber(it)) else activityNumber(it) } ?: activityText("not_reported")
    val value = if (budget == null) amount(used) else activityText("progress", amount(used), amount(budget))
    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        Text(activityText(label), Modifier.weight(1f), style = MaterialTheme.typography.labelSmall, color = LocalTsColors.current.textSecondary)
        Text(value, style = MaterialTheme.typography.labelSmall)
    }
    chatActivityProgress(used, budget)?.let { ActivityProgress(it) }
}
@Composable private fun ActivityProgress(fraction: Float) {
    LinearProgressIndicator(progress = { fraction }, modifier = Modifier.fillMaxWidth().height(4.dp))
}
@Composable private fun ActivitySection(title: String, initiallyExpanded: Boolean, status: String? = null, owner: Any? = null, content: @Composable ColumnScope.() -> Unit) {
    var choice by remember(title, owner) { mutableStateOf<Boolean?>(null) }
    val expanded = choice ?: initiallyExpanded
    Column(Modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(4.dp)) {
        Row(Modifier.fillMaxWidth().heightIn(min = 34.dp).clickable { choice = !expanded }
            .semantics { stateDescription = L10n.text(if (expanded) "common.collapse" else "common.expand") },
            horizontalArrangement = Arrangement.spacedBy(6.dp), verticalAlignment = Alignment.CenterVertically) {
            Text(title, Modifier.weight(1f), style = MaterialTheme.typography.bodySmall, fontWeight = FontWeight.Medium, maxLines = 1, overflow = TextOverflow.Ellipsis)
            if (status != null) ActivityNote(status)
            Icon(if (expanded) ActionIcon.Latest.vector else ActionIcon.Disclosure.vector, null, Modifier.size(14.dp))
        }
        if (expanded) Column(Modifier.padding(start = 6.dp, bottom = 4.dp), verticalArrangement = Arrangement.spacedBy(4.dp), content = content)
    }
}
