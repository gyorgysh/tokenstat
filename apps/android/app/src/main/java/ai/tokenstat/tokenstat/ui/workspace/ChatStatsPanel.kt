// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.workspace

import ai.tokenstat.tokenstat.ui.logic.ChatCommandRules
import ai.tokenstat.tokenstat.AppViewModel
import ai.tokenstat.tokenstat.ui.localization.L10n
import ai.tokenstat.tokenstat.ui.theme.LocalTsColors
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.repeatOnLifecycle
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.delay
import kotlinx.coroutines.ensureActive
import kotlinx.serialization.json.*
import java.text.NumberFormat

internal fun chatCommands() = listOf(
    "/compact" to L10n.text("common.chat.command.compact"),
    "/status" to L10n.text("common.chat.command.status"),
    "/context" to L10n.text("common.chat.command.context"),
    "/usage" to L10n.text("common.chat.command.usage"),
    "/mcp" to L10n.text("common.chat.command.mcp"),
    "/tools" to L10n.text("common.chat.command.tools"),
    "/goal" to L10n.text("common.chat.activity.command_goal"),
    "/plan" to L10n.text("common.chat.activity.command_plan"),
    "/subagents" to L10n.text("common.chat.activity.command_subagents"),
    "/help" to L10n.text("common.chat.command.help"),
    "/stop" to L10n.text("common.chat.command.stop"),
)

@Composable internal fun ChatCommandMenu(draft: String, onDraft: (String) -> Unit) {
    val query = draft.trim()
    if (!query.startsWith("/") || query.any(Char::isWhitespace)) return
    val names = ChatCommandRules.matches(query)
    val matches = chatCommands().filter { it.first in names }
    if (matches.isEmpty()) return
    Surface(shape = RoundedCornerShape(12.dp), color = LocalTsColors.current.panel) {
        Column(Modifier.fillMaxWidth().heightIn(max = 220.dp).verticalScroll(rememberScrollState())) {
            matches.forEach { (command, detail) ->
                Column(Modifier.fillMaxWidth().clickable { onDraft(command) }.padding(12.dp)) {
                    Text(command, fontWeight = FontWeight.SemiBold)
                    Text(detail, style = MaterialTheme.typography.bodySmall, color = LocalTsColors.current.textSecondary)
                }
            }
        }
    }
}

@Composable internal fun ChatStatsDialog(model: AppViewModel, peer: String, chat: JsonObject, inspection: ChatInspectionSnapshot? = null, activitySection: String? = null, onDismiss: () -> Unit) {
    val account by model.state.collectAsStateWithLifecycle()
    Dialog(onDismissRequest = onDismiss, properties = DialogProperties(usePlatformDefaultWidth = false)) {
        Surface(shape = RoundedCornerShape(20.dp), color = LocalTsColors.current.background,
            modifier = Modifier.fillMaxWidth(.94f).fillMaxHeight(.86f)) {
            Column(Modifier.padding(16.dp).verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text(L10n.text(if (activitySection != null) "common.chat.activity.title" else "common.chat.stats.overview"), Modifier.weight(1f), fontWeight = FontWeight.SemiBold)
                    TextButton(onClick = onDismiss) { Text(L10n.text("common.done")) }
                }
                if (activitySection != null) {
                    val snapshot = inspection ?: rememberChatInspection(model, peer, chat, account.account)
                    ChatActivityPanel(snapshot.data, chat, activitySection, initiallyExpanded = true, loaded = snapshot.loaded)
                } else ChatStatsPanel(model, peer, chat, inspection)
                StatsDisclosure(L10n.text("common.chat.commands")) {
                    chatCommands().forEach { (command, detail) -> Text("$command · $detail", style = MaterialTheme.typography.bodySmall) }
                }
            }
        }
    }
}

internal data class ChatInspectionSnapshot(val data: JsonObject?, val loaded: Boolean)

@Composable internal fun ChatSetupDisclosure(title: String, summary: String?, owner: String?, content: @Composable ColumnScope.() -> Unit) {
    var expanded by remember(owner, title) { mutableStateOf(false) }
    StatsCard(title, expanded, { expanded = !expanded }, subtitle = summary) {
        if (expanded) Column(Modifier.fillMaxWidth().padding(bottom = 4.dp), verticalArrangement = Arrangement.spacedBy(8.dp), content = content)
    }
}

@Composable internal fun rememberChatInspection(model: AppViewModel, peer: String, chat: JsonObject?, owner: Any? = null, enabled: Boolean = true): ChatInspectionSnapshot {
    val id = chat?.str("id")
    val backend = chat?.str("backend")
    val requestedModel = chat?.str("model")
    val revision = chat?.get("runRevision") ?: chat?.get("sendRevision")
    var inspection by remember(owner, peer, id, backend, requestedModel, revision) { mutableStateOf<JsonObject?>(null) }
    var loaded by remember(owner, peer, id, backend, requestedModel, revision) { mutableStateOf(false) }
    var liveLease by remember(owner, peer, id, backend, requestedModel, revision) { mutableStateOf(false) }
    val lifecycle = LocalLifecycleOwner.current.lifecycle
    LaunchedEffect(owner, peer, id, backend, requestedModel, revision, lifecycle, enabled) {
        if (!enabled || id == null) return@LaunchedEffect
        lifecycle.repeatOnLifecycle(Lifecycle.State.RESUMED) {
            try {
                while (true) {
                    try {
                        val next = model.workspaceSection(peer, "chat.inspection", buildJsonObject { put("id", id) }) as? JsonObject
                        currentCoroutineContext().ensureActive()
                        if (next?.str("backend") == backend) { inspection = next; liveLease = true }
                        loaded = true
                    } catch (cancelled: CancellationException) { throw cancelled }
                    catch (_: Exception) { inspection = null; loaded = true; liveLease = false }
                    delay(5000)
                }
            } finally { liveLease = false }
        }
    }
    val current = if (!enabled || !liveLease) inspection?.let { JsonObject(it + ("currentRun" to JsonPrimitive(false))) } else inspection
    return ChatInspectionSnapshot(current, loaded)
}

@Composable internal fun ChatStatsPanel(model: AppViewModel, peer: String, chat: JsonObject, inspection: ChatInspectionSnapshot? = null, activitySection: String? = null) {
    val account by model.state.collectAsStateWithLifecycle()
    val snapshot = inspection ?: rememberChatInspection(model, peer, chat, account.account)
    ChatInspectionCards(snapshot.data, chat, snapshot.loaded, activitySection)
}

@Composable internal fun ChatInspectionCards(data: JsonObject?, chat: JsonObject, loaded: Boolean = true, activitySection: String? = null) {
    val id = chat.str("id")
    val backend = chat.str("backend")
    val requestedModel = chat.str("model")
    var contextOpen by remember(id, backend, requestedModel) { mutableStateOf(false) }
    var serversOpen by remember(id, backend, requestedModel) { mutableStateOf(false) }
    ChatActivityPanel(data, chat, activitySection, loaded = loaded)
    val metrics = chatContextMetrics(data)
    StatsCard(L10n.text("common.chat.stats.context"), contextOpen, { contextOpen = !contextOpen },
        subtitle = data?.str("model") ?: requestedModel ?: backend) {
        if (data == null) {
            if (!loaded) CircularProgressIndicator(Modifier.size(16.dp), strokeWidth = 2.dp)
            else Text(L10n.text("common.chat.stats.unavailable"), style = MaterialTheme.typography.bodySmall)
        } else {
            Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                Text(metrics.used?.let { L10n.text("common.chat.stats.in_context", number(it)) } ?: L10n.text("common.chat.stats.no_data"),
                    Modifier.weight(1f), style = MaterialTheme.typography.bodySmall, fontWeight = FontWeight.SemiBold)
                if (metrics.used != null && metrics.window != null) Text(NumberFormat.getPercentInstance().format(metrics.used / metrics.window),
                    style = MaterialTheme.typography.labelSmall, color = LocalTsColors.current.accent)
            }
            Text(if (metrics.window == null) L10n.text("common.chat.stats.window_unknown")
                else L10n.text("common.chat.stats.capacity", metrics.used?.let(::number) ?: "—", number(metrics.window)),
                style = MaterialTheme.typography.labelSmall, color = LocalTsColors.current.textSecondary)
            if (metrics.used != null && metrics.window != null) ContextCapacityBar(metrics)
            if (contextOpen) {
                if (metrics.prompt.isNotEmpty()) {
                    Text(L10n.text("common.chat.stats.last_prompt"), style = MaterialTheme.typography.labelMedium, fontWeight = FontWeight.SemiBold)
                    val colors = listOf(LocalTsColors.current.accent, LocalTsColors.current.accent.copy(alpha = .55f), LocalTsColors.current.warning)
                    metrics.prompt.entries.forEachIndexed { index, (name, value) -> StatRow(L10n.text(promptLabel(name)), value?.let(::number) ?: "—", colors[index]) }
                }
                if (metrics.window != null && data.str("windowSource") == "catalog") Text(L10n.text("common.chat.stats.catalog_window"),
                    style = MaterialTheme.typography.labelSmall, color = LocalTsColors.current.textSecondary)
                if (metrics.window != null && data.str("windowSource") == "previousAgent") Text(L10n.text("common.chat.stats.last_window"),
                    style = MaterialTheme.typography.labelSmall, color = LocalTsColors.current.textSecondary)
                val history = (data["contextHistory"] as? JsonArray).orEmpty().mapNotNull { chatMetric(it as? JsonObject, "tokens") }
                if (history.size > 1) StatsDisclosure(L10n.text("common.chat.stats.history")) {
                    val color = LocalTsColors.current.accent
                    Canvas(Modifier.fillMaxWidth().height(28.dp)) {
                        val peak = history.max().coerceAtLeast(1.0)
                        history.zipWithNext().forEachIndexed { index, (a, b) ->
                            drawLine(color, Offset(size.width * index / (history.size - 1), size.height * (1 - a / peak).toFloat()),
                                Offset(size.width * (index + 1) / (history.size - 1), size.height * (1 - b / peak).toFloat()), strokeWidth = 2.dp.toPx())
                        }
                    }
                    Text("${number(history.first())} → ${number(history.last())}", style = MaterialTheme.typography.labelSmall)
                }
                (data["usage"] as? JsonObject)?.let { usage ->
                    StatsDisclosure(L10n.text("common.chat.stats.conversation")) {
                        listOf("input", "output", "cacheRead", "cacheWrite").forEach { key ->
                            StatRow(L10n.text(if (key == "output") "common.chat.stats.output" else promptLabel(key)), chatMetric(usage, key)?.let(::number) ?: "—")
                        }
                        chatMetric(usage, "cost")?.takeIf { it > 0 }?.let { cost ->
                            StatRow(L10n.text("common.chat.stats.cost"), NumberFormat.getCurrencyInstance(java.util.Locale.US).format(cost))
                        }
                    }
                }
                tools(data["tools"])?.let { ToolGroups(it, L10n.text("common.chat.stats.available_tools", "${it.size}")) }
                tools(data["usedTools"])?.takeIf { it.isNotEmpty() }?.let { ToolGroups(it, L10n.text("common.chat.stats.used_tools", "${it.size}")) }
                if (data.bol("inventoryPartial")) Text(L10n.text("common.chat.stats.partial"), style = MaterialTheme.typography.labelSmall, color = LocalTsColors.current.textSecondary)
            }
        }
    }
    if (data != null) {
        val servers = (data["mcpServers"] as? JsonArray).orEmpty().filterIsInstance<JsonObject>()
        val connected = servers.filter { it.str("source") == "agent" && it.str("status") == "connected" }
        val others = servers - connected.toSet()
        StatsCard(L10n.text("common.chat.stats.mcp_servers"), serversOpen, { serversOpen = !serversOpen },
            summary = L10n.text("common.chat.stats.connection_summary", "${connected.size}", "${others.size}")) {
            if (serversOpen) {
                connected.forEach { server -> key(server.str("name"), server.str("source")) { ServerRow(server, data.bol("currentRun") && chat.bol("running")) } }
                if (others.isNotEmpty()) StatsDisclosure(L10n.text("common.chat.stats.other_count", "${others.size}")) {
                    others.forEach { server -> key(server.str("name"), server.str("source")) { ServerRow(server, false) } }
                }
                if (servers.isEmpty()) Text(L10n.text("common.chat.stats.no_servers"), style = MaterialTheme.typography.bodySmall)
            }
        }
    }
}

private fun number(value: Double) = NumberFormat.getIntegerInstance().format(value)
private fun promptLabel(key: String) = when (key) {
    "cacheRead" -> "common.chat.stats.cache_read"
    "cacheWrite" -> "common.chat.stats.cache_write"
    else -> "common.chat.stats.input"
}
private fun tools(value: JsonElement?) = (value as? JsonArray)?.mapNotNull { (it as? JsonPrimitive)?.contentOrNull }
private fun toolGroup(name: String): String = if (name.startsWith("mcp__")) name.removePrefix("mcp__").substringBefore("__") else L10n.text("common.chat.stats.agent_tools")
@Composable private fun ContextCapacityBar(metrics: ChatContextMetrics) {
    val accent = LocalTsColors.current.accent
    val colors = listOf(accent, accent.copy(alpha = .55f), LocalTsColors.current.warning)
    val background = LocalTsColors.current.border
    // Prompt categories can segment the bar only when they exactly account for
    // the reported context amount. Otherwise show the reported amount alone.
    val segments = metrics.capacitySegments()
    Canvas(Modifier.fillMaxWidth().height(4.dp).clip(RoundedCornerShape(2.dp))) {
        drawRect(background)
        var x = 0f
        segments.forEachIndexed { index, value ->
            val width = (size.width * value / metrics.window!!).toFloat().coerceIn(0f, size.width - x)
            drawRect(colors[index % colors.size], Offset(x, 0f), androidx.compose.ui.geometry.Size(width, size.height))
            x += width
        }
    }
}
@Composable private fun ToolGroups(names: List<String>, title: String) {
    StatsDisclosure(title) {
        var query by remember { mutableStateOf("") }
        OutlinedTextField(query, { query = it }, placeholder = { Text(L10n.text("common.chat.stats.search_tools")) },
            singleLine = true, textStyle = MaterialTheme.typography.bodySmall, modifier = Modifier.fillMaxWidth())
        names.filter { it.contains(query, ignoreCase = true) }.groupBy(::toolGroup).toSortedMap().forEach { (name, list) ->
            StatsDisclosure("$name · ${list.size}") {
                Column(Modifier.heightIn(max = 180.dp).verticalScroll(rememberScrollState())) {
                    list.forEach { Text(it, style = MaterialTheme.typography.labelSmall, modifier = Modifier.padding(vertical = 3.dp)) }
                }
            }
        }
    }
}
@Composable private fun ServerRow(server: JsonObject, live: Boolean) {
    val connected = server.str("source") == "agent" && server.str("status") == "connected"
    val status = serverStatus(server.str("status"), connected && live)
    val names = tools(server["tools"]).orEmpty()
    var open by remember(server.str("name"), server.str("source")) { mutableStateOf(false) }
    Column(Modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(2.dp)) {
        Row(Modifier.fillMaxWidth().heightIn(min = 36.dp).clickable(enabled = names.isNotEmpty()) { open = !open }
            .semantics(mergeDescendants = true) { stateDescription = status },
            verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
            Box(Modifier.size(6.dp).background(if (connected) LocalTsColors.current.accent else LocalTsColors.current.textSecondary, CircleShape))
            Text(server.str("name").orEmpty().removePrefix("plugin:").replace(":", " · "), Modifier.weight(1f),
                maxLines = 1, overflow = androidx.compose.ui.text.style.TextOverflow.Ellipsis, style = MaterialTheme.typography.bodySmall)
            Text(status, style = MaterialTheme.typography.labelSmall, color = LocalTsColors.current.textSecondary)
            if (names.isNotEmpty()) Text(if (open) "⌃" else "⌄", style = MaterialTheme.typography.labelSmall)
        }
        if (open) ToolGroups(names, L10n.text("common.chat.stats.available_tools", "${names.size}"))
    }
}
internal fun serverStatus(status: String?, live: Boolean) = when (status) {
    "connected" -> if (live) L10n.text("common.chat.stats.connected") else L10n.text("common.chat.stats.reported_connected")
    "configured" -> L10n.text("common.chat.stats.configured")
    "disabled" -> L10n.text("common.chat.stats.disabled")
    "starting" -> L10n.text("common.chat.stats.starting")
    "authenticationRequired" -> L10n.text("common.chat.stats.authenticationRequired")
    "failed" -> L10n.text("common.chat.stats.failed")
    "cancelled" -> L10n.text("common.chat.stats.cancelled")
    "notStarted" -> L10n.text("common.chat.stats.notStarted")
    else -> L10n.text("common.chat.stats.unknown")
}
@Composable private fun StatRow(label: String, value: String, color: Color? = null) {
    Row(Modifier.fillMaxWidth().padding(vertical = 2.dp), horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
        if (color != null) Box(Modifier.size(5.dp).background(color, CircleShape))
        Text(label, Modifier.weight(1f), style = MaterialTheme.typography.bodySmall, color = LocalTsColors.current.textSecondary)
        Text(value, style = MaterialTheme.typography.bodySmall, fontWeight = FontWeight.Medium)
    }
}
@Composable private fun StatsCard(title: String, expanded: Boolean, onToggle: () -> Unit, subtitle: String? = null,
    summary: String? = null, content: @Composable ColumnScope.() -> Unit) {
    Surface(shape = RoundedCornerShape(10.dp), color = LocalTsColors.current.panel) {
        Column(Modifier.fillMaxWidth().padding(horizontal = 10.dp, vertical = 6.dp), verticalArrangement = Arrangement.spacedBy(5.dp)) {
            Row(Modifier.fillMaxWidth().heightIn(min = 36.dp).clickable(onClick = onToggle)
                .semantics { stateDescription = L10n.text(if (expanded) "common.collapse" else "common.expand") },
                verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                Text(title, fontWeight = FontWeight.SemiBold, style = MaterialTheme.typography.bodySmall)
                if (subtitle != null) Text(subtitle, Modifier.weight(1f), maxLines = 1,
                    overflow = androidx.compose.ui.text.style.TextOverflow.Ellipsis, style = MaterialTheme.typography.labelSmall, color = LocalTsColors.current.textSecondary)
                else Spacer(Modifier.weight(1f))
                if (summary != null) Text(summary, style = MaterialTheme.typography.labelSmall, color = LocalTsColors.current.textSecondary)
                Text(if (expanded) "⌃" else "⌄", style = MaterialTheme.typography.labelSmall)
            }
            content()
        }
    }
}
@Composable private fun StatsDisclosure(title: String, content: @Composable ColumnScope.() -> Unit) {
    var expanded by remember { mutableStateOf(false) }
    Row(Modifier.fillMaxWidth().heightIn(min = 36.dp).clickable { expanded = !expanded }
        .semantics { stateDescription = L10n.text(if (expanded) "common.collapse" else "common.expand") }, verticalAlignment = Alignment.CenterVertically) {
        Text(title, Modifier.weight(1f), fontWeight = FontWeight.Medium, style = MaterialTheme.typography.bodySmall)
        Text(if (expanded) "⌃" else "⌄", style = MaterialTheme.typography.labelSmall)
    }
    if (expanded) Column(Modifier.fillMaxWidth().padding(start = 8.dp, bottom = 3.dp), verticalArrangement = Arrangement.spacedBy(3.dp), content = content)
}
