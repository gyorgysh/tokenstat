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
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.LocalLifecycleOwner
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

@Composable internal fun ChatStatsDialog(model: AppViewModel, peer: String, chat: JsonObject, onDismiss: () -> Unit) {
    Dialog(onDismissRequest = onDismiss, properties = DialogProperties(usePlatformDefaultWidth = false)) {
        Surface(shape = RoundedCornerShape(20.dp), color = LocalTsColors.current.background,
            modifier = Modifier.fillMaxWidth(.94f).fillMaxHeight(.86f)) {
            Column(Modifier.padding(16.dp).verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text(L10n.text("common.chat.stats.overview"), Modifier.weight(1f), fontWeight = FontWeight.SemiBold)
                    TextButton(onClick = onDismiss) { Text(L10n.text("common.done")) }
                }
                ChatStatsPanel(model, peer, chat)
                Text(L10n.text("common.chat.commands"), fontWeight = FontWeight.SemiBold)
                chatCommands().forEach { (command, detail) -> Text("$command · $detail", style = MaterialTheme.typography.bodySmall) }
                Text(L10n.text("common.chat.command.unsupported"), style = MaterialTheme.typography.bodySmall)
            }
        }
    }
}

@Composable internal fun ChatStatsPanel(model: AppViewModel, peer: String, chat: JsonObject) {
    val id = chat.str("id") ?: return
    val backend = chat.str("backend")
    val requestedModel = chat.str("model")
    var inspection by remember(peer, id, backend, requestedModel) { mutableStateOf<JsonObject?>(null) }
    var loaded by remember(peer, id, backend, requestedModel) { mutableStateOf(false) }
    val lifecycle = LocalLifecycleOwner.current.lifecycle
    LaunchedEffect(peer, id, backend, requestedModel, lifecycle) {
        lifecycle.repeatOnLifecycle(Lifecycle.State.STARTED) {
            while (true) {
                try {
                    val next = model.workspaceSection(peer, "chat.inspection", buildJsonObject { put("id", id) }) as? JsonObject
                    currentCoroutineContext().ensureActive()
                    if (next?.str("backend") == backend) inspection = next
                    loaded = true
                } catch (cancelled: CancellationException) { throw cancelled }
                catch (_: Exception) { inspection = null; loaded = true }
                delay(5000)
            }
        }
    }
    val data = inspection
    StatsCard(L10n.text("common.chat.stats")) {
        if (data == null) {
            if (!loaded) CircularProgressIndicator(Modifier.size(20.dp))
            else Text(L10n.text("common.chat.stats.unavailable"))
        } else {
            Text(data.str("model") ?: backend.orEmpty(), fontWeight = FontWeight.SemiBold)
            Text(if (chat.bol("running")) L10n.text("common.running") else L10n.text("common.idle"), style = MaterialTheme.typography.bodySmall)
            val used = data["contextUsed"]?.jsonPrimitive?.doubleOrNull
            val window = data["contextWindow"]?.jsonPrimitive?.doubleOrNull
            if (used != null) {
                Text("${number(used)} / ${window?.let(::number) ?: "—"}", style = MaterialTheme.typography.titleLarge)
                if (window != null && window > 0) {
                    val fraction = (used / window).coerceIn(0.0, 1.0).toFloat()
                    LinearProgressIndicator(progress = { fraction }, modifier = Modifier.fillMaxWidth(), color = LocalTsColors.current.accent)
                    Text(NumberFormat.getPercentInstance().format(fraction), style = MaterialTheme.typography.bodySmall)
                }
                Text(L10n.text("common.chat.stats.context"), style = MaterialTheme.typography.bodySmall)
            } else Text(L10n.text("common.chat.stats.no_data"), style = MaterialTheme.typography.bodySmall)
            (data["contextBreakdown"] as? JsonObject)?.let { split ->
                Text(L10n.text("common.chat.stats.last_prompt"), fontWeight = FontWeight.Medium)
                StatRow(L10n.text("common.chat.stats.input"), number(split["input"]?.jsonPrimitive?.doubleOrNull ?: 0.0))
                StatRow(L10n.text("common.chat.stats.cache_read"), number(split["cacheRead"]?.jsonPrimitive?.doubleOrNull ?: 0.0))
                StatRow(L10n.text("common.chat.stats.cache_write"), number(split["cacheWrite"]?.jsonPrimitive?.doubleOrNull ?: 0.0))
                Text(L10n.text("common.chat.stats.prompt_note"), style = MaterialTheme.typography.bodySmall)
            }
            if (data.str("windowSource") == "catalog") Text(L10n.text("common.chat.stats.catalog_window"), style = MaterialTheme.typography.bodySmall)
            val history = (data["contextHistory"] as? JsonArray).orEmpty().mapNotNull { (it as? JsonObject)?.get("tokens")?.jsonPrimitive?.doubleOrNull }
            if (history.size > 1) {
                Text(L10n.text("common.chat.stats.history"), style = MaterialTheme.typography.bodySmall)
                val color = LocalTsColors.current.accent
                Canvas(Modifier.fillMaxWidth().height(48.dp)) {
                    val peak = history.max().coerceAtLeast(1.0)
                    history.zipWithNext().forEachIndexed { index, (a, b) ->
                        drawLine(color, Offset(size.width * index / (history.size - 1), size.height * (1 - a / peak).toFloat()),
                            Offset(size.width * (index + 1) / (history.size - 1), size.height * (1 - b / peak).toFloat()), strokeWidth = 2.dp.toPx())
                    }
                }
                Text("${number(history.first())} → ${number(history.last())}", style = MaterialTheme.typography.bodySmall)
                Text(L10n.text("common.chat.stats.history_note"), style = MaterialTheme.typography.bodySmall)
            }
            (data["usage"] as? JsonObject)?.let { usage ->
                HorizontalDivider()
                Text(L10n.text("common.chat.stats.conversation"), fontWeight = FontWeight.SemiBold)
                val values = listOf("input", "output", "cacheRead", "cacheWrite").map { usage[it]?.jsonPrimitive?.doubleOrNull?.coerceAtLeast(0.0) ?: 0.0 }
                val labels = listOf(L10n.text("common.chat.stats.input"), L10n.text("common.chat.stats.output"), L10n.text("common.chat.stats.cache_read"), L10n.text("common.chat.stats.cache_write"))
                val colors = listOf(LocalTsColors.current.accent, LocalTsColors.current.textSecondary, LocalTsColors.current.accent.copy(alpha = .5f), LocalTsColors.current.warning)
                Row(Modifier.fillMaxWidth().height(8.dp)) {
                    val total = values.sum().coerceAtLeast(1.0)
                    values.forEachIndexed { index, value -> if (value > 0) Box(Modifier.weight((value / total).toFloat().coerceAtLeast(.00001f)).fillMaxHeight().background(colors[index])) }
                }
                labels.forEachIndexed { index, label -> StatRow(label, number(values[index])) }
                val cost = usage["cost"]?.jsonPrimitive?.doubleOrNull ?: 0.0
                if (cost > 0) StatRow(L10n.text("common.chat.stats.cost"), NumberFormat.getCurrencyInstance(java.util.Locale.US).format(cost))
            }
            tools(data["tools"])?.let { ToolGroups(it, L10n.text("common.chat.stats.available_tools", "${it.size}")) }
            tools(data["usedTools"])?.takeIf { it.isNotEmpty() }?.let { ToolGroups(it, L10n.text("common.chat.stats.used_tools", "${it.size}")) }
            if (data.bol("inventoryPartial")) Text(L10n.text("common.chat.stats.partial"), style = MaterialTheme.typography.bodySmall)
        }
    }
    if (data != null) StatsCard(L10n.text("common.chat.stats.mcp_servers")) {
        val servers = (data["mcpServers"] as? JsonArray).orEmpty().filterIsInstance<JsonObject>()
        val connected = servers.filter { it.str("source") == "agent" && it.str("status") == "connected" }
        val others = servers - connected.toSet()
        if (connected.isNotEmpty()) Text(L10n.text("common.chat.stats.connected_servers", "${connected.size}"), style = MaterialTheme.typography.bodySmall)
        if (servers.isEmpty()) Text(L10n.text("common.chat.stats.no_servers"), style = MaterialTheme.typography.bodySmall)
        connected.forEach { server -> key(server.str("name")) { ServerRow(server, data.bol("currentRun") && chat.bol("running")) } }
        if (others.isNotEmpty()) StatsDisclosure(L10n.text("common.chat.stats.other_servers", "${others.size}")) { others.forEach { server -> key(server.str("name")) { ServerRow(server, false) } } }
        Text(L10n.text("common.chat.stats.reported"), style = MaterialTheme.typography.bodySmall, color = LocalTsColors.current.textSecondary)
    }
}

private fun number(value: Double) = NumberFormat.getIntegerInstance().format(value)
private fun tools(value: JsonElement?) = (value as? JsonArray)?.mapNotNull { it.jsonPrimitive.contentOrNull }
private fun toolGroup(name: String): String = if (name.startsWith("mcp__")) name.removePrefix("mcp__").substringBefore("__") else L10n.text("common.chat.stats.agent_tools")
@Composable private fun ToolGroups(names: List<String>, title: String) {
    StatsDisclosure(title) {
        var query by remember(names) { mutableStateOf("") }
        var group by remember(names) { mutableStateOf<String?>(null) }
        names.groupBy(::toolGroup).toSortedMap().forEach { (name, list) ->
            Row(Modifier.fillMaxWidth().clickable { group = if (group == name) null else name }.padding(10.dp)) {
                Text(name, Modifier.weight(1f)); Text("${list.size}${if (group == name) " ✓" else ""}")
            }
        }
        OutlinedTextField(query, { query = it }, label = { Text(L10n.text("common.chat.stats.search_tools")) }, modifier = Modifier.fillMaxWidth())
        if (group != null || query.isNotBlank()) Column(Modifier.heightIn(max = 220.dp).verticalScroll(rememberScrollState())) {
            names.filter { (group == null || toolGroup(it) == group) && it.contains(query, ignoreCase = true) }.forEach { Text(it, style = MaterialTheme.typography.bodySmall, modifier = Modifier.padding(vertical = 4.dp)) }
        }
    }
}
@Composable private fun ServerRow(server: JsonObject, live: Boolean) {
    Surface(shape = RoundedCornerShape(8.dp), color = LocalTsColors.current.background) {
        Column(Modifier.fillMaxWidth().padding(10.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
            Text(server.str("name").orEmpty().removePrefix("plugin:").replace(":", " · "), fontWeight = FontWeight.Medium)
            Text(serverStatus(server.str("status"), live), style = MaterialTheme.typography.bodySmall,
                color = if (live && server.str("status") == "connected") LocalTsColors.current.accent else LocalTsColors.current.textSecondary)
            tools(server["tools"])?.takeIf { it.isNotEmpty() }?.let { ToolGroups(it, L10n.text("common.chat.stats.available_tools", "${it.size}")) }
        }
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
@Composable private fun StatRow(label: String, value: String) {
    Row(Modifier.fillMaxWidth()) { Text(label, Modifier.weight(1f), style = MaterialTheme.typography.bodySmall); Text(value, style = MaterialTheme.typography.bodySmall) }
}
@Composable private fun StatsCard(title: String, content: @Composable ColumnScope.() -> Unit) {
    Surface(shape = RoundedCornerShape(12.dp), color = LocalTsColors.current.panel) {
        Column(Modifier.fillMaxWidth().padding(12.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
            Text(title, fontWeight = FontWeight.SemiBold); content()
        }
    }
}
@Composable private fun StatsDisclosure(title: String, content: @Composable () -> Unit) {
    var expanded by remember { mutableStateOf(false) }
    Row(Modifier.fillMaxWidth().heightIn(min = 48.dp).clickable { expanded = !expanded }.padding(vertical = 10.dp), verticalAlignment = Alignment.CenterVertically) {
        Text(title, Modifier.weight(1f), fontWeight = FontWeight.Medium)
        Text(if (expanded) "⌃" else "⌄")
    }
    if (expanded) content()
}
