// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.workspace

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import ai.tokenstat.tokenstat.AppViewModel
import ai.tokenstat.tokenstat.ui.components.EmptyState
import ai.tokenstat.tokenstat.ui.components.SectionLabel
import ai.tokenstat.tokenstat.ui.components.TsAccentButton
import ai.tokenstat.tokenstat.ui.logic.HostContracts
import ai.tokenstat.tokenstat.ui.logic.RelativeClock
import ai.tokenstat.tokenstat.ui.logic.friendlyError
import kotlinx.coroutines.launch
import kotlinx.serialization.json.*
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ChatBubbleOutline

private fun JsonObject.str(key: String): String? =
    this[key]?.takeUnless { it is JsonNull }?.jsonPrimitive?.contentOrNull

@Composable
fun ChatSection(
    model: AppViewModel,
    peer: String,
    workspace: String,
    protocol: Long?,
    modifier: Modifier = Modifier,
) {
    val scope = rememberCoroutineScope()
    var chats by remember(workspace) { mutableStateOf<List<JsonObject>>(emptyList()) }
    var openId by remember(workspace) { mutableStateOf<String?>(null) }
    var events by remember(workspace) { mutableStateOf<List<JsonObject>>(emptyList()) }
    var error by remember(workspace) { mutableStateOf<String?>(null) }
    var loading by remember(workspace) { mutableStateOf(true) }
    var draft by remember(workspace) { mutableStateOf("") }
    var sending by remember { mutableStateOf(false) }

    suspend fun loadChats() {
        loading = true
        runCatching {
            model.workspaceSection(peer, "chat.list", buildJsonObject { put("workspaceId", workspace) })
        }.onSuccess {
            chats = (it as? JsonArray)?.filterIsInstance<JsonObject>() ?: emptyList()
            error = null
        }.onFailure { error = friendlyError(it.message).message }
        loading = false
    }
    suspend fun loadEvents(id: String) {
        runCatching {
            model.workspaceSection(peer, "chat.events", buildJsonObject {
                put("id", id); put("offset", 0L)
            })
        }.onSuccess {
            val arr = (it as? JsonObject)?.get("events") as? JsonArray
                ?: (it as? JsonArray)
            events = arr?.filterIsInstance<JsonObject>() ?: emptyList()
        }
    }
    LaunchedEffect(workspace) { loadChats() }
    LaunchedEffect(openId) {
        val id = openId ?: return@LaunchedEffect
        while (true) {
            loadEvents(id)
            kotlinx.coroutines.delay(2000)
        }
    }

    Column(modifier, verticalArrangement = Arrangement.spacedBy(8.dp)) {
        SectionLabel("Conversations")
        if (!HostContracts.supportsChat(protocol)) {
            Text("Update the host to use chat (needs protocol 4).", style = MaterialTheme.typography.bodySmall)
            return
        }
        if (error != null) Text(error!!, style = MaterialTheme.typography.bodySmall)
        if (openId == null) {
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                TsAccentButton(label = "New chat", small = true, onClick = {
                    scope.launch {
                        runCatching {
                            model.workspaceSection(peer, "chat.create", buildJsonObject {
                                put("workspaceId", workspace); put("backend", "opencode")
                            })
                        }.onSuccess { loadChats() }
                    }
                })
                TextButton(onClick = { scope.launch { loadChats() } }) { Text("Refresh") }
            }
            if (loading) { CircularProgressIndicator(Modifier.size(20.dp), strokeWidth = 2.dp); return }
            if (chats.isEmpty()) {
                EmptyState(Icons.Default.ChatBubbleOutline, "Start a chat", "Ask an agent to explore, plan, or work in this folder.")
                return
            }
            LazyColumn(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                items(chats, key = { it.str("id") ?: it.hashCode().toString() }) { chat ->
                    ElevatedCard(onClick = { openId = chat.str("id") }) {
                        Column(Modifier.padding(12.dp)) {
                            Text(chat.str("title") ?: "Untitled", style = MaterialTheme.typography.titleSmall)
                            Text(
                                listOfNotNull(chat.str("backend"), chat.str("model")).joinToString(" · "),
                                style = MaterialTheme.typography.bodySmall,
                            )
                        }
                    }
                }
            }
        } else {
            TextButton(onClick = { openId = null; scope.launch { loadChats() } }) { Text("← All conversations") }
            LazyColumn(Modifier.weight(1f, false), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                items(events, key = { it.str("seq") ?: it.hashCode().toString() }) { ev ->
                    val kind = ev.str("kind") ?: ev.str("role") ?: "event"
                    val innerEv = ev["event"] as? JsonObject
                    val text = ev.str("text")
                        ?: innerEv?.str("delta")
                        ?: innerEv?.str("text")
                        ?: innerEv?.str("target")?.let { target -> "${innerEv.str("verb") ?: "Tool"}: $target" }
                        ?: innerEv?.str("name")?.let { name -> "Attachment: $name" }
                        ?: ev.str("body")
                        ?: ""
                    val timeMs = ev["atMs"]?.jsonPrimitive?.longOrNull
                    val timeLabel = timeMs?.let { RelativeClock.label(it) } ?: ""
                    Card {
                        Column(Modifier.padding(10.dp)) {
                            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
                                Text(kind, style = MaterialTheme.typography.labelSmall)
                                if (timeLabel.isNotEmpty()) {
                                    Text(timeLabel, style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.outline)
                                }
                            }
                            if (text.isNotEmpty()) {
                                Spacer(Modifier.height(4.dp))
                                Text(text, style = MaterialTheme.typography.bodySmall)
                            }
                        }
                    }
                }
            }
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                OutlinedTextField(draft, { draft = it }, Modifier.weight(1f), placeholder = { Text("Ask about this folder") })
                TsAccentButton(label = if (sending) "…" else "Send", small = true, onClick = {
                    val id = openId ?: return@TsAccentButton
                    val text = draft.trim(); if (text.isEmpty() || sending) return@TsAccentButton
                    sending = true
                    scope.launch {
                        runCatching {
                            model.workspaceSection(peer, "chat.send", buildJsonObject {
                                put("id", id); put("text", text)
                            })
                        }.onSuccess { draft = ""; loadEvents(id) }
                        sending = false
                    }
                })
            }
            Text("Times shown relatively; full transcript pinning ships next.", style = MaterialTheme.typography.labelSmall)
        }
    }
}

@Composable
fun PullsSection(
    model: AppViewModel,
    peer: String,
    workspace: String,
    protocol: Long?,
    modifier: Modifier = Modifier,
) {
    val scope = rememberCoroutineScope()
    var pulls by remember(workspace) { mutableStateOf<List<JsonObject>>(emptyList()) }
    var error by remember(workspace) { mutableStateOf<String?>(null) }
    var loading by remember(workspace) { mutableStateOf(true) }

    suspend fun load() {
        loading = true
        runCatching {
            model.workspaceSection(peer, "pulls.list", buildJsonObject {
                put("workspaceId", workspace); put("state", "open"); put("limit", 30)
            })
        }.onSuccess {
            val arr = (it as? JsonObject)?.get("pulls") as? JsonArray ?: (it as? JsonArray)
            pulls = arr?.filterIsInstance<JsonObject>() ?: emptyList()
            error = null
        }.onFailure { error = friendlyError(it.message).message }
        loading = false
    }
    LaunchedEffect(workspace) { load() }
    Column(modifier, verticalArrangement = Arrangement.spacedBy(8.dp)) {
        SectionLabel("Pull requests")
        if (!HostContracts.supportsPulls(protocol)) {
            Text("Update the host to read pull requests (needs protocol 3).", style = MaterialTheme.typography.bodySmall)
            return
        }
        if (error != null) Text(error!!, style = MaterialTheme.typography.bodySmall)
        if (loading) { CircularProgressIndicator(Modifier.size(20.dp), strokeWidth = 2.dp); return }
        if (pulls.isEmpty()) {
            EmptyState(Icons.Default.ChatBubbleOutline, "No open pulls", "Connect GitHub on the host to review here.")
            return
        }
        LazyColumn(verticalArrangement = Arrangement.spacedBy(6.dp)) {
            items(pulls, key = { it.str("number") ?: it.hashCode().toString() }) { pr ->
                ElevatedCard(onClick = {}) {
                    Column(Modifier.padding(12.dp)) {
                        Text(pr.str("title") ?: "Pull #${pr.str("number")}", style = MaterialTheme.typography.titleSmall)
                        Text(
                            listOfNotNull(pr.str("head"), pr.str("base"), pr.str("state")).joinToString(" · "),
                            style = MaterialTheme.typography.bodySmall,
                        )
                    }
                }
            }
        }
    }
}
