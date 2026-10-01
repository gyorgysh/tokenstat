// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.workflows

import ai.tokenstat.tokenstat.ui.localization.L10n

import ai.tokenstat.tokenstat.ui.automations.AutomationSchedule
import ai.tokenstat.tokenstat.ui.automations.BudgetFields
import ai.tokenstat.tokenstat.ui.automations.ScheduleFields
import ai.tokenstat.tokenstat.ui.automations.ScheduleKind
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.doubleOrNull
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.longOrNull
import kotlinx.serialization.json.put
import kotlinx.serialization.json.putJsonObject

internal fun JsonObject.optStr(key: String): String? =
    this[key]?.takeUnless { it is JsonNull }?.jsonPrimitive?.contentOrNull

internal fun JsonObject.optLong(key: String): Long? =
    this[key]?.takeUnless { it is JsonNull }?.jsonPrimitive?.longOrNull

internal fun JsonObject.optInt(key: String): Int? =
    this[key]?.takeUnless { it is JsonNull }?.jsonPrimitive?.intOrNull

internal fun JsonObject.optDouble(key: String): Double? =
    this[key]?.takeUnless { it is JsonNull }?.jsonPrimitive?.doubleOrNull

internal fun JsonObject.optBool(key: String): Boolean? =
    this[key]?.takeUnless { it is JsonNull }?.jsonPrimitive?.booleanOrNull

enum class WorkflowScope(val label: String) {
    GLOBAL(L10n.text("android.workflowmodels.global.a258b30f")),
    WORKSPACE(L10n.text("android.workflowmodels.this_project.d0f62545")),
    ;

    companion object {
        fun parse(raw: String?): WorkflowScope =
            entries.firstOrNull { it.name.equals(raw, ignoreCase = true) } ?: GLOBAL
    }
}

enum class WorkflowNodeKind(val label: String) {
    INPUT(L10n.text("android.workflowmodels.input.36ecb4f8")),
    AGENT(L10n.text("android.workflowmodels.agent.11b39c93")),
    AUTOMATION(L10n.text("android.workflowmodels.automation.d909750b")),
    HTTP("HTTP"),
    COMMAND(L10n.text("android.workflowmodels.command.71316697")),
    GATE(L10n.text("android.workflowmodels.gate.fa77a525")),
    CONDITION(L10n.text("android.workflowmodels.if.1e3abf61")),
    LOOP(L10n.text("android.workflowmodels.loop.f2f6a018")),
    MCP("MCP"),
    ;

    companion object {
        fun parse(raw: String?): WorkflowNodeKind =
            entries.firstOrNull { it.name.equals(raw, ignoreCase = true) } ?: INPUT
    }
}

enum class WorkflowEdgeWhen(val label: String) {
    OK(L10n.text("android.workflowmodels.on_success.97a99d2e")),
    ERROR(L10n.text("android.workflowmodels.on_error.deef8196")),
    ALWAYS("always"),
    ;

    companion object {
        fun parse(raw: String?): WorkflowEdgeWhen =
            entries.firstOrNull { it.name.equals(raw, ignoreCase = true) } ?: OK
    }
}

data class WorkflowNode(
    val id: String = "",
    val kind: WorkflowNodeKind = WorkflowNodeKind.INPUT,
    val x: Double = 0.0,
    val y: Double = 0.0,
    val title: String = "",
    val backend: String? = null,
    val model: String? = null,
    val effort: String? = null,
    val prompt: String? = null,
    val wait: String? = null,
    val waitPattern: String? = null,
    val automationID: String? = null,
    val promptOverride: String? = null,
    val method: String? = null,
    val url: String? = null,
    val headers: Map<String, String>? = null,
    val body: String? = null,
    val command: String? = null,
    val test: String? = null,
    val pattern: String? = null,
    val times: Long? = null,
    val until: String? = null,
    /// Fields the host sent that this client does not name. Never shown,
    /// never edited, written back untouched so a round trip cannot delete
    /// them.
    val extra: Map<String, JsonElement> = emptyMap(),
) {
    companion object {
        val knownKeys = setOf(
            "id", "kind", "x", "y", "title", "backend", "model", "effort",
            "prompt", "wait", "waitPattern", "automationId", "promptOverride",
            "method", "url", "headers", "body", "command", "test", "pattern",
            "times", "until",
        )

        fun parse(obj: JsonObject): WorkflowNode = WorkflowNode(
            id = obj.optStr("id") ?: "",
            kind = WorkflowNodeKind.parse(obj.optStr("kind")),
            x = obj.optDouble("x") ?: 0.0,
            y = obj.optDouble("y") ?: 0.0,
            title = obj.optStr("title") ?: "",
            backend = obj.optStr("backend"),
            model = obj.optStr("model"),
            effort = obj.optStr("effort"),
            prompt = obj.optStr("prompt"),
            wait = obj.optStr("wait"),
            waitPattern = obj.optStr("waitPattern"),
            automationID = obj.optStr("automationId"),
            promptOverride = obj.optStr("promptOverride"),
            method = obj.optStr("method"),
            url = obj.optStr("url"),
            headers = (obj["headers"] as? JsonObject)?.entries?.associate { (k, v) -> k to (v.jsonPrimitive.contentOrNull ?: "") },
            body = obj.optStr("body"),
            command = obj.optStr("command"),
            test = obj.optStr("test"),
            pattern = obj.optStr("pattern"),
            times = obj.optLong("times"),
            until = obj.optStr("until"),
            extra = obj.entries.filter { (k, _) -> k !in knownKeys }.associate { (k, v) -> k to v },
        )
    }

    val displayTitle: String get() {
        val trimmed = title.trim()
        if (trimmed.isNotEmpty()) return trimmed
        return kind.label
    }

    /// One-line caption for the outline.
    val subtitle: String get() = when (kind) {
        WorkflowNodeKind.INPUT -> L10n.text("android.workflowmodels.starting_prompt.407bec2f")
        WorkflowNodeKind.AGENT -> listOfNotNull(backend, model).filter { !it.isNullOrEmpty() }.joinToString(" · ")
        WorkflowNodeKind.AUTOMATION -> automationID ?: L10n.text("android.workflowmodels.run_automation.4c10763f")
        WorkflowNodeKind.HTTP -> {
            val verb = if (!method.isNullOrEmpty()) method else "GET"
            listOfNotNull(verb, url).filter { it.isNotEmpty() }.joinToString(" ")
        }
        WorkflowNodeKind.COMMAND -> command ?: prompt ?: L10n.text("android.workflowmodels.command.71316697")
        WorkflowNodeKind.GATE -> L10n.text("android.workflowmodels.waits_for_you.0851c4a2")
        WorkflowNodeKind.CONDITION -> if (!pattern.isNullOrEmpty()) pattern else L10n.text("android.workflowmodels.then_or_else.2318a255")
        WorkflowNodeKind.LOOP -> {
            if (!until.isNullOrEmpty()) L10n.text("android.workflowmodels.until_0.b5b51017", "${until}")
            else "${times ?: 3}×"
        }
        WorkflowNodeKind.MCP -> L10n.text("android.workflowmodels.reserved.3385ffe6")
    }

    fun toJson(): JsonObject {
        val extraCopy = extra
        return buildJsonObject {
            put("id", id)
            put("kind", kind.name.lowercase())
            put("x", x)
            put("y", y)
            put("title", title)
            backend?.let { put("backend", it) }
            model?.let { put("model", it) }
            effort?.let { put("effort", it) }
            prompt?.let { put("prompt", it) }
            wait?.let { put("wait", it) }
            waitPattern?.let { put("waitPattern", it) }
            automationID?.let { put("automationId", it) }
            promptOverride?.let { put("promptOverride", it) }
            method?.let { put("method", it) }
            url?.let { put("url", it) }
            headers?.let { map ->
                putJsonObject("headers") {
                    map.forEach { (k, v) -> put(k, v) }
                }
            }
            body?.let { put("body", it) }
            command?.let { put("command", it) }
            test?.let { put("test", it) }
            pattern?.let { put("pattern", it) }
            times?.let { put("times", it) }
            until?.let { put("until", it) }
            extraCopy.forEach { (k, v) -> put(k, v) }
        }
    }
}

data class WorkflowEdge(
    val from: String = "",
    val to: String = "",
    val whenDo: WorkflowEdgeWhen = WorkflowEdgeWhen.OK,
) {
    val id: String get() = "$from>$to:${whenDo.name.lowercase()}"

    companion object {
        fun parse(obj: JsonObject): WorkflowEdge = WorkflowEdge(
            from = obj.optStr("from") ?: "",
            to = obj.optStr("to") ?: "",
            whenDo = WorkflowEdgeWhen.parse(obj.optStr("when")),
        )
    }

    fun toJson(): JsonObject = buildJsonObject {
        put("from", from)
        put("to", to)
        put("when", whenDo.name.lowercase())
    }
}

data class WorkflowGraph(
    val id: String = "",
    val name: String = "",
    val scope: WorkflowScope = WorkflowScope.GLOBAL,
    val workspaceID: String? = null,
    val budgetSeconds: Long = 10_800,
    val schedule: AutomationSchedule = AutomationSchedule.DEFAULT,
    val enabled: Boolean = false,
    val nodes: List<WorkflowNode> = emptyList(),
    val edges: List<WorkflowEdge> = emptyList(),
    val lastRunAtMs: Long? = null,
    val nextRunAtMs: Long? = null,
    val lastRunID: String? = null,
    /// Missing on hosts before protocol 22, and on cached copies from then.
    val revision: Long = 0,
    /// Fields the host sent that this client does not name. Never shown,
    /// never edited, written back untouched so a round trip cannot delete
    /// them.
    val extra: Map<String, JsonElement> = emptyMap(),
) {
    companion object {
        val knownKeys = setOf(
            "id", "name", "scope", "workspaceId", "budgetSeconds",
            "schedule", "enabled", "nodes", "edges",
            "lastRunAtMs", "nextRunAtMs", "lastRunId", "revision",
        )

        fun parse(obj: JsonObject): WorkflowGraph = WorkflowGraph(
            id = obj.optStr("id") ?: "",
            name = obj.optStr("name") ?: "",
            scope = WorkflowScope.parse(obj.optStr("scope")),
            workspaceID = obj.optStr("workspaceId"),
            budgetSeconds = obj.optLong("budgetSeconds") ?: 10_800,
            schedule = AutomationSchedule.parse(obj["schedule"] as? JsonObject),
            enabled = obj.optBool("enabled") ?: false,
            nodes = ((obj["nodes"] as? JsonArray)?.filterIsInstance<JsonObject>() ?: emptyList()).map(WorkflowNode::parse),
            edges = ((obj["edges"] as? JsonArray)?.filterIsInstance<JsonObject>() ?: emptyList()).map(WorkflowEdge::parse),
            lastRunAtMs = obj.optLong("lastRunAtMs"),
            nextRunAtMs = obj.optLong("nextRunAtMs"),
            lastRunID = obj.optStr("lastRunId"),
            revision = obj.optLong("revision") ?: 0,
            extra = obj.entries.filter { (k, _) -> k !in knownKeys }.associate { (k, v) -> k to v },
        )

        /// Empty graph with a start node. The person still has to save it.
        fun blank(name: String = L10n.text("android.workflowmodels.untitled.f59ab8d1"), workspaceID: String? = null): WorkflowGraph =
            WorkflowGraph(
                name = name,
                scope = WorkflowScope.WORKSPACE,
                workspaceID = workspaceID,
                nodes = listOf(WorkflowNode(id = "in", kind = WorkflowNodeKind.INPUT, x = 80.0, y = 120.0, title = L10n.text("common.start"))),
            )
    }

    /// Place nodes top to bottom when every position is still the origin.
    /// Design-from-prompt often omits x/y. Layers go down, siblings share
    /// a row. Port of `WorkflowGraph.layoutIfNeeded`.
    fun layoutIfNeeded(): WorkflowGraph {
        if (nodes.isEmpty()) return this
        if (nodes.any { it.x != 0.0 || it.y != 0.0 }) return this
        val incoming = mutableMapOf<String, Int>()
        val outgoing = mutableMapOf<String, MutableList<String>>()
        nodes.forEach { incoming[it.id] = 0 }
        edges.forEach { edge ->
            incoming[edge.to] = (incoming[edge.to] ?: 0) + 1
            outgoing.getOrPut(edge.from) { mutableListOf() }.add(edge.to)
        }
        val layer = mutableMapOf<String, Int>()
        var queue = nodes.filter { (incoming[it.id] ?: 0) == 0 }.map { it.id }.ifEmpty { nodes.map { it.id } }
        queue.forEach { layer[it] = 0 }
        val seen = queue.toMutableSet()
        var i = 0
        while (i < queue.size) {
            val id = queue[i++]
            val current = layer[id] ?: 0
            outgoing[id].orEmpty().forEach { next ->
                layer[next] = maxOf(layer[next] ?: 0, current + 1)
                if (seen.add(next)) queue = queue + next
            }
        }
        val siblingInLayer = mutableMapOf<Int, Int>()
        val placed = nodes.map { node ->
            val depth = layer[node.id] ?: 0
            val sibling = siblingInLayer.getOrDefault(depth, 0)
            siblingInLayer[depth] = sibling + 1
            node.copy(x = 80.0 + sibling * 252.0, y = 80.0 + depth * 160.0)
        }
        return copy(nodes = placed)
    }

    fun toJson(): JsonObject {
        val extraCopy = extra
        return buildJsonObject {
            put("id", id)
            put("name", name)
            put("scope", scope.name.lowercase())
            workspaceID?.let { put("workspaceId", it) }
            put("budgetSeconds", budgetSeconds)
            put("schedule", schedule.toJson())
            put("enabled", enabled)
            put("nodes", JsonArray(nodes.map { it.toJson() }))
            put("edges", JsonArray(edges.map { it.toJson() }))
            lastRunAtMs?.let { put("lastRunAtMs", it) }
            nextRunAtMs?.let { put("nextRunAtMs", it) }
            lastRunID?.let { put("lastRunId", it) }
            put("revision", revision)
            extraCopy.forEach { (k, v) -> put(k, v) }
        }
    }
}

/// Host graph limits and the messages a person sees before Save. Keep the
/// numbers and the legal shapes in step with `tokenstat-host::workflows`.
/// Port of `WorkflowGraphRules`.
object WorkflowGraphRules {
    const val MAX_NODES = 64
    const val MAX_EDGES = 128
    const val MAX_LOOP_TIMES = 20L
    const val MAX_PATH_ID = 128

    /// Kinds a person can add. MCP is reserved on the host.
    val authorableKinds = listOf(
        WorkflowNodeKind.INPUT, WorkflowNodeKind.AGENT, WorkflowNodeKind.AUTOMATION,
        WorkflowNodeKind.HTTP, WorkflowNodeKind.COMMAND, WorkflowNodeKind.GATE,
        WorkflowNodeKind.CONDITION, WorkflowNodeKind.LOOP,
    )

    /// How an outgoing connection is named on the step list and detail.
    /// If uses Then/Else. Loop uses Body for the repeated work and After
    /// last pass for the way out. Other steps use Then, On error, Always.
    fun outgoingRole(kind: WorkflowNodeKind, whenDo: WorkflowEdgeWhen): String = when {
        kind == WorkflowNodeKind.CONDITION && whenDo == WorkflowEdgeWhen.OK -> L10n.text("android.workflowmodels.then.0597f441")
        kind == WorkflowNodeKind.CONDITION && whenDo == WorkflowEdgeWhen.ERROR -> L10n.text("android.workflowmodels.else.9c77d72e")
        kind == WorkflowNodeKind.LOOP && whenDo == WorkflowEdgeWhen.OK -> L10n.text("android.workflowmodels.body.6ccaa641")
        kind == WorkflowNodeKind.LOOP && whenDo == WorkflowEdgeWhen.ALWAYS -> L10n.text("android.workflowmodels.after_last_pass.c89d89b0")
        whenDo == WorkflowEdgeWhen.OK -> L10n.text("android.workflowmodels.then.0597f441")
        whenDo == WorkflowEdgeWhen.ERROR -> L10n.text("android.workflowmodels.on_error.817fc01c")
        else -> L10n.text("android.workflowmodels.always.de9f057a")
    }

    fun connectionCaption(kind: WorkflowNodeKind): String = when (kind) {
        WorkflowNodeKind.CONDITION -> L10n.text("android.workflowmodels.then_is_success_else_is_error_the_test_rea.8b4c9b63")
        WorkflowNodeKind.LOOP -> L10n.text("android.workflowmodels.body_is_the_repeated_work_after_last_pass.121c684e")
        WorkflowNodeKind.GATE -> L10n.text("android.workflowmodels.the_run_pauses_here_continue_or_stop_from.793fcc9e")
        WorkflowNodeKind.INPUT -> L10n.text("android.workflowmodels.the_starting_prompt_fills_input_when_you_p.25eaf312")
        else -> L10n.text("android.workflowmodels.then_is_on_success_on_error_is_the_failure.bab7fe1d")
    }

    fun suggestedWhen(kind: WorkflowNodeKind, outgoing: List<WorkflowEdge>): WorkflowEdgeWhen {
        val used = outgoing.map { it.whenDo }.toSet()
        if (kind == WorkflowNodeKind.LOOP) {
            if (WorkflowEdgeWhen.OK !in used) return WorkflowEdgeWhen.OK
            return WorkflowEdgeWhen.ALWAYS
        }
        if (WorkflowEdgeWhen.OK !in used) return WorkflowEdgeWhen.OK
        if (WorkflowEdgeWhen.ERROR !in used) return WorkflowEdgeWhen.ERROR
        return WorkflowEdgeWhen.ALWAYS
    }

    fun additionIssue(kind: WorkflowNodeKind, nodeCount: Int): String? {
        if (kind == WorkflowNodeKind.MCP) return L10n.text("android.workflowmodels.mcp_steps_are_not_available_yet.d3e1bfc3")
        if (nodeCount >= MAX_NODES) return L10n.text("android.workflowmodels.a_workflow_may_have_at_most_0_steps.e533210f", "${MAX_NODES}")
        return null
    }

    fun connectionIssue(from: String, to: String, nodes: List<WorkflowNode>, edges: List<WorkflowEdge>): String? {
        if (from == to) return L10n.text("android.workflowmodels.a_step_cannot_connect_to_itself.315c4446")
        val ids = nodes.map { it.id }.toSet()
        if (from !in ids) return L10n.text("android.workflowmodels.a_connection_starts_from_a_missing_step.f423e421")
        if (to !in ids) return L10n.text("android.workflowmodels.a_connection_points_to_a_missing_step.611cba65")
        val replacing = edges.any { it.from == from && it.to == to }
        if (!replacing && edges.size >= MAX_EDGES) return L10n.text("android.workflowmodels.a_workflow_may_have_at_most_0_connections.32d67dc9", "${MAX_EDGES}")
        return null
    }

    fun stepsIssue(nodes: List<WorkflowNode>, edges: List<WorkflowEdge>): String? {
        if (nodes.size > MAX_NODES) return L10n.text("android.workflowmodels.a_workflow_may_have_at_most_0_steps.e533210f", "${MAX_NODES}")
        if (edges.size > MAX_EDGES) return L10n.text("android.workflowmodels.a_workflow_may_have_at_most_0_connections.32d67dc9", "${MAX_EDGES}")
        val ids = mutableSetOf<String>()
        nodes.forEach { node ->
            val trimmed = node.id.trim()
            if (trimmed.isEmpty()) return L10n.text("android.workflowmodels.every_step_needs_an_id.8d69a4a0")
            if (!isPathSafeID(node.id)) {
                if (node.id.toByteArray().size > MAX_PATH_ID * 4 || node.id.contains('\u0000')) {
                    return L10n.text("android.workflowmodels.step_id_0_cannot_be_used.cb82549b", "${node.id}")
                }
            }
            if (!ids.add(node.id)) return L10n.text("android.workflowmodels.two_steps_share_the_id_0.7df9bf9b", "${node.id}")
            nodeIssue(node)?.let { return it }
        }
        edges.forEach { edge ->
            if (edge.from !in ids) return L10n.text("android.workflowmodels.a_connection_starts_from_a_missing_step.f423e421")
            if (edge.to !in ids) return L10n.text("android.workflowmodels.a_connection_points_to_a_missing_step.611cba65")
            if (edge.from == edge.to) return L10n.text("android.workflowmodels.a_step_cannot_connect_to_itself.315c4446")
        }
        if (hasIllegalCycle(nodes, edges)) return L10n.text("android.workflowmodels.this_graph_loops_without_a_loop_step.92bd3735")
        nodes.filter { it.kind == WorkflowNodeKind.LOOP }.forEach { node ->
            val times = node.times ?: 3
            if (times !in 1..MAX_LOOP_TIMES) return L10n.text("android.workflowmodels.a_loop_may_repeat_at_most_0_times.5ac3bdc7", "${MAX_LOOP_TIMES}")
            if (edges.none { it.from == node.id && it.whenDo == WorkflowEdgeWhen.OK }) {
                return L10n.text("android.workflowmodels.loop_0_needs_a_body_connection.0195107c", "${node.displayTitle}")
            }
        }
        return null
    }

    fun nodeIssue(node: WorkflowNode): String? = when (node.kind) {
        WorkflowNodeKind.INPUT, WorkflowNodeKind.GATE, WorkflowNodeKind.LOOP -> null
        WorkflowNodeKind.CONDITION -> when (node.test ?: "contains") {
            "contains", "equals", "matches" -> null
            else -> L10n.text("android.workflowmodels.if_only_supports_contains_equals_or_matche.3a5207ff")
        }
        WorkflowNodeKind.MCP -> L10n.text("android.workflowmodels.mcp_steps_are_not_available_yet.d3e1bfc3")
        WorkflowNodeKind.AGENT ->
            if ((node.backend ?: "").isEmpty()) L10n.text("android.workflowmodels.an_agent_step_needs_an_agent.4f1e96ec") else null
        WorkflowNodeKind.AUTOMATION ->
            if ((node.automationID ?: "").isEmpty()) L10n.text("android.workflowmodels.an_automation_step_needs_an_automation.5eb2b325") else null
        WorkflowNodeKind.HTTP -> {
            val url = node.url ?: ""
            if (url.isEmpty()) L10n.text("android.workflowmodels.an_http_step_needs_a_url.78b1c371")
            else if (!url.startsWith("http://") && !url.startsWith("https://")) L10n.text("android.workflowmodels.an_http_url_must_start_with_http_or_https.f66df6ab")
            else null
        }
        WorkflowNodeKind.COMMAND -> {
            val text = node.command ?: node.prompt ?: ""
            if (text.isEmpty()) L10n.text("android.workflowmodels.a_command_step_needs_a_command.5d665b7c") else null
        }
    }

    fun isPathSafeID(id: String): Boolean {
        val bytes = id.toByteArray()
        return bytes.isNotEmpty() && bytes.size <= MAX_PATH_ID && bytes.all { byte ->
            val b = byte.toInt() and 0xFF
            (b in 48..57) || (b in 65..90) || (b in 97..122) || b == 45 || b == 95
        }
    }

    fun nextNodeID(nodes: List<WorkflowNode>): String {
        val existing = nodes.map { it.id }.toSet()
        var n = nodes.size + 1
        var id = "n$n"
        while (id in existing) {
            n += 1
            id = "n$n"
        }
        return id
    }

    fun makeNode(kind: WorkflowNodeKind, id: String, backend: String? = null, automationID: String? = null): WorkflowNode {
        var node = WorkflowNode(id = id, kind = kind, title = kind.label, backend = backend, automationID = automationID)
        when (kind) {
            WorkflowNodeKind.AGENT -> node = node.copy(prompt = "{{input}}", wait = "exit")
            WorkflowNodeKind.HTTP -> node = node.copy(method = "GET", url = "https://")
            WorkflowNodeKind.COMMAND -> node = node.copy(command = "echo ok")
            WorkflowNodeKind.CONDITION -> node = node.copy(test = "contains")
            WorkflowNodeKind.LOOP -> node = node.copy(times = 3)
            else -> Unit
        }
        return node
    }

    /// Cycles are allowed only when every cycle passes through a loop node.
    /// Edges that touch a loop are dropped from the walk, matching the host.
    fun hasIllegalCycle(nodes: List<WorkflowNode>, edges: List<WorkflowEdge>): Boolean {
        val loops = nodes.filter { it.kind == WorkflowNodeKind.LOOP }.map { it.id }.toSet()
        val adj = mutableMapOf<String, MutableList<String>>()
        edges.forEach { edge ->
            if (edge.from in loops || edge.to in loops) return@forEach
            adj.getOrPut(edge.from) { mutableListOf() }.add(edge.to)
        }
        val stack = mutableSetOf<String>()
        val seen = mutableSetOf<String>()
        fun visit(id: String): Boolean {
            if (!stack.add(id)) return true
            if (seen.add(id)) {
                adj[id].orEmpty().forEach { child ->
                    if (visit(child)) return true
                }
            }
            stack.remove(id)
            return false
        }
        return nodes.any { visit(it.id) }
    }
}

/// Graph metadata a phone can author. Port of `WorkflowEditorDraft`.
/// Recipes fill nodes and edges locally; a blank draft is a Start card.
data class WorkflowEditorDraft(
    val name: String = "",
    val workspaceID: String = "",
    val starterID: String = BLANK_STARTER_ID,
    val enabled: Boolean = true,
    val nodes: List<WorkflowNode> = blankNodes(),
    val edges: List<WorkflowEdge> = emptyList(),
    val schedule: ScheduleFields = ScheduleFields(),
    val budget: BudgetFields = BudgetFields(),
    /// Graph-level fields the host sent that this client does not name.
    /// Saved with the draft so a round trip through this device cannot
    /// delete them.
    val graphExtra: Map<String, JsonElement> = emptyMap(),
) {
    companion object {
        const val BLANK_STARTER_ID = "blank"
        const val DESIGNED_STARTER_ID = "designed"

        fun blankNodes(): List<WorkflowNode> =
            listOf(WorkflowNode(id = "in", kind = WorkflowNodeKind.INPUT, x = 80.0, y = 120.0, title = L10n.text("common.start")))

        fun blank(workspaceID: String, budgetSeconds: Long = 10_800): WorkflowEditorDraft =
            WorkflowEditorDraft(workspaceID = workspaceID, budget = BudgetFields.load(budgetSeconds))

        fun fromGraph(graph: WorkflowGraph): WorkflowEditorDraft = WorkflowEditorDraft(
            name = graph.name,
            workspaceID = graph.workspaceID ?: "",
            starterID = "",
            enabled = graph.enabled,
            nodes = graph.nodes,
            edges = graph.edges,
            schedule = ScheduleFields.load(graph.schedule),
            budget = BudgetFields.load(graph.budgetSeconds),
            graphExtra = graph.extra,
        )
    }

    val isBlankStarter: Boolean get() = starterID == BLANK_STARTER_ID

    fun applyBlank(): WorkflowEditorDraft = copy(
        starterID = BLANK_STARTER_ID,
        nodes = blankNodes(),
        edges = emptyList(),
        graphExtra = emptyMap(),
    )

    fun applyRecipe(recipe: WorkflowRecipe): WorkflowEditorDraft {
        val trimmed = name.trim()
        return copy(
            starterID = recipe.id,
            nodes = recipe.nodes,
            edges = recipe.edges,
            graphExtra = emptyMap(),
            name = if (trimmed.isEmpty() || trimmed == "Untitled") recipe.name else name,
        )
    }

    fun applyDesign(graph: WorkflowGraph): WorkflowEditorDraft = copy(
        starterID = DESIGNED_STARTER_ID,
        nodes = graph.nodes,
        edges = graph.edges,
        graphExtra = graph.extra,
    )

    val validation: String? get() {
        if (name.trim().isEmpty()) return L10n.text("android.workflowmodels.give_this_workflow_a_name.146078f2")
        if (name.toByteArray().size > 4096) return L10n.text("android.workflowmodels.shorten_the_name_to_4_kib_or_less.5579d8cf")
        if (workspaceID.trim().isEmpty()) return L10n.text("android.workflowmodels.choose_a_folder_for_this_workflow.e6f199bc")
        if (nodes.isEmpty()) return L10n.text("android.workflowmodels.a_workflow_needs_a_start_step.92d85360")
        WorkflowGraphRules.stepsIssue(nodes, edges)?.let { return it }
        schedule.validation?.let { return it }
        budget.validation?.let { return it }
        return null
    }

    fun matches(graph: WorkflowGraph): Boolean =
        name.trim() == graph.name &&
            workspaceID == (graph.workspaceID ?: "") &&
            schedule.builtSchedule == graph.schedule &&
            budget.budgetSeconds == graph.budgetSeconds &&
            (if (schedule.builtSchedule.repeats) enabled else false) == graph.enabled &&
            nodes == graph.nodes &&
            edges == graph.edges &&
            graphExtra == graph.extra

    fun makeGraph(id: String, lastRunAtMs: Long? = null, lastRunID: String? = null): WorkflowGraph {
        val budgetSeconds = budget.budgetSeconds
            ?: throw IllegalArgumentException(validation ?: L10n.text("android.workflowmodels.check_this_workflow_s_settings.e97a5e74"))
        if (validation != null) throw IllegalArgumentException(validation)
        return WorkflowGraph(
            id = id,
            name = name.trim(),
            scope = WorkflowScope.WORKSPACE,
            workspaceID = workspaceID,
            budgetSeconds = budgetSeconds,
            schedule = schedule.builtSchedule,
            enabled = if (schedule.builtSchedule.repeats) enabled else false,
            nodes = nodes,
            edges = edges,
            lastRunAtMs = lastRunAtMs,
            lastRunID = lastRunID,
            extra = graphExtra,
        ).layoutIfNeeded()
    }
}

/// Cheap/low defaults used by Design and by the example recipes.
/// Port of `WorkflowModelPick`.
object WorkflowModelPick {
    val cheapMarkers = listOf("haiku", "nano", "mini", "flash", "fast", "lite", "small")

    fun cheapestModel(backend: String, models: List<String>): String? {
        if (models.isEmpty()) return null
        cheapMarkers.forEach { marker ->
            models.firstOrNull { it.lowercase().contains(marker) }?.let { return it }
        }
        if (backend == "claude") return models.last()
        return models.first()
    }

    fun lowestEffort(efforts: List<String>): String? {
        listOf("low", "minimal").forEach { prefer ->
            efforts.firstOrNull { it.equals(prefer, ignoreCase = true) }?.let { return it }
        }
        return efforts.firstOrNull()
    }

    fun highestEffort(efforts: List<String>): String? {
        listOf("high", "max", "xhigh").forEach { prefer ->
            efforts.firstOrNull { it.equals(prefer, ignoreCase = true) }?.let { return it }
        }
        return efforts.lastOrNull()
    }

    fun midModel(models: List<String>, excluding: String?): String? {
        val review = listOf("opus", "fable")
        models.firstOrNull { id ->
            if (id == excluding) return@firstOrNull false
            val low = id.lowercase()
            if (cheapMarkers.any { low.contains(it) }) return@firstOrNull false
            if (review.any { low.contains(it) }) return@firstOrNull false
            true
        }?.let { return it }
        return models.firstOrNull { it != excluding }
    }

    fun reviewModel(models: List<String>): String? {
        listOf("opus", "fable").forEach { marker ->
            models.firstOrNull { it.lowercase().contains(marker) }?.let { return it }
        }
        return null
    }
}

/// One example pipeline. Port of `WorkflowRecipe`.
data class WorkflowRecipe(
    val id: String,
    val name: String,
    val label: String,
    val prompt: String,
    val nodes: List<WorkflowNode>,
    val edges: List<WorkflowEdge>,
)

/// Example pipelines built from the advertised backends. Port of
/// `WorkflowRecipes` (phone path: every advertised agent counts).
object WorkflowRecipes {
    fun designAgents(backends: List<AgentBackend>): List<AgentBackend> =
        backends.filter { it.id != "sh" }

    fun defaultBackend(backends: List<AgentBackend>): String {
        val agents = designAgents(backends)
        agents.firstOrNull {
            WorkflowModelPick.cheapestModel(it.id, it.models) != null ||
                WorkflowModelPick.lowestEffort(it.efforts) != null
        }?.let { return it.id }
        return agents.firstOrNull()?.id ?: ""
    }

    fun recipes(backends: List<AgentBackend>): List<WorkflowRecipe> {
        val agents = designAgents(backends)
        if (agents.isEmpty()) return emptyList()
        val out = mutableListOf<WorkflowRecipe>()
        pipeline(agents, "full", short = false)?.let { out.add(it) }
        if (agents.size >= 2) {
            pipeline(agents, "short", short = true)?.let {
                if (it.label != out.firstOrNull()?.label) out.add(it)
            }
        }
        return out
    }

    private data class Stage(
        val id: String,
        val verb: String,
        val title: String,
        val backend: AgentBackend,
        val model: String?,
        val effort: String?,
        val prompt: String,
    )

    private data class AgentPick(val backend: AgentBackend, val model: String?, val effort: String?)

    private fun priorToken(previous: String?): String =
        if (previous == null) "{{input}}" else "{{$previous.output}}"

    private fun distinct(pick: AgentPick, previous: Stage?): Boolean {
        if (previous == null) return true
        return pick.backend.id != previous.backend.id || pick.model != previous.model || pick.effort != previous.effort
    }

    private fun pickRefine(agents: List<AgentBackend>): AgentPick? {
        val cheap = agents.firstOrNull { agent ->
            val model = WorkflowModelPick.cheapestModel(agent.id, agent.models) ?: return@firstOrNull false
            WorkflowModelPick.cheapMarkers.any { model.lowercase().contains(it) }
        } ?: agents.firstOrNull() ?: return null
        return AgentPick(
            cheap,
            WorkflowModelPick.cheapestModel(cheap.id, cheap.models),
            WorkflowModelPick.lowestEffort(cheap.efforts),
        )
    }

    private fun pickPlan(agents: List<AgentBackend>, refine: AgentPick): AgentPick? {
        val preferred = agents.firstOrNull { it.id == "grok" }
            ?: agents.firstOrNull { WorkflowModelPick.highestEffort(it.efforts) != null && it.id != refine.backend.id }
            ?: refine.backend
        val model = if (preferred.id == refine.backend.id) {
            WorkflowModelPick.midModel(preferred.models, refine.model) ?: refine.model
        } else {
            preferred.models.firstOrNull()
        }
        return AgentPick(preferred, model, WorkflowModelPick.highestEffort(preferred.efforts))
    }

    private fun pickBuild(agents: List<AgentBackend>, used: List<String>): AgentPick? {
        val order = listOf("opencode", "opencode2", "cursor", "codex", "agy")
        val agent = order.firstNotNullOfOrNull { id -> agents.firstOrNull { it.id == id } }
            ?: agents.firstOrNull { it.id !in used }
            ?: return null
        if (agent.id in used) return null
        val mid = WorkflowModelPick.midModel(agent.models, null)
        val high = WorkflowModelPick.highestEffort(agent.efforts)
        val effort = agent.efforts.firstOrNull { it.equals("medium", ignoreCase = true) } ?: high
        return AgentPick(agent, mid ?: agent.models.firstOrNull(), effort)
    }

    private fun pickReview(agents: List<AgentBackend>): AgentPick? {
        val withOpus = agents.firstOrNull { WorkflowModelPick.reviewModel(it.models) != null } ?: return null
        return AgentPick(
            withOpus,
            WorkflowModelPick.reviewModel(withOpus.models),
            WorkflowModelPick.highestEffort(withOpus.efforts),
        )
    }

    private fun pipeline(agents: List<AgentBackend>, id: String, short: Boolean): WorkflowRecipe? {
        val refinePick = pickRefine(agents) ?: return null
        val planPick = pickPlan(agents, refinePick)
        val buildPick = pickBuild(agents, listOf(refinePick.backend.id, planPick?.backend?.id).filterNotNull())
        val reviewPick = pickReview(agents)
        val stages = mutableListOf<Stage>()
        if (!short) {
            stages.add(Stage("refine", L10n.text("android.workflowmodels.refine.1e7f34ee"), L10n.text("android.workflowmodels.refine_prompt.cbab4873"), refinePick.backend, refinePick.model, refinePick.effort,
                L10n.text("android.workflowmodels.rewrite_this_starting_prompt_so_it_is_clea.6b67cfe2")))
        }
        if (planPick != null && distinct(planPick, stages.lastOrNull())) {
            stages.add(Stage("plan", L10n.text("android.workflowmodels.plan.fa8ed0bd"), L10n.text("android.workflowmodels.plan.fa8ed0bd"), planPick.backend, planPick.model, planPick.effort,
                L10n.text("android.workflowmodels.write_a_short_plan_for_this_work_0.d30fbc18", "${priorToken(stages.lastOrNull()?.id)}")))
        }
        if (buildPick != null) {
            stages.add(Stage("build", L10n.text("android.workflowmodels.build.bdd254b6"), L10n.text("android.workflowmodels.build.bdd254b6"), buildPick.backend, buildPick.model, buildPick.effort,
                L10n.text("android.workflowmodels.implement_the_plan_0.1bcd9971", "${priorToken(stages.lastOrNull()?.id)}")))
        }
        if (!short && reviewPick != null && distinct(reviewPick, stages.lastOrNull())) {
            stages.add(Stage("review", L10n.text("android.workflowmodels.review.aff0766a"), L10n.text("android.workflowmodels.review.aff0766a"), reviewPick.backend, reviewPick.model, reviewPick.effort,
                L10n.text("android.workflowmodels.review_the_work_list_issues_first_0.6279f6f0", "${priorToken(stages.lastOrNull()?.id)}")))
        }
        if (stages.isEmpty()) return null
        val nodes = mutableListOf(WorkflowNode(id = "in", kind = WorkflowNodeKind.INPUT, title = L10n.text("common.start")))
        val edges = mutableListOf<WorkflowEdge>()
        var previous = "in"
        stages.forEach { item ->
            nodes.add(WorkflowNode(id = item.id, kind = WorkflowNodeKind.AGENT, title = item.title,
                backend = item.backend.id, model = item.model, effort = item.effort, prompt = item.prompt, wait = "exit"))
            edges.add(WorkflowEdge(previous, item.id, WorkflowEdgeWhen.OK))
            previous = item.id
        }
        nodes.add(WorkflowNode(id = "done", kind = WorkflowNodeKind.COMMAND, title = L10n.text("common.done"),
            command = "afplay /System/Library/Sounds/Glass.aiff"))
        edges.add(WorkflowEdge(previous, "done", WorkflowEdgeWhen.OK))
        val label = (listOf(L10n.text("common.start")) + stages.map {
            (listOf(it.verb, it.backend.label) + listOfNotNull(it.model, it.effort)).joinToString(" ")
        } + L10n.text("common.done")).joinToString(" → ")
        val prompt = L10n.text("android.workflowmodels.starting_prompt_then_0_then_play_the_syste.5a7a8b91", "${stages.map { part ->
            (listOf(part.verb.lowercase(), "on", part.backend.label) +
                listOfNotNull(part.model) +
                listOfNotNull(part.effort?.let { "($it)" })).joinToString(" ")
        }.joinToString(L10n.text("android.workflowmodels.then.6b6fbf17"))}")
        return WorkflowRecipe(id, if (short) L10n.text("android.workflowmodels.plan_then_build.9b157ea7") else L10n.text("android.workflowmodels.plan_build_review.f00c084c"), label, prompt, nodes, edges)
    }
}

data class AgentBackend(val id: String = "", val label: String = "", val models: List<String> = emptyList(), val efforts: List<String> = emptyList()) {
    companion object {
        fun parse(obj: JsonObject): AgentBackend = AgentBackend(
            id = obj.optStr("id") ?: "",
            label = obj.optStr("label") ?: "",
            models = (obj["models"] as? JsonArray)?.mapNotNull { it.jsonPrimitive.contentOrNull } ?: emptyList(),
            efforts = (obj["efforts"] as? JsonArray)?.mapNotNull { it.jsonPrimitive.contentOrNull } ?: emptyList(),
        )
    }
}

data class WorkflowStep(
    val nodeID: String = "",
    val kind: String = "",
    val title: String = "",
    val status: String = "",
    val output: String = "",
    val startedAtMs: Long = 0,
    val endedAtMs: Long? = null,
) {
    companion object {
        fun parse(obj: JsonObject): WorkflowStep = WorkflowStep(
            nodeID = obj.optStr("nodeId") ?: "",
            kind = obj.optStr("kind") ?: "",
            title = obj.optStr("title") ?: "",
            status = obj.optStr("status") ?: "",
            output = obj.optStr("output") ?: "",
            startedAtMs = obj.optLong("startedAtMs") ?: 0,
            endedAtMs = obj.optLong("endedAtMs"),
        )
    }
}

data class WorkflowRunRecord(
    val id: String = "",
    val workflowID: String = "",
    val name: String = "",
    val workspaceID: String = "",
    val input: String = "",
    val status: String = "",
    val startedAtMs: Long = 0,
    val endedAtMs: Long? = null,
    val currentNodeID: String? = null,
    val steps: List<WorkflowStep> = emptyList(),
    val budgetSeconds: Long = 0,
) {
    companion object {
        fun label(status: String): String = when (status) {
            "queued" -> L10n.text("common.queued")
            "running" -> L10n.text("common.working")
            "waiting" -> L10n.text("android.workflowmodels.needs_attention.c1ebc781")
            "ok" -> L10n.text("common.done")
            "stopped" -> L10n.text("android.workflowmodels.stopped.1a4f630a")
            "error" -> L10n.text("common.failed")
            "interrupted" -> L10n.text("android.workflowmodels.interrupted_by_restart.012812fe")
            else -> status
        }

        fun parse(obj: JsonObject): WorkflowRunRecord = WorkflowRunRecord(
            id = obj.optStr("id") ?: "",
            workflowID = obj.optStr("workflowId") ?: "",
            name = obj.optStr("name") ?: "",
            workspaceID = obj.optStr("workspaceId") ?: "",
            input = obj.optStr("input") ?: "",
            status = obj.optStr("status") ?: "",
            startedAtMs = obj.optLong("startedAtMs") ?: 0,
            endedAtMs = obj.optLong("endedAtMs"),
            currentNodeID = obj.optStr("currentNodeId"),
            steps = ((obj["steps"] as? JsonArray)?.filterIsInstance<JsonObject>() ?: emptyList()).map(WorkflowStep::parse),
            budgetSeconds = obj.optLong("budgetSeconds") ?: 0,
        )
    }

    val isLive: Boolean get() = status == "running" || status == "waiting"
    val isWaiting: Boolean get() = status == "waiting"
    val endedLabel: String get() = label(status)
}

data class WorkflowDesignResult(val workflow: WorkflowGraph, val transcript: String) {
    companion object {
        fun parse(obj: JsonObject): WorkflowDesignResult = WorkflowDesignResult(
            workflow = WorkflowGraph.parse((obj["workflow"] as? JsonObject) ?: JsonObject(emptyMap())),
            transcript = obj.optStr("transcript") ?: "",
        )
    }
}

/// "3 workflows · 1 running", the workflows library summary.
fun workflowListSummary(total: Int, running: Int): String = L10n.text("android.workflowmodels.0_workflows_1_running.3c6bc0ea", "${total}", "${running}")

/// Library search covers the graph name, like the Apple client.
fun graphMatchesQuery(graph: WorkflowGraph, query: String): Boolean {
    val q = query.trim()
    if (q.isEmpty()) return true
    return graph.name.contains(q, ignoreCase = true)
}

/// The run the detail leads with: the graph's recorded last run, else the
/// first retained run. Port of `ClientWorkflowSession.lastRun(for:)`.
fun lastWorkflowRun(runs: List<WorkflowRunRecord>, graph: WorkflowGraph): WorkflowRunRecord? {
    val id = graph.lastRunID
    if (id != null) runs.firstOrNull { it.id == id }?.let { return it }
    return runs.firstOrNull { it.workflowID == graph.id }
}
