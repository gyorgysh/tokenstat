// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.workspace

import kotlinx.serialization.json.*

internal data class ChatActivityGoal(val objective: String, val status: String, val tokenBudget: Double?, val tokensUsed: Double?,
    val timeBudgetSeconds: Double?, val timeUsedSeconds: Double?, val source: String?)
internal data class ChatActivityStep(val text: String, val status: String)
internal data class ChatActivityAgent(val id: String, val name: String?, val task: String?, val status: String, val model: String?, val source: String?) {
    fun displayStatus(live: Boolean) = if (!live && status in setOf("pending", "running", "waiting")) "unknown" else status
}
internal data class ChatActivityData(val goal: ChatActivityGoal?, val plan: List<ChatActivityStep>, val agents: List<ChatActivityAgent>,
    val planSource: String?, val goalReported: Boolean, val planReported: Boolean, val agentsReported: Boolean, val partial: Boolean, val live: Boolean,
    val observedAtMs: Long?) {
    val hasContent get() = goal != null || plan.isNotEmpty() || agents.isNotEmpty()
    // A retained running status is historical once its owning run is gone.
    val runningAgents get() = if (live && agentsReported && agents.none { it.status == "unknown" }) agents.count { it.status == "running" } else null
    val completedSteps get() = plan.count { it.status == "completed" }
    val headline get() = goal?.objective?.takeIf { it.isNotBlank() } ?: plan.firstOrNull { it.status == "inProgress" }?.text
}

internal fun chatActivityProgress(used: Double?, budget: Double?): Float? =
    if (used != null && used.isFinite() && used >= 0 && budget != null && budget.isFinite() && budget > 0)
        (used / budget).coerceIn(0.0, 1.0).toFloat() else null

internal fun chatActivityData(inspection: JsonObject?, chat: JsonObject?): ChatActivityData? {
    val raw = inspection?.get("activity") as? JsonObject ?: return null
    fun JsonObject.text(key: String) = (this[key] as? JsonPrimitive)?.contentOrNull?.takeIf { it.isNotBlank() }
    fun JsonObject.flag(key: String) = (this[key] as? JsonPrimitive)?.booleanOrNull == true
    fun JsonObject.metric(key: String) = (this[key] as? JsonPrimitive)?.doubleOrNull?.takeIf { it.isFinite() && it >= 0 }
    fun status(value: String?, allowed: Set<String>) = value?.takeIf { it in allowed } ?: "unknown"
    val goalReported = raw.flag("goalReported")
    val planReported = raw.flag("planReported")
    val agentsReported = raw.flag("agentsReported")
    val goal = (raw["goal"] as? JsonObject)?.takeIf { goalReported }?.let {
        ChatActivityGoal(it.text("objective").orEmpty(), status(it.text("status"), setOf("active", "paused", "completed", "blocked", "budgetLimited", "usageLimited")),
            it.metric("tokenBudget"), it.metric("tokensUsed"), it.metric("timeBudgetSeconds"), it.metric("timeUsedSeconds"), it.text("source"))
    }
    val plan = if (!planReported) emptyList() else (raw["plan"] as? JsonArray).orEmpty().filterIsInstance<JsonObject>().map {
        ChatActivityStep(it.text("text").orEmpty(), status(it.text("status"), setOf("pending", "inProgress", "completed")))
    }
    val agents = if (!agentsReported) emptyList() else (raw["agents"] as? JsonArray).orEmpty().filterIsInstance<JsonObject>().mapNotNull {
        val id = it.text("id") ?: return@mapNotNull null
        ChatActivityAgent(id, it.text("name"), it.text("task"), status(it.text("status"), setOf("pending", "running", "waiting", "completed", "failed", "stopped")), it.text("model"), it.text("source"))
    }
    return ChatActivityData(goal, plan, agents, raw.text("planSource"), goalReported, planReported, agentsReported, raw.flag("partial"),
        raw.flag("live") && inspection.flag("currentRun") && chat?.flag("running") == true,
        (inspection["observedAtMs"] as? JsonPrimitive)?.longOrNull?.takeIf { it in 0..253402300799999 })
}
