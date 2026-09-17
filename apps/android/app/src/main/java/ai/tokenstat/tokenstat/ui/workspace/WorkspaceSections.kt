// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.workspace

import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight

import androidx.compose.ui.graphics.drawscope.Stroke

import androidx.compose.ui.graphics.PathEffect

import androidx.compose.ui.geometry.CornerRadius

import androidx.compose.ui.draw.drawBehind

import ai.tokenstat.tokenstat.ui.components.ActionIcon

import ai.tokenstat.tokenstat.ui.chrome.TabBarChrome
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.InsertDriveFile
import androidx.compose.material.icons.automirrored.filled.MergeType
import androidx.compose.material.icons.automirrored.filled.Notes
import androidx.compose.material.icons.filled.AccountTree
import androidx.compose.material.icons.filled.Archive
import androidx.compose.material.icons.filled.Bolt
import androidx.compose.material.icons.filled.ChatBubbleOutline
import androidx.compose.material.icons.filled.Checklist
import androidx.compose.material.icons.filled.Difference
import androidx.compose.material.icons.filled.FolderOpen
import androidx.compose.material.icons.filled.History
import androidx.compose.material.icons.filled.Lock
import androidx.compose.material.icons.filled.LockOpen
import androidx.compose.material.icons.filled.Terminal
import androidx.compose.material.icons.filled.Unarchive
import androidx.compose.material.icons.filled.Add
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
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
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import ai.tokenstat.tokenstat.AppViewModel
import ai.tokenstat.tokenstat.ui.components.Banner
import ai.tokenstat.tokenstat.ui.components.BannerSeverity
import ai.tokenstat.tokenstat.ui.components.EmptyState
import ai.tokenstat.tokenstat.ui.components.SectionLabel
import ai.tokenstat.tokenstat.ui.components.SkeletonRows
import ai.tokenstat.tokenstat.ui.components.TsAccentButton
import ai.tokenstat.tokenstat.ui.components.TsSecondaryButton
import ai.tokenstat.tokenstat.ui.components.TsType
import ai.tokenstat.tokenstat.ui.components.cardRadiusDp
import ai.tokenstat.tokenstat.ui.logic.TunnelCopy
import ai.tokenstat.tokenstat.ui.marks.CadenceGlyph
import ai.tokenstat.tokenstat.ui.marks.EmptyArt
import ai.tokenstat.tokenstat.ui.marks.EmptyArtKind
import ai.tokenstat.tokenstat.ui.theme.LocalTsColors
import ai.tokenstat.tokenstat.ui.theme.Space
import androidx.compose.material.icons.filled.Language
import kotlinx.coroutines.launch
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.add
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.longOrNull
import kotlinx.serialization.json.put
import kotlinx.serialization.json.putJsonArray

/// Shared JSON readers for the workspace sections. Internal so each section
/// file reads the host answers the same way.
internal fun JsonObject.str(key: String): String? =
    (this[key] as? JsonPrimitive)?.contentOrNull

internal fun JsonObject.bol(key: String): Boolean = (this[key] as? JsonPrimitive)?.booleanOrNull == true

internal fun JsonObject.long(key: String): Long? = (this[key] as? JsonPrimitive)?.longOrNull

internal fun asObjects(element: JsonElement?): List<JsonObject> =
    (element as? JsonArray)?.filterIsInstance<JsonObject>() ?: emptyList()/// One workspace section, rendered as its own surface instead of a raw JSON
/// dump. Each section reaches the real remote method over the tunnel; the
/// renderers mirror their Apple counterparts' content and colour rules.
@OptIn(ExperimentalLayoutApi::class)
@Composable
fun WorkspaceSection(
    model: AppViewModel,
    peer: String,
    workspace: String,
    hostLabel: String,
    section: String,
    modifier: Modifier = Modifier,
    protocol: Long? = null,
    folderName: String = "",
    onOpenTerminal: (String?) -> Unit,
    onOpenBrowser: (String, Int) -> Unit = { _, _ -> },
    onOpenSection: (String) -> Unit = {},
    onChatOpened: (String) -> Unit = {},
    initialChatId: String? = null,
    openConversationOnAppear: Boolean = false,
    conversationNonce: Int = 0,
    onStartChat: () -> Unit = {},
) {
    val scope = rememberCoroutineScope()
    var data by remember(section) { mutableStateOf<JsonElement?>(null) }
    var error by remember(section) { mutableStateOf<String?>(null) }
    var loading by remember(section) { mutableStateOf(true) }

    suspend fun load() {
        loading = true
        val params = buildJsonObject {
            when (section) {
                "Sessions" -> put("includeRemote", false)
                "Files" -> { put("id", workspace); put("path", "") }
                "Changes" -> put("id", workspace)
                "Tasks", "Notes" -> put("includeArchived", true)
                else -> put("workspaceId", workspace)
            }
        }
        runCatching { model.workspaceSection(peer, methodFor(section), params) }
            .onSuccess { data = it; error = null }
            .onFailure { error = TunnelCopy.display(it.message ?: "The request failed.", hostLabel) }
        loading = false
    }
    LaunchedEffect(section) { load() }

    val reload: () -> Unit = { scope.launch { load() } }
    when (section) {
        "Sessions" -> SessionsSection(model, peer, workspace, folderName, hostLabel, data, error, loading, onOpenTerminal, reload, onOpenSection, onStartChat, modifier)
        "Chat" -> ChatSection(model, peer, workspace, protocol = protocol, modifier, folderName, hostLabel, onChatOpened, initialChatId, openConversationOnAppear, conversationNonce)
        "Pulls" -> PullsSection(model, peer, workspace, protocol = protocol, modifier, folderName, hostLabel)
        "Changes" -> ChangesSection(model, peer, workspace, modifier, folderName, hostLabel, protocol, onChanged = reload)
        "History" -> HistorySection(model, peer, workspace, modifier, folderName, hostLabel)
        "Tasks" -> TodoSection(model, peer, workspace, data, error, loading, kindTask = true, onChanged = reload, modifier, folderName, hostLabel, onOpenSection, protocol, onOpenTerminal)
        "Notes" -> NotesSection(model, peer, workspace, modifier, folderName, hostLabel)
        "Workflows" -> WorkflowsSection(model, peer, workspace, data, error, loading, reload, modifier, folderName, hostLabel, protocol)
        "Automations" -> AutomationsSection(model, peer, workspace, data, error, loading, reload, modifier, folderName, hostLabel, protocol)
        "Files" -> FilesSection(model, peer, workspace, modifier, folderName, hostLabel)
        "Browser" -> BrowserSection(model, peer, onOpenBrowser, modifier)
        else -> EmptyState(Icons.AutoMirrored.Filled.Notes, "Nothing here", "This section has no content yet.", modifier)
    }
}

private fun methodFor(section: String): String = when (section) {
    "Sessions" -> "pty.list"
    "Chat" -> "chat.list"
    "Pulls" -> "pulls.list"
    "Changes" -> "workspace.status"
    "History" -> "workspace.log"
    "Tasks", "Notes" -> "todo.list"
    "Workflows" -> "workflow.list"
    "Automations" -> "automation.list"
    "Files" -> "workspace.tree"
    else -> "host.stats"
}

@Composable
private fun SectionError(error: String?) {
    if (error != null) Banner(error, BannerSeverity.DANGER)
}

@Composable
private fun SessionsSection(
    model: AppViewModel,
    peer: String,
    workspace: String,
    folderName: String,
    hostLabel: String,
    data: JsonElement?,
    error: String?,
    loading: Boolean,
    onOpen: (String?) -> Unit,
    onLoad: () -> Unit,
    onOpenSection: (String) -> Unit,
    onStartChat: () -> Unit,
    modifier: Modifier,
) {
    val context = androidx.compose.ui.platform.LocalContext.current
    val scope = rememberCoroutineScope()
    val dark = androidx.compose.foundation.isSystemInDarkTheme()
    val prefs = remember(peer, workspace) {
        context.getSharedPreferences("tokenstat.launcher.v1", android.content.Context.MODE_PRIVATE)
    }
    var catalog by remember(peer) { mutableStateOf<List<ai.tokenstat.tokenstat.ui.logic.LaunchProfile>>(emptyList()) }
    var catalogLoaded by remember(peer) { mutableStateOf(false) }
    var folderPath by remember(peer, workspace) { mutableStateOf("") }
    var stickyError by remember(peer, workspace) { mutableStateOf<String?>(null) }
    var launchingId by remember { mutableStateOf<String?>(null) }
    var installingId by remember { mutableStateOf<String?>(null) }
    var pendingInstall by remember { mutableStateOf<ai.tokenstat.tokenstat.ui.logic.LaunchProfile?>(null) }
    var pendingClose by remember { mutableStateOf<JsonObject?>(null) }
    var showExtra by remember { mutableStateOf(false) }
    var hiddenVersion by remember { mutableStateOf(0) }
    var bypassOn by remember(peer, workspace) {
        mutableStateOf(
            context.getSharedPreferences("tokenstat.bypass.v1", android.content.Context.MODE_PRIVATE)
                .getBoolean("bypass.$workspace", false),
        )
    }
    val locallyHidden: Set<String> = remember(prefs, hiddenVersion) {
        prefs.getStringSet("hidden.$peer", emptySet()) ?: emptySet()
    }

    suspend fun loadCatalog() {
        runCatching {
            model.workspaceSection(peer, "launcher.catalog", buildJsonObject {})
        }.onSuccess { element ->
            catalog = asObjects(element).mapNotNull { ai.tokenstat.tokenstat.ui.logic.LaunchCatalog.parse(it) }
            catalogLoaded = true
        }.onFailure {
            // A host that predates the launcher still gets the shell tile.
            catalogLoaded = true
        }
    }
    // The Chat tile's badge counts the workspace's conversations, like the
    // iOS destination tile. A failed count hides the badge, not the tile.
    var chatCount by remember(peer, workspace) { mutableStateOf(0) }
    LaunchedEffect(peer, workspace) {
        loadCatalog()
        runCatching {
            model.workspaceSection(peer, "workspace.status", buildJsonObject { put("id", workspace) }) as? JsonObject
        }.onSuccess { folderPath = it?.str("path").orEmpty() }
        runCatching {
            model.workspaceSection(peer, "chat.list", buildJsonObject { put("workspaceId", workspace) })
        }.onSuccess { chatCount = asObjects(it).size }
    }

    fun setHidden(id: String, hide: Boolean, tellHost: Boolean) {
        val next = if (hide) locallyHidden + id else locallyHidden - id
        prefs.edit().putStringSet("hidden.$peer", next).apply()
        hiddenVersion += 1
        if (tellHost) {
            scope.launch {
                runCatching {
                    model.workspaceSection(peer, if (hide) "launcher.hide" else "launcher.show", buildJsonObject { put("id", id) })
                }
                loadCatalog()
            }
        }
    }

    fun launch(profile: ai.tokenstat.tokenstat.ui.logic.LaunchProfile) {
        if (launchingId != null || installingId != null) return
        launchingId = profile.id
        stickyError = null
        scope.launch {
            runCatching {
                model.workspaceSection(peer, "pty.spawn", buildJsonObject {
                    put("workspaceId", workspace)
                    put("command", profile.command)
                    putJsonArray("args") { profile.launchArgs(bypassOn).forEach { add(it) } }
                    put("rows", 40)
                    put("cols", 100)
                    put("noColor", false)
                    put("dark", dark)
                }) as? JsonObject
            }.onSuccess { info ->
                launchingId = null
                val id = info?.str("id")
                onOpen(id)
                onLoad()
            }.onFailure {
                launchingId = null
                stickyError = TunnelCopy.display(it.message ?: "The request failed.", hostLabel)
            }
        }
    }

    fun install(profile: ai.tokenstat.tokenstat.ui.logic.LaunchProfile) {
        if (installingId != null) return
        installingId = profile.id
        scope.launch {
            runCatching {
                model.workspaceSection(peer, "launcher.install", buildJsonObject { put("id", profile.id) }) as? JsonObject
            }.onSuccess { result ->
                installingId = null
                if (result?.bol("installed") == true || result?.bol("ok") == true) {
                    setHidden(profile.id, false, tellHost = false)
                    loadCatalog()
                } else {
                    val tail = (result?.str("output") ?: "").trim()
                    val code = result?.long("exitCode") ?: 1
                    stickyError = tail.ifEmpty { "${profile.name} could not be installed (exit $code)" }
                }
            }.onFailure {
                installingId = null
                stickyError = TunnelCopy.display(it.message ?: "The request failed.", hostLabel)
            }
        }
    }

    val allSessions = asObjects(data)
    val sessions = allSessions.filter { session ->
        val ws = session.str("workspaceID") ?: session.str("workspaceId")
        if (!ws.isNullOrEmpty()) {
            ws == workspace
        } else if (folderPath.isNotEmpty()) {
            val cwd = session.str("cwd").orEmpty()
            cwd == folderPath || cwd.startsWith(folderPath + "/")
        } else {
            true
        }
    }
    val tiles = ai.tokenstat.tokenstat.ui.logic.LaunchCatalog.visible(catalog, locallyHidden)
    val extra = ai.tokenstat.tokenstat.ui.logic.LaunchCatalog.extra(catalog, locallyHidden)
    val shell = ai.tokenstat.tokenstat.ui.logic.LaunchCatalog.shellFallback()
    val grid = tiles.ifEmpty {
        if (catalogLoaded && !locallyHidden.contains(shell.id)) listOf(shell) else emptyList()
    }

    LazyColumn(modifier, contentPadding = PaddingValues(bottom = TabBarChrome.contentBottomInset), verticalArrangement = Arrangement.spacedBy(Space.s)) {
        item {
            BypassCard(
                bypassOn = bypassOn,
                onToggle = { next ->
                    bypassOn = next
                    context.getSharedPreferences("tokenstat.bypass.v1", android.content.Context.MODE_PRIVATE)
                        .edit().putBoolean("bypass.$workspace", next).apply()
                },
            )
        }
        item {
            OpenDestinationsGrid(onOpenSection = onOpenSection, onStartChat = onStartChat, chatCount = chatCount)
        }
        if (stickyError != null) {
            item {
                StickyErrorCard(
                    message = stickyError!!,
                    onDismiss = { stickyError = null },
                )
            }
        }
        if (error != null) item { SectionError(error) }
        item { SectionLabel("Run an agent") }
        if (!catalogLoaded) {
            item { SkeletonRows(count = 2) }
        } else {
            // The rest of the catalog is the last cell of the grid, a dashed
            // `+` tile, exactly where the Apple grid puts it. A bordered
            // "More agents (1)" chip underneath read as a filter on the list
            // above rather than as one more thing you can open, and it broke
            // the grid's shape at the bottom.
            val cells = grid.size + if (extra.isNotEmpty()) 1 else 0
            itemsIndexed((0 until cells).toList().chunked(2)) { _, pair ->
                Row(horizontalArrangement = Arrangement.spacedBy(Space.s)) {
                    pair.forEach { index ->
                        if (index < grid.size) {
                            val profile = grid[index]
                            LaunchTile(
                                profile = profile,
                                busy = launchingId == profile.id,
                                dimmed = launchingId != null && launchingId != profile.id,
                                onTap = { launch(profile) },
                                onHide = { setHidden(profile.id, true, tellHost = true) },
                                modifier = Modifier.weight(1f),
                            )
                        } else {
                            MoreLaunchTile(
                                showing = showExtra,
                                onTap = { showExtra = !showExtra },
                                modifier = Modifier.weight(1f),
                            )
                        }
                    }
                    if (pair.size == 1) Spacer(Modifier.weight(1f))
                }
            }
            if (showExtra) {
                itemsIndexed(extra) { _, profile ->
                    val offGrid = ai.tokenstat.tokenstat.ui.logic.LaunchCatalog.isOffGrid(profile, locallyHidden)
                    ExtraLaunchRow(
                        profile = profile,
                        offGrid = offGrid,
                        installing = installingId == profile.id,
                        installBusy = installingId != null && installingId != profile.id,
                        onInstall = { pendingInstall = profile },
                        onHide = { setHidden(profile.id, true, tellHost = true) },
                        onShow = { setHidden(profile.id, false, tellHost = true) },
                        onLaunch = { launch(profile) },
                    )
                }
            }
        }
        item {
            Row(verticalAlignment = Alignment.CenterVertically) {
                SectionLabel("Sessions", sessions.size, Modifier.weight(1f))
                TextButton(onClick = onLoad) { Text("Refresh") }
            }
        }
        if (loading && sessions.isEmpty()) item { SkeletonRows(count = 3) }
        if (!loading && sessions.isEmpty()) {
            item {
                EmptyState(
                    Icons.Default.Terminal,
                    "Nothing running here",
                    "Start an agent from the row above and it opens right here.",
                    art = { EmptyArt(EmptyArtKind.Sessions) },
                )
            }
        }
        itemsIndexed(sessions) { _, session ->
            val id = session.str("id") ?: return@itemsIndexed
            Row(
                Modifier
                    .fillMaxWidth()
                    .clip(RoundedCornerShape(cardRadiusDp))
                    .background(LocalTsColors.current.panel)
                    .clickable(indication = null, interactionSource = remember { MutableInteractionSource() }) { onOpen(id) }
                    .padding(Space.m),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(Space.s),
            ) {
                Icon(Icons.Default.Terminal, null, tint = LocalTsColors.current.accent)
                Column(Modifier.weight(1f)) {
                    Text(session.str("command") ?: "shell", style = TsType.mono(13), color = LocalTsColors.current.textPrimary)
                    Text(
                        listOfNotNull(session.str("status"), session.str("title")).joinToString(" · ").ifBlank { id },
                        style = TextStyle(fontSize = 11.sp),
                        color = LocalTsColors.current.textTertiary,
                        maxLines = 1,
                    )
                }
                TextButton(onClick = { pendingClose = session }) { Text("Close") }
            }
        }
    }
    val install = pendingInstall
    if (install != null) {
        AlertDialog(
            onDismissRequest = { pendingInstall = null },
            title = { Text("Install ${install.name}?") },
            text = { Text("This runs its official installer.") },
            confirmButton = {
                TextButton(onClick = { pendingInstall = null; install(install) }) { Text("Install") }
            },
            dismissButton = { TextButton(onClick = { pendingInstall = null }) { Text("Cancel") } },
        )
    }
    val closing = pendingClose
    if (closing != null) {
        AlertDialog(
            onDismissRequest = { pendingClose = null },
            title = { Text("Close this session?") },
            text = { Text("The process on ${hostLabel.ifBlank { "the host" }} stops. This cannot be undone.") },
            confirmButton = {
                val scope2 = rememberCoroutineScope()
                TextButton(onClick = {
                    pendingClose = null
                    scope2.launch {
                        runCatching {
                            model.workspaceSection(peer, "pty.close", buildJsonObject { put("id", closing.str("id") ?: "") })
                        }.onFailure { stickyError = TunnelCopy.display(it.message ?: "The request failed.", hostLabel) }
                        onLoad()
                    }
                }) { Text("Close session") }
            },
            dismissButton = { TextButton(onClick = { pendingClose = null }) { Text("Keep it") } },
        )
    }
}

@Composable
private fun BypassCard(bypassOn: Boolean, onToggle: (Boolean) -> Unit) {
    val colors = LocalTsColors.current
    Row(
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(Space.s),
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(cardRadiusDp))
            .background(colors.panel)
            .padding(Space.m),
    ) {
        Icon(
            if (bypassOn) Icons.Default.LockOpen else Icons.Default.Lock,
            contentDescription = null,
            tint = if (bypassOn) colors.warning else colors.accent,
        )
        Column(Modifier.weight(1f)) {
            Text("Bypass permissions", style = TextStyle(fontSize = 12.sp), color = colors.textSecondary)
            Text(
                if (bypassOn) "On" else "Off",
                style = TextStyle(fontSize = 14.sp, fontWeight = androidx.compose.ui.text.font.FontWeight.Medium),
                color = colors.textPrimary,
            )
        }
        ai.tokenstat.tokenstat.ui.components.TsBrandSwitch(checked = bypassOn, onCheckedChange = onToggle)
    }
}

@Composable
private fun OpenDestinationsGrid(onOpenSection: (String) -> Unit, onStartChat: () -> Unit, chatCount: Int = 0) {
    Column(verticalArrangement = Arrangement.spacedBy(Space.s)) {
        SectionLabel("Open")
        val tiles = listOf(
            Triple("Chat", Icons.Default.ChatBubbleOutline, null),
            Triple("Files", Icons.Default.FolderOpen, "Files"),
            Triple("Browser", Icons.Default.Language, "Browser"),
            Triple("Changes", Icons.Default.Difference, "Changes"),
            Triple("History", Icons.Default.History, "History"),
            Triple("Pull requests", Icons.AutoMirrored.Filled.MergeType, "Pulls"),
            Triple("Tasks", Icons.Default.Checklist, "Tasks"),
        )
        tiles.chunked(2).forEach { pair ->
            Row(horizontalArrangement = Arrangement.spacedBy(Space.s)) {
                val first = pair[0]
                DestinationTile(
                    first.first, first.second,
                    { if (first.third == null) onStartChat() else onOpenSection(first.third!!) },
                    Modifier.weight(1f),
                    count = if (first.third == null) chatCount else 0,
                )
                if (pair.size > 1) {
                    val second = pair[1]
                    DestinationTile(
                        second.first, second.second,
                        { if (second.third == null) onStartChat() else onOpenSection(second.third!!) },
                        Modifier.weight(1f),
                        count = if (second.third == null) chatCount else 0,
                    )
                } else {
                    Spacer(Modifier.weight(1f))
                }
            }
        }
    }
}

@Composable
private fun DestinationTile(
    label: String,
    icon: ImageVector,
    onTap: () -> Unit,
    modifier: Modifier = Modifier,
    count: Int = 0,
) {
    val colors = LocalTsColors.current
    Box(
        modifier
            .clip(RoundedCornerShape(cardRadiusDp))
            .background(colors.panel)
            .border(1.dp, colors.border, RoundedCornerShape(cardRadiusDp))
            .clickable { onTap() }
            .padding(Space.m),
        contentAlignment = Alignment.Center,
    ) {
        Column(
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(Space.s),
        ) {
            Box(Modifier.height(34.dp), contentAlignment = Alignment.Center) {
                Icon(icon, null, tint = colors.accent, modifier = Modifier.size(20.dp))
            }
            Text(
                label,
                style = TsType.caption.copy(fontWeight = androidx.compose.ui.text.font.FontWeight.Medium),
                color = colors.textPrimary,
                maxLines = 1,
            )
        }
        if (count > 0) {
            Text(
                "$count",
                style = TsType.numeric(12, androidx.compose.ui.text.font.FontWeight.SemiBold),
                color = colors.accent,
                modifier = Modifier.align(Alignment.TopEnd)
                    .background(colors.accentSoft, CircleShape)
                    .padding(horizontal = 6.dp, vertical = 1.dp),
            )
        }
    }
}

@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun LaunchTile(
    profile: ai.tokenstat.tokenstat.ui.logic.LaunchProfile,
    busy: Boolean,
    dimmed: Boolean,
    onTap: () -> Unit,
    onHide: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val colors = LocalTsColors.current
    // The hide lives on a long press like the iOS context menu, not as a
    // button inside the tile. The shell fallback is never hideable.
    var menu by remember { mutableStateOf(false) }
    Box(
        modifier
            .clip(RoundedCornerShape(cardRadiusDp))
            .background(
                if (busy) colors.accent.copy(alpha = 0.12f)
                else colors.panel.copy(alpha = if (dimmed) 0.4f else 1f),
            )
            .border(
                1.dp,
                if (busy) colors.accent else colors.border.copy(alpha = if (dimmed) 0.5f else 1f),
                RoundedCornerShape(cardRadiusDp),
            )
            .combinedClickable(
                enabled = !busy && !dimmed,
                onClick = onTap,
                onLongClick = if (profile.id == "shell") null else ({ menu = true }),
            )
            .padding(vertical = Space.m, horizontal = Space.s),
        contentAlignment = Alignment.Center,
    ) {
        Column(
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(Space.s),
            modifier = Modifier.alpha(if (busy) 1f else if (dimmed) 0.5f else 1f),
        ) {
            Box(Modifier.height(34.dp), contentAlignment = Alignment.Center) {
                if (busy) {
                    CircularProgressIndicator(Modifier.size(20.dp), strokeWidth = 2.dp, color = colors.accent)
                } else {
                    ai.tokenstat.tokenstat.ui.marks.HarnessMark(id = profile.harnessId ?: profile.id, size = 28.dp)
                }
            }
            Text(
                if (busy) "Starting…" else profile.name,
                style = TsType.caption.copy(fontWeight = androidx.compose.ui.text.font.FontWeight.Medium),
                color = if (dimmed) colors.textSecondary else colors.textPrimary,
                maxLines = 1,
            )
        }
        DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
            DropdownMenuItem(
                text = { Text("Remove from launcher") },
                onClick = { menu = false; onHide() },
            )
        }
    }
}

@Composable
private fun ExtraLaunchRow(
    profile: ai.tokenstat.tokenstat.ui.logic.LaunchProfile,
    offGrid: Boolean,
    installing: Boolean,
    installBusy: Boolean,
    onInstall: () -> Unit,
    onHide: () -> Unit,
    onShow: () -> Unit,
    onLaunch: () -> Unit,
) {
    val colors = LocalTsColors.current
    Row(
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(Space.s),
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(cardRadiusDp))
            .background(colors.panel)
            .padding(Space.m),
    ) {
        ai.tokenstat.tokenstat.ui.marks.HarnessMark(id = profile.harnessId ?: profile.id, size = 26.dp)
        Column(Modifier.weight(1f)) {
            Text(
                if (installing) "Installing…" else profile.name,
                style = TextStyle(fontSize = 13.sp, fontWeight = androidx.compose.ui.text.font.FontWeight.Medium),
                color = colors.textPrimary,
                maxLines = 1,
            )
            Text(
                if (!profile.installed) "Not installed" else "Hidden",
                style = TextStyle(fontSize = 11.sp),
                color = colors.textTertiary,
                maxLines = 1,
            )
        }
        if (!profile.installed && profile.installCommand != null) {
            TsAccentButton(label = "Install", small = true, enabled = !installBusy && !installing, onClick = onInstall)
        } else if (profile.installed && offGrid) {
            TsSecondaryButton(label = "Show", small = true, onClick = onShow)
        } else if (profile.installed) {
            TsSecondaryButton(label = "Start", small = true, onClick = onLaunch)
            TextButton(onClick = onHide) { Text("Hide") }
        }
    }
}

@Composable
private fun TodoSection(
    model: AppViewModel,
    peer: String,
    workspace: String,
    data: JsonElement?,
    error: String?,
    loading: Boolean,
    kindTask: Boolean,
    onChanged: () -> Unit,
    modifier: Modifier,
    folderName: String = "",
    hostLabel: String = "",
    onOpenSection: (String) -> Unit = {},
    protocol: Long? = null,
    onOpenTerminal: (String?) -> Unit = {},
) {
    val scope = rememberCoroutineScope()
    val cards = asObjects(data).filter { (it.str("kind") ?: "task") == if (kindTask) "task" else "note" }
    var composer by remember { mutableStateOf(false) }
    var resultCard by remember { mutableStateOf<JsonObject?>(null) }
    var boardFolder by remember { mutableStateOf<String?>(null) }
    var boardAll by remember { mutableStateOf(false) }
    if (boardFolder != null || boardAll) {
        BackHandler { boardFolder = null; boardAll = false }
        ai.tokenstat.tokenstat.ui.tasks.TaskBoardScreen(
            model = model,
            peer = peer,
            hostLabel = hostLabel,
            protocol = protocol,
            fixedFolder = if (boardAll) null else boardFolder,
            folderName = folderName,
            onOpenTerminal = { onOpenTerminal(it) },
            onOpenSection = { onOpenSection(it); boardFolder = null; boardAll = false; onChanged() },
            onBack = { boardFolder = null; boardAll = false; onChanged() },
        )
        return
    }

    LazyColumn(modifier, contentPadding = PaddingValues(bottom = TabBarChrome.contentBottomInset), verticalArrangement = Arrangement.spacedBy(Space.s)) {
        if (error != null) item { SectionError(error) }
        item {
            // Spaced: the label's own count sits at its trailing edge, so
            // with no gap the button covered it and the header read "TASKS 1".
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(Space.s),
            ) {
                SectionLabel(if (kindTask) "Tasks" else "Notes", cards.size, Modifier.weight(1f))
                TsAccentButton(
                    label = if (kindTask) "Add task" else "Add note",
                    icon = ActionIcon.Create.vector,
                    small = true,
                    onClick = { composer = true },
                )
            }
        }
        if (kindTask) {
            item {
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(Space.s)) {
                    TsSecondaryButton(label = "Open board", icon = ActionIcon.Layout.vector, small = true, onClick = { boardFolder = workspace })
                    TsSecondaryButton(label = "All tasks", icon = ActionIcon.Docs.vector, small = true, onClick = { boardAll = true })
                }
            }
        }
        if (loading && cards.isEmpty()) item { SkeletonRows(count = 3) }
        if (!loading && cards.isEmpty()) {
            item {
                EmptyState(
                    if (kindTask) Icons.Default.Checklist else Icons.AutoMirrored.Filled.Notes,
                    if (kindTask) "No tasks yet" else "No notes yet",
                    if (kindTask) {
                        "Cards captured here land on the Mac's board for this folder."
                    } else {
                        "A note is text kept beside the folder it belongs to."
                    },
                    art = { EmptyArt(if (kindTask) EmptyArtKind.Tasks else EmptyArtKind.Notes) },
                )
            }
        }
        itemsIndexed(cards) { _, card ->
            val id = card.str("id") ?: return@itemsIndexed
            // The host column for put-away cards is "archive"
            // (`TodoCard.isArchived`); "archived" never matches.
            val archived = (card.str("column") ?: "") == "archive"
            Column(
                Modifier
                    .fillMaxWidth()
                    .clip(RoundedCornerShape(cardRadiusDp))
                    .background(LocalTsColors.current.panel)
                    .padding(Space.m),
                verticalArrangement = Arrangement.spacedBy(Space.xs),
            ) {
                Text(
                    card.str("title") ?: "",
                    style = TextStyle(fontSize = 14.sp, fontWeight = androidx.compose.ui.text.font.FontWeight.Medium),
                    color = LocalTsColors.current.textPrimary,
                )
                card.str("notes")?.takeIf { it.isNotBlank() }?.let {
                    Text(it, style = TextStyle(fontSize = 12.sp), color = LocalTsColors.current.textSecondary, maxLines = 4)
                }
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(Space.s)) {
                    Text(
                        (card.str("column") ?: "backlog").replaceFirstChar(Char::uppercase),
                        style = TextStyle(fontSize = 11.sp, fontWeight = androidx.compose.ui.text.font.FontWeight.SemiBold),
                        color = LocalTsColors.current.accent,
                    )
                    Spacer(Modifier.weight(1f))
                    if (kindTask) {
                        TextButton(onClick = { resultCard = card }) { Text("View result") }
                    }
                    IconButton(onClick = {
                        scope.launch {
                            runCatching {
                                model.workspaceSection(peer, "todo.update", buildJsonObject {
                                    put("id", id)
                                    put("column", if (archived) "backlog" else "archive")
                                })
                            }
                            onChanged()
                        }
                    }) {
                        // Outlined and tinted like every other glyph here. The
                        // filled Material pair drew a solid black square in a
                        // row of thin accent marks.
                        Icon(
                            if (archived) ActionIcon.Restore.vector else ActionIcon.Archive.vector,
                            if (archived) "Restore" else "Archive",
                            tint = LocalTsColors.current.textSecondary,
                        )
                    }
                }
            }
        }
    }
    val opened = resultCard
    if (opened != null) {
        TaskResultDialog(
            model = model,
            peer = peer,
            workspace = workspace,
            title = opened.str("title") ?: "",
            backend = opened.str("backend") ?: "",
            column = (opened.str("column") ?: "").replaceFirstChar(Char::uppercase),
            folderName = folderName,
            hostLabel = hostLabel,
            onOpenSection = { resultCard = null; onOpenSection(it) },
            onDismiss = { resultCard = null },
        )
    }
    if (composer) {
        ComposerDialog(
            title = if (kindTask) "New task" else "New note",
            onDismiss = { composer = false },
            onSave = { text ->
                composer = false
                scope.launch {
                    runCatching {
                        model.workspaceSection(peer, "todo.create", buildJsonObject {
                            put("title", text)
                            put("kind", if (kindTask) "task" else "note")
                            put("notes", "")
                            put("column", "backlog")
                            put("backend", "")
                            put("workspaceId", workspace)
                            // A note is never delegated, so its budget is moot;
                            // a task gets the Mac's default three hours.
                            put("budgetSeconds", if (kindTask) 180 * 60 else 0)
                        })
                    }
                    onChanged()
                }
            },
        )
    }
}

@Composable
private fun ComposerDialog(title: String, onDismiss: () -> Unit, onSave: (String) -> Unit) {
    var text by remember { mutableStateOf("") }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(title) },
        text = { OutlinedTextField(text, { text = it }, minLines = 3, modifier = Modifier.fillMaxWidth()) },
        confirmButton = { Button(enabled = text.isNotBlank(), onClick = { onSave(text.trim()) }) { Text("Save") } },
        dismissButton = { TextButton(onClick = onDismiss) { Text("Cancel") } },
    )
}

@Composable
private fun WorkflowsSection(
    model: AppViewModel,
    peer: String,
    workspace: String,
    data: JsonElement?,
    error: String?,
    loading: Boolean,
    onChanged: () -> Unit,
    modifier: Modifier,
    folderName: String = "",
    hostLabel: String = "",
    protocol: Long? = null,
) {
    val scope = rememberCoroutineScope()
    val workflows = asObjects(data)
    var transcript by remember { mutableStateOf<String?>(null) }
    var workbench by remember { mutableStateOf(false) }
    if (workbench) {
        BackHandler { workbench = false }
        ai.tokenstat.tokenstat.ui.workflows.WorkflowsScreen(
            model = model,
            peer = peer,
            hostLabel = hostLabel,
            protocol = protocol,
            workspaceID = workspace,
            folderName = folderName,
            onBack = { workbench = false; onChanged() },
        )
        return
    }
    LazyColumn(modifier, contentPadding = PaddingValues(bottom = TabBarChrome.contentBottomInset), verticalArrangement = Arrangement.spacedBy(Space.s)) {
        if (error != null) item { SectionError(error) }
        item {
            TsSecondaryButton(label = "Open workflows", icon = ActionIcon.Layout.vector, small = true, onClick = { workbench = true })
        }
        if (loading && workflows.isEmpty()) item { SkeletonRows(count = 3) }
        if (!loading && workflows.isEmpty()) {
            item {
                EmptyState(
                    Icons.Default.AccountTree,
                    "No workflows yet",
                    "Workflows built on the Mac appear here. Run one from this device.",
                    art = { EmptyArt(EmptyArtKind.Workflows) },
                )
            }
        }
        itemsIndexed(workflows) { _, wf ->
            WorkflowCard(
                wf = wf,
                onRun = {
                    val id = wf.str("id") ?: return@WorkflowCard
                    scope.launch {
                        runCatching {
                            model.workspaceSection(peer, "workflow.run", buildJsonObject {
                                put("id", id)
                                put("input", "")
                                put("workspaceId", workspace)
                            })
                        }
                        onChanged()
                    }
                },
                onKill = { runId ->
                    scope.launch {
                        runCatching {
                            model.workspaceSection(peer, "workflow.kill", buildJsonObject { put("id", runId) })
                        }
                        onChanged()
                    }
                },
                onTranscript = { runId, nodeId ->
                    scope.launch {
                        runCatching {
                            val chunk = model.workspaceSection(peer, "workflow.transcript", buildJsonObject {
                                put("id", runId)
                                put("nodeId", nodeId)
                                put("offset", 0)
                            }) as? JsonObject
                            transcript = chunk?.str("text") ?: chunk?.str("content") ?: chunk.toString()
                        }.onFailure { transcript = it.message }
                    }
                },
            )
        }
    }
    if (transcript != null) {
        AlertDialog(
            onDismissRequest = { transcript = null },
            title = { Text("Transcript") },
            text = { Text(transcript.orEmpty(), style = TsType.mono(11)) },
            confirmButton = { TextButton(onClick = { transcript = null }) { Text("Close") } },
        )
    }
}

/// A workflow as a picture: named step capsules joined left-to-right, the
/// compact reading of `MiniGraph`/`WorkflowStepStrip` in a phone column.
@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun WorkflowCard(
    wf: JsonObject,
    onRun: () -> Unit,
    onKill: (String) -> Unit,
    onTranscript: (String, String) -> Unit,
) {
    val colors = LocalTsColors.current
    val steps = (wf["steps"] as? JsonArray)?.filterIsInstance<JsonObject>().orEmpty()
    val liveRun = wf.str("runId") ?: wf.str("liveRunId")
    Column(
        Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(cardRadiusDp))
            .background(colors.panel)
            .padding(Space.m),
        verticalArrangement = Arrangement.spacedBy(Space.s),
    ) {
        Text(
            wf.str("name") ?: wf.str("title") ?: "Workflow",
            style = TextStyle(fontSize = 14.sp, fontWeight = androidx.compose.ui.text.font.FontWeight.SemiBold),
            color = colors.textPrimary,
        )
        if (steps.isNotEmpty()) {
            FlowRow(
                horizontalArrangement = Arrangement.spacedBy(Space.xs),
                verticalArrangement = Arrangement.spacedBy(Space.xs),
            ) {
                steps.forEachIndexed { index, step ->
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        StepCapsule(step.str("label") ?: step.str("name") ?: "step")
                        if (index < steps.lastIndex) {
                            Text("→", color = colors.textTertiary, modifier = Modifier.padding(horizontal = 2.dp))
                        }
                    }
                }
            }
        }
        Row(horizontalArrangement = Arrangement.spacedBy(Space.s)) {
            TsAccentButton(label = "Run", small = true, onClick = onRun)
            if (liveRun != null) {
                TsSecondaryButton(label = "Stop", small = true, onClick = { onKill(liveRun) })
                steps.firstOrNull()?.str("id")?.let { node ->
                    TsSecondaryButton(label = "Transcript", small = true, onClick = { onTranscript(liveRun, node) })
                }
            }
        }
    }
}

@Composable
private fun StepCapsule(label: String) {
    Box(
        Modifier
            .clip(RoundedCornerShape(50))
            .background(LocalTsColors.current.accentSoft)
            .padding(horizontal = Space.s, vertical = 2.dp),
    ) {
        Text(
            label,
            style = TextStyle(fontSize = 11.sp, fontWeight = androidx.compose.ui.text.font.FontWeight.Medium),
            color = LocalTsColors.current.accent,
            maxLines = 1,
        )
    }
}

@Composable
private fun AutomationsSection(
    model: AppViewModel,
    peer: String,
    workspace: String,
    data: JsonElement?,
    error: String?,
    loading: Boolean,
    onChanged: () -> Unit,
    modifier: Modifier,
    folderName: String = "",
    hostLabel: String = "",
    protocol: Long? = null,
) {
    val scope = rememberCoroutineScope()
    val automations = asObjects(data)
    var workbench by remember { mutableStateOf(false) }
    if (workbench) {
        BackHandler { workbench = false }
        ai.tokenstat.tokenstat.ui.automations.AutomationsScreen(
            model = model,
            peer = peer,
            hostLabel = hostLabel,
            protocol = protocol,
            workspaceID = workspace,
            folderName = folderName,
            onBack = { workbench = false; onChanged() },
        )
        return
    }
    LazyColumn(modifier, contentPadding = PaddingValues(bottom = TabBarChrome.contentBottomInset), verticalArrangement = Arrangement.spacedBy(Space.s)) {
        if (error != null) item { SectionError(error) }
        item {
            TsSecondaryButton(label = "Open automations", icon = ActionIcon.Layout.vector, small = true, onClick = { workbench = true })
        }
        if (loading && automations.isEmpty()) item { SkeletonRows(count = 3) }
        if (!loading && automations.isEmpty()) {
            item {
                EmptyState(
                    Icons.Default.Bolt,
                    "No automations yet",
                    "Scheduled runs configured on the host appear here.",
                    art = { EmptyArt(EmptyArtKind.Automations) },
                )
            }
        }
        itemsIndexed(automations) { _, automation ->
            val colors = LocalTsColors.current
            val enabled = automation.bol("enabled")
            val id = automation.str("id") ?: return@itemsIndexed
            // The host sends the structured schedule from `ScheduleSpec`
            // (kind, weekday, weekdays); the ring reads those, like Apple's
            // `CadenceGlyph`, rather than a summary string the host never sends.
            val schedule = automation["schedule"] as? JsonObject
            val scheduleKind = schedule?.str("kind").orEmpty()
            val scheduleWeekday = schedule?.get("weekdays")?.jsonPrimitive?.intOrNull ?: 0
            val scheduleDay = schedule?.get("weekday")?.jsonPrimitive?.intOrNull ?: 0
            Column(
                Modifier
                    .fillMaxWidth()
                    .clip(RoundedCornerShape(cardRadiusDp))
                    .background(colors.panel)
                    .padding(Space.m),
                verticalArrangement = Arrangement.spacedBy(Space.xs),
            ) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    if (schedule != null) {
                        CadenceGlyph(
                            kind = scheduleKind,
                            weekdays = scheduleWeekday,
                            weekday = scheduleDay,
                            enabled = enabled,
                        )
                        Spacer(Modifier.width(Space.s))
                    }
                    Text(
                        automation.str("label") ?: automation.str("name") ?: "Automation",
                        style = TextStyle(fontSize = 14.sp, fontWeight = androidx.compose.ui.text.font.FontWeight.SemiBold),
                        color = colors.textPrimary,
                        modifier = Modifier.weight(1f),
                    )
                    Box(
                        Modifier
                            .clip(RoundedCornerShape(50))
                            .background(if (enabled) colors.accentSoft else colors.controlSeat)
                            .padding(horizontal = Space.s, vertical = 2.dp)
                            .clickable {
                                scope.launch {
                                    runCatching {
                                        model.workspaceSection(
                                            peer,
                                            if (enabled) "automation.disable" else "automation.enable",
                                            buildJsonObject { put("id", id) },
                                        )
                                    }
                                    onChanged()
                                }
                            },
                    ) {
                        Text(
                            if (enabled) "ON" else "OFF",
                            style = TextStyle(fontSize = 9.sp, fontWeight = androidx.compose.ui.text.font.FontWeight.Bold),
                            color = if (enabled) colors.accent else colors.controlGlyph,
                        )
                    }
                }
                TsAccentButton(
                    label = "Run",
                    small = true,
                    onClick = {
                        scope.launch {
                            runCatching {
                                model.workspaceSection(peer, "automation.run", buildJsonObject { put("id", id) })
                            }
                            onChanged()
                        }
                    },
                )
            }
        }
    }
}

@Composable
private fun BrowserSection(
    model: AppViewModel,
    peer: String,
    onOpen: (String, Int) -> Unit,
    modifier: Modifier,
) {
    val scope = rememberCoroutineScope()
    var portText by remember { mutableStateOf("3000") }
    var error by remember { mutableStateOf<String?>(null) }
    Column(modifier, verticalArrangement = Arrangement.spacedBy(Space.s)) {
        Text("Open a port on that computer in this device's browser.", color = LocalTsColors.current.textSecondary)
        OutlinedTextField(
            portText,
            { portText = it.filter(Char::isDigit).take(5) },
            label = { Text("Port") },
            singleLine = true,
            modifier = Modifier.fillMaxWidth(),
            leadingIcon = { Icon(Icons.Default.Language, null) },
        )
        error?.let { SectionError(it) }
        TsAccentButton(
            label = "Open",
            onClick = {
                val port = portText.toIntOrNull() ?: return@TsAccentButton
                scope.launch {
                    runCatching {
                        val opened = model.core(
                            "proxy.listen",
                            buildJsonObject {
                                put("peer", peer)
                                put("host", "127.0.0.1")
                                put("port", port)
                            },
                        ) as JsonObject
                        val url = opened.str("url") ?: "http://127.0.0.1:$port/"
                        onOpen(url, port)
                    }.onFailure { error = it.message }
                }
            },
        )
    }
}


/// The dashed `+` cell that opens the rest of the catalog. Port of
/// `ClientMoreTile`.
///
/// Dashed and half-toned on purpose: it sits in the same grid as the tiles
/// that launch something, and it has to read as "there are more of these"
/// rather than as another agent.
@Composable
private fun MoreLaunchTile(showing: Boolean, onTap: () -> Unit, modifier: Modifier = Modifier) {
    val colors = LocalTsColors.current
    val shape = RoundedCornerShape(cardRadiusDp)
    val stroke = colors.border.copy(alpha = 0.5f)
    Column(
        modifier
            .clip(shape)
            .background(colors.panel.copy(alpha = 0.4f))
            .drawBehind {
                drawRoundRect(
                    color = stroke,
                    cornerRadius = CornerRadius(cardRadiusDp.toPx(), cardRadiusDp.toPx()),
                    style = Stroke(
                        width = 1.dp.toPx(),
                        pathEffect = PathEffect.dashPathEffect(floatArrayOf(4.dp.toPx(), 3.dp.toPx())),
                    ),
                )
            }
            .clickable(onClick = onTap)
            .semantics {
                contentDescription = if (showing) "Hide extra tools" else "Show more tools"
            }
            .padding(vertical = Space.m),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(Space.s),
    ) {
        Box(Modifier.height(34.dp), contentAlignment = Alignment.Center) {
            Icon(
                ActionIcon.Create.vector,
                null,
                tint = colors.textTertiary,
                modifier = Modifier.size(18.dp),
            )
        }
        Text(
            if (showing) "Hide" else "More",
            style = TsType.caption.copy(fontWeight = FontWeight.Medium),
            color = colors.textSecondary,
            maxLines = 1,
        )
    }
}
