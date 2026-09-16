// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.workspace

import ai.tokenstat.tokenstat.ui.components.ActionIcon
import ai.tokenstat.tokenstat.ui.components.EmptyState
import ai.tokenstat.tokenstat.ui.components.SectionLabel
import ai.tokenstat.tokenstat.ui.components.TsAccentButton
import ai.tokenstat.tokenstat.ui.components.TsCard
import ai.tokenstat.tokenstat.ui.components.TsSecondaryButton
import ai.tokenstat.tokenstat.ui.logic.RelativeClock
import ai.tokenstat.tokenstat.ui.logic.harnessName
import ai.tokenstat.tokenstat.ui.marks.AwakeDot
import ai.tokenstat.tokenstat.ui.marks.DeviceGlyph
import ai.tokenstat.tokenstat.ui.marks.EmptyArt
import ai.tokenstat.tokenstat.ui.marks.EmptyArtKind
import ai.tokenstat.tokenstat.ui.marks.HarnessMark
import ai.tokenstat.tokenstat.ui.theme.LocalTsColors
import ai.tokenstat.tokenstat.ui.theme.Space
import android.content.Context
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.ChatBubbleOutline
import androidx.compose.material.icons.filled.ChevronRight
import androidx.compose.material.icons.filled.Folder
import androidx.compose.material.icons.filled.KeyboardArrowDown
import androidx.compose.material.icons.filled.KeyboardArrowUp
import androidx.compose.material.icons.filled.Terminal
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.longOrNull

/// One block of the connected-host Workspaces surface. Hosts stay outside
/// this list: they are how you get here, not cards to rearrange. Port of
/// `WorkspacesSection` in `WorkspacesLayout.swift`.
enum class WorkSection(val key: String, val label: String, val detail: String) {
    FOLDERS("folders", "Folders", "Projects on the connected computer"),
    RECENT_CHATS("recent_chats", "Recent chats", "Chats opened recently"),
    SESSIONS("sessions", "All sessions", "Terminals and agents running now"),
}

/// How this device arranges the three work blocks once a host is connected.
/// Device furniture, same idea as Home: the layout is not per host. Backed
/// by SharedPreferences the way the Apple client uses UserDefaults.
class WorkspaceLayoutStore(context: Context) {
    private val prefs = context.getSharedPreferences("tokenstat.workspaces.v1", Context.MODE_PRIVATE)

    fun order(): List<WorkSection> {
        val keys = prefs.getString("order", null)
            ?.split(",")?.mapNotNull { key -> WorkSection.entries.find { it.key == key } }
            .orEmpty()
        return (keys + WorkSection.entries.filter { it !in keys }).distinct()
    }

    fun hidden(): Set<WorkSection> =
        prefs.getStringSet("hidden", emptySet()).orEmpty()
            .mapNotNull { key -> WorkSection.entries.find { it.key == key } }.toSet()

    fun save(order: List<WorkSection>, hidden: Set<WorkSection>) {
        prefs.edit()
            .putString("order", order.joinToString(",") { it.key })
            .putStringSet("hidden", hidden.map { it.key }.toSet())
            .apply()
    }

    fun lastConnectedHost(): String? = prefs.getString("lastConnectedHost", null)

    fun setLastConnectedHost(peer: String?) {
        prefs.edit().putString("lastConnectedHost", peer).apply()
    }

    /// Missing means on. Nothing dials on its own until somebody has
    /// connected by hand once, because the auto path needs the last host and
    /// only a successful connection writes it.
    fun isAutoConnectEnabled(peer: String): Boolean =
        prefs.getBoolean("autoConnect.$peer", true)

    fun setAutoConnectEnabled(peer: String, enabled: Boolean) {
        prefs.edit().putBoolean("autoConnect.$peer", enabled).apply()
    }
}

/// Which harness a session command belongs to, port of
/// `harnessID(forCommand:)`. The last path component decides: the full
/// command is a path, and the brand is the binary.
fun harnessIdForCommand(command: String): String? = when (command.substringAfterLast("/")) {
    "claude" -> "claude_code"
    "codex" -> "codex"
    "opencode", "opencode2" -> "opencode"
    "grok" -> "grok"
    "copilot" -> "copilot"
    "cline" -> "cline"
    "openclaw" -> "openclaw"
    "muse" -> "muse"
    "pi" -> "pi"
    "zed" -> "zed"
    "agy" -> "antigravity"
    "agent", "cursor" -> "cursor"
    "hermes" -> "hermes"
    "kilocode", "kilo" -> "kilo"
    else -> null
}

/// One-line git summary: branch, ahead/behind, diff stat. Nil when there is
/// nothing worth saying. Port of `WorkspaceFolder.subtitle`.
fun folderSubtitle(folder: JsonObject): String? {
    if ((folder["exists"] as? JsonPrimitive)?.booleanOrNull == false) return "Folder missing"
    val git = folder["git"] as? JsonObject ?: return "Not a git repo"
    if (git.bol("isRepo") != true) return "Not a git repo"
    val parts = mutableListOf<String>()
    git.str("branch")?.takeIf { it.isNotEmpty() }?.let { parts.add(it) }
    val ahead = (git["ahead"] as? JsonPrimitive)?.intOrNull ?: 0
    val behind = (git["behind"] as? JsonPrimitive)?.intOrNull ?: 0
    if (ahead > 0) parts.add("⇡$ahead")
    if (behind > 0) parts.add("⇣$behind")
    val files = (git["files"] as? JsonArray)?.size ?: 0
    if (files > 0) {
        val added = (git["added"] as? JsonPrimitive)?.intOrNull ?: 0
        val removed = (git["removed"] as? JsonPrimitive)?.intOrNull ?: 0
        val partial = git.bol("partial") == true
        val stat = "+$added" + (if (removed > 0) " −$removed" else "") + (if (partial) "+" else "")
        parts.add(stat)
    }
    return parts.joinToString(" ").takeIf { it.isNotEmpty() }
}

/// One host on the account: presence, name, and the way in. Port of
/// `hostCard` in `ClientWorkspacesView.swift`. No card-wide tap: the card
/// holds Connect/Disconnect, Open device and an Auto-connect toggle, and a
/// parent tap would fire for taps on those controls too.
@Composable
fun HostCard(
    machine: JsonObject,
    name: String,
    connected: Boolean,
    connecting: Boolean,
    autoConnect: Boolean,
    onConnect: () -> Unit,
    onDisconnect: () -> Unit,
    onOpenDevice: (() -> Unit)?,
    onAutoConnect: (Boolean) -> Unit,
) {
    val colors = LocalTsColors.current
    val online = (machine["online"] as? JsonPrimitive)?.booleanOrNull
    val platform = machine.str("platform")
    val isHost = machine.str("kind") != "client"
    TsCard {
        Column(verticalArrangement = Arrangement.spacedBy(Space.s)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                AwakeDot(online = online)
                Spacer(Modifier.width(Space.s))
                DeviceGlyph(name = name, label = machine.str("label"), platform = platform, isHost = isHost)
                Spacer(Modifier.width(Space.s))
                Text(
                    name,
                    fontWeight = FontWeight.Medium,
                    color = colors.textPrimary,
                    modifier = Modifier.weight(1f),
                    maxLines = 1,
                )
                if (online == false) {
                    Text("Offline", style = MaterialTheme.typography.bodySmall, color = colors.textSecondary)
                } else if (connected) {
                    TsSecondaryButton(label = "Disconnect", small = true, onClick = onDisconnect)
                } else {
                    TsAccentButton(
                        label = if (connecting) "Connecting…" else "Connect",
                        small = true,
                        enabled = !connecting,
                        onClick = onConnect,
                    )
                }
            }
            // Opening the device used to hide behind a bare chevron, so the
            // card never said it could be entered. It says so now, as its
            // own row.
            if (onOpenDevice != null) {
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    modifier = Modifier.fillMaxWidth().clickable { onOpenDevice() },
                ) {
                    Text(
                        "Open device",
                        style = MaterialTheme.typography.bodySmall,
                        fontWeight = FontWeight.SemiBold,
                        color = colors.accent,
                    )
                    Icon(ActionIcon.Next.vector, null, tint = colors.accent, modifier = Modifier.size(14.dp))
                }
            }
            if (connected) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text(
                        "Auto-connect",
                        style = MaterialTheme.typography.bodySmall,
                        fontWeight = FontWeight.Medium,
                        color = colors.textSecondary,
                        modifier = Modifier.weight(1f),
                    )
                    Switch(checked = autoConnect, onCheckedChange = onAutoConnect)
                }
            }
        }
    }
}

/// One registered folder: its name, path, and git state. Port of
/// `ClientFolderRow`.
@Composable
fun WorkspaceFolderRow(folder: JsonObject, onOpen: () -> Unit) {
    val colors = LocalTsColors.current
    TsCard(Modifier.clickable { onOpen() }) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Box(
                Modifier.size(40.dp).clip(RoundedCornerShape(11.dp))
                    .background(colors.accent.copy(alpha = 0.12f)),
                contentAlignment = Alignment.Center,
            ) {
                Icon(Icons.Default.Folder, null, tint = colors.accent, modifier = Modifier.size(20.dp))
            }
            Spacer(Modifier.width(Space.m))
            Column(Modifier.weight(1f)) {
                Text(
                    folder.str("name") ?: "Workspace",
                    fontWeight = FontWeight.Medium,
                    color = colors.textPrimary,
                    maxLines = 1,
                )
                Text(
                    folder.str("path") ?: "",
                    style = MaterialTheme.typography.bodySmall,
                    color = colors.textSecondary,
                    maxLines = 1,
                )
                folderSubtitle(folder)?.let { subtitle ->
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Text(
                            subtitle,
                            style = MaterialTheme.typography.bodySmall,
                            color = colors.accent,
                            maxLines = 1,
                        )
                    }
                }
            }
            Icon(Icons.Default.ChevronRight, null, tint = colors.textSecondary)
        }
    }
}

/// One running session: the harness mark where the command names one, a
/// terminal tile otherwise. Port of `ClientSessionRow`.
@Composable
fun WorkspaceSessionRow(session: JsonObject, onOpen: () -> Unit) {
    val colors = LocalTsColors.current
    val command = session.str("command").orEmpty()
    val harness = harnessIdForCommand(command)
    val title = harness?.let { harnessName(it) } ?: command.substringAfterLast("/").ifEmpty { "Shell" }
    val alive = (session["alive"] as? JsonPrimitive)?.booleanOrNull != false
    TsCard(Modifier.clickable { onOpen() }) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            if (harness != null) {
                HarnessMark(id = harness, size = 40.dp)
            } else {
                Box(
                    Modifier.size(40.dp).clip(RoundedCornerShape(11.dp))
                        .background(colors.accent.copy(alpha = 0.12f)),
                    contentAlignment = Alignment.Center,
                ) {
                    Icon(Icons.Default.Terminal, null, tint = colors.accent, modifier = Modifier.size(20.dp))
                }
            }
            Spacer(Modifier.width(Space.m))
            Column(Modifier.weight(1f)) {
                Text(title, fontWeight = FontWeight.Medium, color = colors.textPrimary, maxLines = 1)
                Text(
                    if (alive) "Running · ${session.str("cwd").orEmpty()}" else "Stopped · tap to open",
                    style = MaterialTheme.typography.bodySmall,
                    color = colors.textSecondary,
                    maxLines = 1,
                )
            }
        }
    }
}

/// One recent chat: harness mark with an attention dot, title, and where it
/// lives. Port of `ClientRecentChatRow`. This device keeps no read receipts,
/// so the dot is attention only: unread tracking lives on the Apple client.
@Composable
fun WorkspaceChatRow(chat: JsonObject, folderName: String, onOpen: () -> Unit) {
    val colors = LocalTsColors.current
    val needsAttention = (chat["needsAttention"] as? JsonPrimitive)?.booleanOrNull == true
    val running = (chat["running"] as? JsonPrimitive)?.booleanOrNull == true
    TsCard(Modifier.clickable { onOpen() }) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Box {
                HarnessMark(id = chat.str("backend").orEmpty(), size = 28.dp)
                if (needsAttention) {
                    Canvas(Modifier.size(8.dp).align(Alignment.TopEnd).offset(x = 2.dp, y = (-2).dp)) {
                        drawCircle(color = colors.warning)
                    }
                }
            }
            Spacer(Modifier.width(Space.m))
            Column(Modifier.weight(1f)) {
                Text(
                    chat.str("title") ?: "Chat",
                    fontWeight = if (needsAttention) FontWeight.SemiBold else FontWeight.Medium,
                    color = colors.textPrimary,
                    maxLines = 1,
                )
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text(
                        folderName,
                        style = MaterialTheme.typography.bodySmall,
                        color = colors.textSecondary,
                    )
                    (chat["lastMessageAtMs"] as? JsonPrimitive)?.longOrNull?.let { at ->
                        Text(" · ${RelativeClock.label(at)}", style = MaterialTheme.typography.bodySmall, color = colors.textSecondary)
                    }
                    if (needsAttention) {
                        Text(" · Needs approval", style = MaterialTheme.typography.bodySmall, color = colors.warning)
                    } else if (running) {
                        Text(" · Working", style = MaterialTheme.typography.bodySmall, color = colors.accent)
                    }
                }
            }
            Icon(ActionIcon.Next.vector, null, tint = colors.textSecondary, modifier = Modifier.size(14.dp))
        }
    }
}

/// The screen a device sees until that computer lets it in. Opening the host
/// is somebody saying they want in, so the asking happens without a second
/// press; the button stays, for asking again once a request has gone stale.
@Composable
fun RequestAccessCard(
    hostName: String,
    requesting: Boolean,
    notice: String?,
    onRequest: () -> Unit,
) {
    val colors = LocalTsColors.current
    Column(verticalArrangement = Arrangement.spacedBy(Space.s)) {
        EmptyState(
            icon = ActionIcon.Approve.vector,
            title = "$hostName has not let this device in yet",
            message = "Folders, files, terminals and the agents running in them are only open to devices that computer has allowed. This screen opens on its own once the request is answered.",
            art = { EmptyArt(EmptyArtKind.WorkspaceAccess) },
            action = {
                TsAccentButton(
                    label = if (requesting) "Asking…" else "Request access",
                    icon = ActionIcon.Approve.vector,
                    enabled = !requesting,
                    onClick = onRequest,
                )
            },
        )
        notice?.let {
            TsCard {
                Text(it, style = MaterialTheme.typography.bodySmall, color = colors.textSecondary)
            }
        }
    }
}

/// A machine with no folders is a machine waiting to be given one, and both
/// ways to do that are here rather than described.
@Composable
fun EmptyWorkspacesCard(
    hostName: String,
    onChooseFolder: () -> Unit,
    onClone: () -> Unit,
) {
    val colors = LocalTsColors.current
    Column(verticalArrangement = Arrangement.spacedBy(Space.s)) {
        EmptyState(
            icon = Icons.Default.Folder,
            title = "Nothing to work on yet",
            message = "Give $hostName a folder. Choose one it already has, or clone a repository onto it.",
            art = { EmptyArt(EmptyArtKind.NoMachine) },
        )
        TextButton(onClick = onChooseFolder) {
            Icon(ActionIcon.Reveal.vector, null, tint = colors.accent, modifier = Modifier.size(16.dp))
            Spacer(Modifier.width(Space.xs))
            Text("Choose a folder", color = colors.accent)
        }
        TextButton(onClick = onClone) {
            Icon(ActionIcon.Download.vector, null, tint = colors.accent, modifier = Modifier.size(16.dp))
            Spacer(Modifier.width(Space.xs))
            Text("Clone a repository", color = colors.accent)
        }
    }
}

/// Chats live inside folders, so starting one means picking the folder
/// first. Port of `ClientFolderChooserSheet`.
@Composable
fun FolderChooserDialog(
    title: String,
    folders: List<JsonObject>,
    onPick: (JsonObject) -> Unit,
    onDismiss: () -> Unit,
) {
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(title) },
        text = {
            LazyColumn(verticalArrangement = Arrangement.spacedBy(Space.xs)) {
                items(folders) { folder ->
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        modifier = Modifier.fillMaxWidth()
                            .clip(RoundedCornerShape(12.dp))
                            .clickable { onPick(folder) }
                            .padding(Space.s),
                    ) {
                        Icon(Icons.Default.Folder, null, tint = LocalTsColors.current.accent)
                        Spacer(Modifier.width(Space.m))
                        Column(Modifier.weight(1f)) {
                            Text(folder.str("name") ?: "Workspace", fontWeight = FontWeight.Medium)
                            Text(
                                folder.str("path") ?: "",
                                style = MaterialTheme.typography.bodySmall,
                                color = LocalTsColors.current.textSecondary,
                                maxLines = 1,
                            )
                        }
                    }
                }
            }
        },
        confirmButton = {},
        dismissButton = { TextButton(onClick = onDismiss) { Text("Cancel") } },
    )
}

/// Order of Folders, Recent chats and All sessions on the connected machine.
/// Hosts stay above. Mirrors `HomeEditor`: presets, then visible rows with
/// up/down moves, then hidden rows.
@Composable
fun WorkspacesEditor(
    order: List<WorkSection>,
    hidden: Set<WorkSection>,
    onDone: (List<WorkSection>, Set<WorkSection>) -> Unit,
    onCancel: () -> Unit,
) {
    val colors = LocalTsColors.current
    var draftOrder by remember(order, hidden) { mutableStateOf(order) }
    var draftHidden by remember(order, hidden) { mutableStateOf(hidden) }
    val visible = draftOrder.filter { it !in draftHidden }
    fun move(section: WorkSection, delta: Int) {
        val index = visible.indexOf(section)
        if (index < 0) return
        val target = index + delta
        if (target !in visible.indices) return
        val rest = visible.toMutableList().also { it.removeAt(index) }
        rest.add(target, section)
        draftOrder = rest + draftOrder.filter { it in draftHidden }
    }
    LazyColumn(verticalArrangement = Arrangement.spacedBy(Space.s)) {
        item {
            WorkspacesLayoutPreview(sections = visible)
        }
        item {
            SectionLabel("Order of Folders, Recent chats and All sessions on the connected machine. Hosts stay above.")
        }
        item {
            Row(horizontalArrangement = Arrangement.spacedBy(Space.xs)) {
                listOf(
                    "Folders first" to listOf(WorkSection.FOLDERS, WorkSection.RECENT_CHATS, WorkSection.SESSIONS),
                    "Chats first" to listOf(WorkSection.RECENT_CHATS, WorkSection.FOLDERS, WorkSection.SESSIONS),
                    "Sessions first" to listOf(WorkSection.SESSIONS, WorkSection.FOLDERS, WorkSection.RECENT_CHATS),
                ).forEach { (label, preset) ->
                    if (visible == preset && draftHidden.isEmpty()) {
                        TsAccentButton(label = label, small = true, onClick = {})
                    } else {
                        TsSecondaryButton(
                            label = label,
                            small = true,
                            onClick = { draftOrder = preset; draftHidden = emptySet() },
                        )
                    }
                }
            }
        }
        item { SectionLabel("Visible") }
        items(visible) { section ->
            TsCard {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Column(Modifier.weight(1f)) {
                        Text(section.label, fontWeight = FontWeight.Medium, color = colors.textPrimary)
                        Text(section.detail, style = MaterialTheme.typography.bodySmall, color = colors.textSecondary)
                    }
                    TextButton(onClick = {
                        draftHidden = draftHidden + section
                    }) { Text("Hide", color = colors.accent) }
                    Icon(
                        Icons.Default.KeyboardArrowUp, "Move up",
                        tint = colors.textSecondary,
                        modifier = Modifier.clickable { move(section, -1) }.padding(8.dp),
                    )
                    Icon(
                        Icons.Default.KeyboardArrowDown, "Move down",
                        tint = colors.textSecondary,
                        modifier = Modifier.clickable { move(section, 1) }.padding(8.dp),
                    )
                }
            }
        }
        if (draftHidden.isNotEmpty()) {
            item { SectionLabel("Hidden") }
            items(draftOrder.filter { it in draftHidden }) { section ->
                TsCard {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Column(Modifier.weight(1f)) {
                            Text(section.label, fontWeight = FontWeight.Medium, color = colors.textPrimary)
                            Text(section.detail, style = MaterialTheme.typography.bodySmall, color = colors.textSecondary)
                        }
                        TextButton(onClick = { draftHidden = draftHidden - section }) {
                            Text("Show", color = colors.accent)
                        }
                    }
                }
            }
        }
        item {
            Spacer(Modifier.height(Space.s))
            Row(horizontalArrangement = Arrangement.spacedBy(Space.s)) {
                TsAccentButton(label = "Done", onClick = { onDone(draftOrder, draftHidden) })
                TextButton(onClick = onCancel) { Text("Cancel") }
            }
        }
    }
}

/// The connected host at a glance: one bar per visible block, in order.
/// Port of `WorkspacesLayoutPreview`.
@Composable
fun WorkspacesLayoutPreview(sections: List<WorkSection>) {
    val colors = LocalTsColors.current
    Column(
        Modifier.fillMaxWidth()
            .clip(RoundedCornerShape(10.dp))
            .background(colors.background)
            .border(1.dp, colors.border, RoundedCornerShape(10.dp))
            .padding(Space.s),
        verticalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        Box(
            Modifier.width(72.dp).height(8.dp)
                .clip(CircleShape)
                .background(colors.accent.copy(alpha = 0.35f)),
        )
        if (sections.isEmpty()) {
            Text(
                "Only hosts will show",
                style = MaterialTheme.typography.bodySmall,
                color = colors.textSecondary,
                modifier = Modifier.fillMaxWidth().padding(vertical = 12.dp),
            )
        } else {
            sections.forEach { section ->
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    modifier = Modifier.fillMaxWidth()
                        .height(20.dp)
                        .clip(RoundedCornerShape(5.dp))
                        .background(colors.accent.copy(alpha = 0.10f))
                        .padding(horizontal = 6.dp),
                ) {
                    Icon(
                        when (section) {
                            WorkSection.FOLDERS -> Icons.Default.Folder
                            WorkSection.RECENT_CHATS -> Icons.Default.ChatBubbleOutline
                            WorkSection.SESSIONS -> Icons.Default.Terminal
                        },
                        null,
                        tint = colors.accent,
                        modifier = Modifier.size(10.dp),
                    )
                    Spacer(Modifier.width(6.dp))
                    Text(
                        section.label,
                        style = androidx.compose.ui.text.TextStyle(fontSize = 9.sp, fontWeight = FontWeight.Medium),
                        color = colors.textSecondary,
                        maxLines = 1,
                    )
                }
            }
        }
    }
}
