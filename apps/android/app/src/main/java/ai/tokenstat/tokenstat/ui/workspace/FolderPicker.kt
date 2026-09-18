// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.workspace

import androidx.activity.compose.BackHandler
import ai.tokenstat.tokenstat.ui.chrome.HideTabBar

import ai.tokenstat.tokenstat.ui.chrome.HideTopBar

import ai.tokenstat.tokenstat.AppViewModel
import ai.tokenstat.tokenstat.ui.chrome.TabBarChrome
import ai.tokenstat.tokenstat.ui.components.ActionIcon
import ai.tokenstat.tokenstat.ui.components.Banner
import ai.tokenstat.tokenstat.ui.components.BannerSeverity
import ai.tokenstat.tokenstat.ui.components.TsAccentButton
import ai.tokenstat.tokenstat.ui.components.TsSecondaryButton
import ai.tokenstat.tokenstat.ui.theme.LocalTsColors
import ai.tokenstat.tokenstat.ui.theme.Space
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.ChevronRight
import androidx.compose.material.icons.filled.Description
import androidx.compose.material.icons.filled.Folder
import androidx.compose.material.icons.filled.Inventory
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.launch
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put

/// Register a folder that is already on the computer: browse its disk, make
/// a folder where one is needed, and register the one you are looking at.
/// Port of `ClientFolderPicker`.
@Composable
fun FolderPickerScreen(
    model: AppViewModel,
    peer: String,
    hostName: String,
    onClose: () -> Unit,
    onAdded: (JsonObject) -> Unit,
) {
    // Its own header and its own way out, so the app chrome steps aside.
    HideTopBar()
    HideTabBar()
    // A pushed screen owns the system back. Without it the gesture falls
    // through to the activity and closes the app instead of stepping back.
    BackHandler { onClose() }
    val colors = LocalTsColors.current
    val scope = rememberCoroutineScope()
    var listing by remember { mutableStateOf<JsonObject?>(null) }
    var loading by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    var showHidden by remember { mutableStateOf(false) }
    var naming by remember { mutableStateOf(false) }
    var newFolder by remember { mutableStateOf("") }
    var menu by remember { mutableStateOf(false) }
    // Guards against stale responses when rows are tapped in quick succession.
    var generation by remember { mutableStateOf(0) }

    suspend fun load(path: String?) {
        val mine = generation + 1
        generation = mine
        loading = true
        error = null
        runCatching {
            val params = buildJsonObject { if (path != null) put("path", path) }
            model.workspaceSection(peer, "fs.browse", params) as JsonObject
        }.onSuccess { if (generation == mine) listing = it }
            .onFailure { if (generation == mine) error = it.message }
        if (generation == mine) loading = false
    }

    suspend fun create(): Boolean {
        val here = listing?.str("path") ?: return false
        val name = newFolder.trim()
        if (name.isEmpty()) return false
        loading = true
        val made = runCatching {
            val answer = model.workspaceSection(peer, "fs.mkdir", buildJsonObject { put("path", "$here/$name") }) as JsonObject
            answer.str("path") ?: "$here/$name"
        }
        loading = false
        return made
            .onSuccess {
                newFolder = ""
                naming = false
                scope.launch { load(it) }
            }
            .onFailure { error = it.message }
            .isSuccess
    }

    suspend fun add(path: String) {
        loading = true
        runCatching {
            model.workspaceSection(peer, "workspace.add", buildJsonObject { put("path", path) }) as JsonObject
        }.onSuccess(onAdded).onFailure { error = it.message }
        loading = false
    }

    LaunchedEffect(peer) { load(null) }

    Column(Modifier.fillMaxSize()) {
        Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.padding(horizontal = 8.dp)) {
            IconButton(onClick = onClose) { Icon(Icons.AutoMirrored.Filled.ArrowBack, "Back") }
            Text(
                "Choose a folder",
                style = MaterialTheme.typography.headlineSmall,
                color = colors.textPrimary,
                modifier = Modifier.weight(1f),
            )
            IconButton(onClick = { menu = true }) { Icon(ActionIcon.More.vector, "Options") }
            DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
                DropdownMenuItem(
                    text = { Text(if (showHidden) "Hide dotfiles" else "Show dotfiles") },
                    onClick = { menu = false; showHidden = !showHidden },
                )
                DropdownMenuItem(
                    text = { Text("New folder here") },
                    enabled = listing != null,
                    onClick = { menu = false; naming = true },
                )
            }
        }
        listing?.let { current ->
            Column(Modifier.padding(horizontal = 16.dp, vertical = 8.dp)) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    current.str("parent")?.let { parent ->
                        TextButton(onClick = { scope.launch { load(parent) } }) { Text("Up") }
                    }
                    Text(
                        current.str("path") ?: "",
                        fontFamily = FontFamily.Monospace,
                        style = MaterialTheme.typography.bodySmall,
                        color = colors.textPrimary,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                        modifier = Modifier.weight(1f),
                    )
                }
                val roots = (current["roots"] as? JsonArray).orEmpty().mapNotNull { it as? JsonObject }
                if (roots.size > 1) {
                    Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(Space.s)) {
                        roots.forEach { root ->
                            TextButton(onClick = { scope.launch { load(root.str("path")) } }) {
                                Text(root.str("label") ?: root.str("path") ?: "")
                            }
                        }
                    }
                }
            }
            HorizontalDivider(color = colors.border)
        }
        error?.let {
            Banner(it, BannerSeverity.DANGER, modifier = Modifier.padding(16.dp))
        }
        val entries = (listing?.get("entries") as? JsonArray).orEmpty()
            .mapNotNull { it as? JsonObject }
            .filter { showHidden || it.bol("hidden") != true }
        LazyColumn(Modifier.weight(1f), contentPadding = PaddingValues(bottom = TabBarChrome.contentBottomInset)) {
            if (entries.isEmpty() && !loading) {
                item {
                    Text(
                        if ((listing?.get("entries") as? JsonArray).isNullOrEmpty()) "This folder is empty."
                        else "Everything here is a dotfile. Show them from the menu.",
                        color = colors.textSecondary,
                        modifier = Modifier.padding(16.dp),
                    )
                }
            }
            items(entries) { entry ->
                val isDir = entry.str("kind") == "directory"
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    modifier = Modifier.fillMaxWidth()
                        .clickable(enabled = isDir && entry.str("path") != null) {
                            entry.str("path")?.let { scope.launch { load(it) } }
                        }
                        .padding(horizontal = 16.dp, vertical = 12.dp),
                ) {
                    Icon(
                        when {
                            entry.bol("isRepo") == true -> Icons.Default.Inventory
                            isDir -> Icons.Default.Folder
                            else -> Icons.Default.Description
                        },
                        null,
                        tint = if (isDir) colors.accent else colors.textSecondary,
                        modifier = Modifier.size(20.dp),
                    )
                    Spacer(Modifier.width(Space.m))
                    Column(Modifier.weight(1f)) {
                        Text(
                            entry.str("name") ?: "",
                            color = if (isDir) colors.textPrimary else colors.textSecondary,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis,
                        )
                        if (entry.bol("isRegistered") == true) {
                            Text("already registered", style = MaterialTheme.typography.bodySmall, color = colors.textSecondary)
                        }
                    }
                    if (isDir) Icon(Icons.Default.ChevronRight, null, tint = colors.textSecondary)
                }
                HorizontalDivider(color = colors.border)
            }
            if (listing?.bol("truncated") == true) {
                item {
                    Text(
                        "Only the first 2000 entries are shown.",
                        style = MaterialTheme.typography.bodySmall,
                        color = colors.textSecondary,
                        modifier = Modifier.padding(16.dp),
                    )
                }
            }
        }
        listing?.let { current ->
            Column(Modifier.fillMaxWidth().padding(16.dp)) {
                TsAccentButton(
                    label = if (loading) "Working…" else "Use this folder",
                    icon = ActionIcon.Approve.vector,
                    enabled = !loading,
                    onClick = { current.str("path")?.let { scope.launch { add(it) } } },
                    modifier = Modifier.fillMaxWidth(),
                )
            }
        }
    }
    if (naming) {
        AlertDialog(
            onDismissRequest = { naming = false; newFolder = "" },
            title = { Text("New folder") },
            text = {
                Column {
                    Text("It is made on $hostName, inside the folder you are looking at.")
                    Spacer(Modifier.height(Space.s))
                    OutlinedTextField(newFolder, { newFolder = it }, label = { Text("Name") }, singleLine = true)
                }
            },
            confirmButton = {
                TsAccentButton(label = "Create", small = true, enabled = newFolder.isNotBlank(), onClick = {
                    scope.launch { create() }
                })
            },
            dismissButton = {
                TsSecondaryButton(label = "Cancel", small = true, onClick = { naming = false; newFolder = "" })
            },
        )
    }
}
