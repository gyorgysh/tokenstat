// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.workspace

import ai.tokenstat.tokenstat.ui.components.ForegroundEffect
import ai.tokenstat.tokenstat.AppViewModel
import ai.tokenstat.tokenstat.ui.chrome.TabBarChrome
import ai.tokenstat.tokenstat.ui.components.ActionIcon
import android.content.ClipData
import android.content.ClipboardManager
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.expandVertically
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.shrinkVertically
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalHapticFeedback
import ai.tokenstat.tokenstat.ui.components.EmptyState
import ai.tokenstat.tokenstat.ui.components.SectionLabel
import ai.tokenstat.tokenstat.ui.components.SectionTitle
import ai.tokenstat.tokenstat.ui.components.TsAccentButton
import ai.tokenstat.tokenstat.ui.components.TsCard
import ai.tokenstat.tokenstat.ui.components.TsProminentButton
import ai.tokenstat.tokenstat.ui.components.TsSecondaryButton
import ai.tokenstat.tokenstat.ui.components.TsType
import ai.tokenstat.tokenstat.ui.components.cardRadiusDp
import ai.tokenstat.tokenstat.ui.components.tsPanel
import ai.tokenstat.tokenstat.ui.logic.HostStatsFormat
import ai.tokenstat.tokenstat.ui.logic.RelativeClock
import ai.tokenstat.tokenstat.ui.logic.harnessName
import ai.tokenstat.tokenstat.ui.marks.AwakeDot
import ai.tokenstat.tokenstat.ui.marks.DeviceGlyph
import ai.tokenstat.tokenstat.ui.marks.EmptyArt
import ai.tokenstat.tokenstat.ui.marks.EmptyArtKind
import ai.tokenstat.tokenstat.ui.marks.FeatureMark
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
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.AccountTree
import androidx.compose.material.icons.filled.BatteryAlert
import androidx.compose.material.icons.filled.BatteryChargingFull
import androidx.compose.material.icons.filled.BatteryFull
import androidx.compose.material.icons.filled.BatteryStd
import androidx.compose.material.icons.filled.Bolt
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.ChatBubbleOutline
import androidx.compose.material.icons.filled.ChevronRight
import androidx.compose.material.icons.filled.DeveloperBoard
import androidx.compose.material.icons.filled.Folder
import androidx.compose.material.icons.filled.KeyboardArrowDown
import androidx.compose.material.icons.filled.KeyboardArrowUp
import androidx.compose.material.icons.filled.Memory
import androidx.compose.material.icons.filled.Terminal
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.scale
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlinx.coroutines.delay
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.doubleOrNull
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.jsonPrimitive
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

/// The same ahead, behind and diff figures as `folderSubtitle`, without the
/// branch name. For a row that already says which branch it is on: the folder
/// header repeated "main" beside "Branch main" and then said nothing about
/// what was actually waiting in it.
fun folderGitStats(folder: JsonObject): String? {
    val git = folder["git"] as? JsonObject ?: return null
    if (git.bol("isRepo") != true) return null
    val parts = mutableListOf<String>()
    val ahead = (git["ahead"] as? JsonPrimitive)?.intOrNull ?: 0
    val behind = (git["behind"] as? JsonPrimitive)?.intOrNull ?: 0
    if (ahead > 0) parts.add("⇡$ahead")
    if (behind > 0) parts.add("⇣$behind")
    val files = (git["files"] as? JsonArray)?.size ?: 0
    if (files > 0) {
        val added = (git["added"] as? JsonPrimitive)?.intOrNull ?: 0
        val removed = (git["removed"] as? JsonPrimitive)?.intOrNull ?: 0
        val partial = git.bol("partial") == true
        parts.add("+$added" + (if (removed > 0) " −$removed" else "") + (if (partial) "+" else ""))
    }
    return parts.joinToString(" ").takeIf { it.isNotEmpty() }
}

/// The power glyph for a stats reading: a bolt on the wall, a battery
/// draining with the percent, a charging battery while it fills.
fun powerIconVector(charging: Boolean, percent: Int?, power: String?): ImageVector {
    if (charging) return Icons.Default.BatteryChargingFull
    if (power == "ac") return Icons.Default.Bolt
    if (power == "battery") {
        val level = percent ?: 100
        if (level >= 90) return Icons.Default.BatteryFull
        if (level >= 35) return Icons.Default.BatteryStd
        return Icons.Default.BatteryAlert
    }
    return Icons.Default.Bolt
}

/// The same wording and colours the screen viewer uses, on a machine row.
/// Nothing renders for a path nobody has observed yet.
@Composable
fun ConnectionRouteMark(route: String?) {
    val label = HostStatsFormat.routeLabel(route) ?: return
    val colors = LocalTsColors.current
    Row(
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        Box(
            Modifier.size(7.dp).background(
                if (route == "direct") colors.success else colors.warning,
                CircleShape,
            ),
        )
        Text(label, style = TsType.caption, color = colors.textSecondary, maxLines = 1)
    }
}

/// Compact power, CPU and memory for a machine, refilled every 2.5 seconds
/// over the tunnel. Ported from `HostStatsStrip`: the power cell always
/// draws (an ellipsis while loading, n/a when the hop failed), CPU and
/// memory join only when the host measured them.
@Composable
fun HostStatsStrip(model: AppViewModel, peer: String, online: Boolean = true) {
    val colors = LocalTsColors.current
    var stats by remember(peer) { mutableStateOf<JsonObject?>(null) }
    var failed by remember(peer) { mutableStateOf(false) }
    var route by remember(peer) { mutableStateOf<String?>(null) }
    ForegroundEffect(peer, online) {
        if (!online) return@ForegroundEffect
        while (true) {
            runCatching { model.hostStats(peer) }
                .onSuccess { stats = it; failed = false }
                .onFailure {
                    android.util.Log.w("ts-stats", "host.stats failed for peer len=${peer.length}: $it")
                    // Matches iOS: failed tracks this hop, and the last good
                    // readings stay on screen either way.
                    failed = true
                }
            route = runCatching { model.peerRoute(peer) }.getOrNull()
            delay(2500)
        }
    }
    val charging = stats?.get("charging")?.jsonPrimitive?.booleanOrNull == true
    val percent = stats?.get("percent")?.jsonPrimitive?.intOrNull
    val power = stats?.get("power")?.jsonPrimitive?.contentOrNull
    Column(verticalArrangement = Arrangement.spacedBy(4.dp), modifier = Modifier.fillMaxWidth()) {
        Row(horizontalArrangement = Arrangement.spacedBy(Space.m)) {
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(4.dp),
            ) {
                Icon(
                    powerIconVector(charging, percent, power),
                    contentDescription = null,
                    modifier = Modifier.size(12.dp),
                    tint = colors.accent,
                )
                Text(
                    HostStatsFormat.powerLabel(charging, percent, power, failed, stats != null),
                    style = TsType.numeric(12),
                    color = colors.textSecondary,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
            }
            stats?.get("cpu")?.jsonPrimitive?.doubleOrNull?.let { cpu ->
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(4.dp),
                ) {
                    Icon(Icons.Default.Memory, contentDescription = null, modifier = Modifier.size(12.dp), tint = colors.accent)
                    Text(HostStatsFormat.cpuLabel(cpu), style = TsType.numeric(12), color = colors.textSecondary, maxLines = 1)
                }
            }
            val used = stats?.get("ramUsedBytes")?.jsonPrimitive?.longOrNull
            val total = stats?.get("ramTotalBytes")?.jsonPrimitive?.longOrNull
            if (used != null && total != null && total > 0) {
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(4.dp),
                ) {
                    Icon(Icons.Default.DeveloperBoard, contentDescription = null, modifier = Modifier.size(12.dp), tint = colors.accent)
                    Text(HostStatsFormat.ramLabel(used, total), style = TsType.numeric(12), color = colors.textSecondary, maxLines = 1)
                }
            }
        }
        ConnectionRouteMark(route)
    }
}

/// One host on the account: presence, name, and the way in. Port of
/// `hostCard` in `ClientWorkspacesView.swift`. No card-wide tap: the card
/// holds Connect/Disconnect, Open device and an Auto-connect toggle, and a
/// parent tap would fire for taps on those controls too.
@Composable
fun HostCard(
    model: AppViewModel,
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
    val peer = machine.str("publicIdentity").orEmpty()
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
                    overflow = TextOverflow.Ellipsis,
                )
                if (online == false) {
                    Text("Offline", style = MaterialTheme.typography.bodySmall, color = colors.textSecondary)
                } else if (connected) {
                    // Soft accent, like iOS `.bordered`: the card already
                    // says connected three ways, the button need not shout.
                    TsAccentButton(
                        label = "Disconnect",
                        icon = ActionIcon.Disconnect.vector,
                        small = true,
                        onClick = onDisconnect,
                    )
                } else {
                    TsProminentButton(
                        label = if (connecting) "Connecting…" else "Connect",
                        icon = ActionIcon.Connect.vector,
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
                    horizontalArrangement = Arrangement.spacedBy(4.dp),
                    modifier = Modifier.fillMaxWidth().clickable { onOpenDevice() },
                ) {
                    Text(
                        "Open device",
                        style = TsType.caption.copy(fontWeight = FontWeight.SemiBold),
                        color = colors.accent,
                    )
                    Icon(Icons.Default.ChevronRight, null, tint = colors.textTertiary, modifier = Modifier.size(12.dp))
                }
            }
            if (connected) {
                // What the machine is doing, rather than a sentence saying
                // it is connected. The row already says that: the dot is lit
                // and the button says Disconnect.
                HostStatsStrip(model, peer, online != false)
                // Per-host, on by default, same line-height as Disconnect.
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    modifier = Modifier
                        .padding(top = 4.dp)
                        .semantics { contentDescription = "Auto-connect $name" },
                ) {
                    Text(
                        "Auto-connect",
                        style = TsType.caption.copy(fontWeight = FontWeight.Medium),
                        color = colors.textSecondary,
                        modifier = Modifier.weight(1f),
                    )
                    Switch(
                        checked = autoConnect,
                        onCheckedChange = onAutoConnect,
                        modifier = Modifier.scale(0.82f),
                    )
                }
            }
        }
    }
}

/// Shared leading tile size for folder and session rows. Port of
/// `ClientRowMark`.
private const val ROW_MARK = 26

/// A path shortened in the middle, the way the Apple rows truncate one:
/// the start says which machine area, the end says which folder, and the
/// middle is what nobody needs. Compose only ellipsizes the end, so long
/// paths are cut by hand.
fun middleTruncate(text: String, maxChars: Int = 48): String {
    if (text.length <= maxChars) return text
    val head = (maxChars - 1) * 2 / 3
    val tail = maxChars - 1 - head
    return text.take(head) + "…" + text.takeLast(tail)
}

/// What protects a connection between this phone and a computer, in the
/// words and the numbers it actually runs on. Ported from
/// `ClientSecurityCard.swift`: a glass divider on the work list, not a
/// fourth device card, expanding to the keys a person can compare against
/// the other machine. The wording follows the privacy rule: the guarantee
/// is the boundary, not the read.
@Composable
fun SecurityCard(model: AppViewModel, peerKey: String?, peerName: String?) {
    val colors = LocalTsColors.current
    val context = LocalContext.current
    val haptic = LocalHapticFeedback.current
    var identity by remember { mutableStateOf<JsonObject?>(null) }
    var peer by remember { mutableStateOf<JsonObject?>(null) }
    var copied by remember { mutableStateOf<String?>(null) }
    var expanded by remember { mutableStateOf(false) }
    LaunchedEffect(peerKey) {
        // The effect restarts per peer, but a run already past its first
        // call is not stopped by the next one starting. Capture what this
        // run is for and refuse to publish into a different peer's card.
        val wanted = peerKey
        val got = runCatching { model.machineIdentity() }.getOrNull()
        if (wanted != peerKey) return@LaunchedEffect
        identity = got
        if (wanted == null) {
            peer = null
            return@LaunchedEffect
        }
        val found = runCatching { model.machinePeers() }.getOrNull()
            .orEmpty().mapNotNull { it as? JsonObject }
            .find { (it["key"] as? JsonPrimitive)?.contentOrNull == wanted }
        if (wanted != peerKey) return@LaunchedEffect
        peer = found
    }
    Column(
        Modifier.fillMaxWidth(),
        verticalArrangement = Arrangement.spacedBy(Space.s),
    ) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(Space.s),
            modifier = Modifier
                .fillMaxWidth()
                .heightIn(min = 56.dp)
                .clickable { expanded = !expanded }
                .semantics(mergeDescendants = true) { },
        ) {
            androidx.compose.material3.HorizontalDivider(
                color = colors.border,
                modifier = Modifier.weight(1f),
            )
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(6.dp),
                modifier = Modifier
                    .clip(CircleShape)
                    .background(colors.panel)
                    .border(1.dp, colors.border, CircleShape)
                    .padding(horizontal = Space.m, vertical = Space.s),
            ) {
                Icon(
                    ActionIcon.Security.vector,
                    contentDescription = null,
                    tint = colors.accent,
                    modifier = Modifier.size(12.dp),
                )
                Text(
                    "End to end encrypted",
                    style = TsType.caption.copy(fontWeight = FontWeight.Medium),
                    color = colors.textSecondary,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
                Icon(
                    if (expanded) Icons.Default.KeyboardArrowUp else Icons.Default.KeyboardArrowDown,
                    contentDescription = if (expanded) "Expanded" else "Collapsed",
                    tint = colors.textTertiary,
                    modifier = Modifier.size(12.dp),
                )
            }
            androidx.compose.material3.HorizontalDivider(
                color = colors.border,
                modifier = Modifier.weight(1f),
            )
        }
        AnimatedVisibility(
            visible = expanded,
            enter = fadeIn() + expandVertically(),
            exit = fadeOut() + shrinkVertically(),
        ) {
            Column(
                verticalArrangement = Arrangement.spacedBy(Space.s),
                modifier = Modifier.padding(horizontal = Space.s),
            ) {
                Text(
                    "A connection between your devices is encrypted on one and decrypted " +
                        "on the other, with keys that never leave them. The relay forwards " +
                        "the bytes and cannot read them, and neither can tokenstat. Your " +
                        "folders, terminals and agents are on your own computer.",
                    style = TsType.caption,
                    color = colors.textSecondary,
                )
                identity?.let {
                    SecurityKeyRow(
                        title = "This device",
                        words = (it["words"] as? JsonPrimitive)?.contentOrNull,
                        fingerprint = (it["fingerprint"] as? JsonPrimitive)?.contentOrNull.orEmpty(),
                        key = (it["key"] as? JsonPrimitive)?.contentOrNull.orEmpty(),
                        copied = copied,
                        onCopy = { value ->
                            val manager = context.getSystemService(ClipboardManager::class.java)
                            manager?.setPrimaryClip(ClipData.newPlainText("public key", value))
                            copied = value
                            haptic.performHapticFeedback(HapticFeedbackType.LongPress)
                        },
                    )
                }
                peer?.let {
                    val label = (it["label"] as? JsonPrimitive)?.contentOrNull.orEmpty()
                    SecurityKeyRow(
                        title = peerName ?: label.ifEmpty { "The other device" },
                        words = (it["words"] as? JsonPrimitive)?.contentOrNull,
                        fingerprint = (it["fingerprint"] as? JsonPrimitive)?.contentOrNull.orEmpty(),
                        key = (it["key"] as? JsonPrimitive)?.contentOrNull.orEmpty(),
                        copied = copied,
                        onCopy = { value ->
                            val manager = context.getSystemService(ClipboardManager::class.java)
                            manager?.setPrimaryClip(ClipData.newPlainText("public key", value))
                            copied = value
                            haptic.performHapticFeedback(HapticFeedbackType.LongPress)
                        },
                    )
                }
                Text(
                    "Noise XX handshake, X25519 keys, ChaCha20-Poly1305. " +
                        "Compare the words with the other device to be sure.",
                    style = TsType.caption.copy(fontSize = 10.sp),
                    color = colors.textTertiary,
                )
            }
        }
    }
}

@Composable
private fun SecurityKeyRow(
    title: String,
    words: String?,
    fingerprint: String,
    key: String,
    copied: String?,
    onCopy: (String) -> Unit,
) {
    val colors = LocalTsColors.current
    Column(
        verticalArrangement = Arrangement.spacedBy(1.dp),
        modifier = Modifier
            .fillMaxWidth()
            .heightIn(min = 44.dp)
            .clickable { onCopy(key) },
    ) {
        Text(title, style = TsType.caption, color = colors.textSecondary)
        Text(
            words ?: fingerprint,
            style = TsType.subheadline.copy(fontWeight = FontWeight.Medium),
            color = colors.textPrimary,
        )
        Row(
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(6.dp),
        ) {
            Text(
                middleTruncate(fingerprint),
                style = TsType.mono(12),
                color = colors.textTertiary,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            if (copied == key) {
                Text("copied", style = TsType.caption, color = colors.accent)
            }
        }
    }
}

/// One registered folder: its name, path, and git state. Port of
/// `ClientFolderRow`.
@Composable
fun WorkspaceFolderRow(folder: JsonObject, onOpen: () -> Unit) {
    val colors = LocalTsColors.current
    val git = folder["git"] as? JsonObject
    Row(
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(Space.s),
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(cardRadiusDp))
            .tsPanel()
            .clickable { onOpen() }
            .padding(Space.m),
    ) {
        Box(
            Modifier.size(ROW_MARK.dp).clip(RoundedCornerShape((ROW_MARK * 0.28f).dp))
                .background(colors.accent.copy(alpha = 0.12f)),
            contentAlignment = Alignment.Center,
        ) {
            Icon(Icons.Default.Folder, null, tint = colors.accent, modifier = Modifier.size((ROW_MARK * 0.5f).dp))
        }
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text(
                folder.str("name") ?: "Workspace",
                style = TsType.subheadline.copy(fontWeight = FontWeight.Medium),
                color = colors.textPrimary,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            Text(
                middleTruncate(folder.str("path").orEmpty()),
                style = TsType.caption,
                color = colors.textSecondary,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            folderSubtitle(folder)?.let { subtitle ->
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(4.dp),
                ) {
                    // The same branch the Mac sidebar draws. Without it the
                    // branch is a bare word in a line of numbers.
                    if (git?.bol("isRepo") == true && !git.str("branch").isNullOrEmpty()) {
                        Icon(
                            Icons.Default.AccountTree,
                            contentDescription = null,
                            tint = colors.accent,
                            modifier = Modifier.size(12.dp),
                        )
                    }
                    Text(
                        subtitle,
                        style = TsType.caption,
                        color = colors.accent,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                    )
                }
            }
        }
        Icon(Icons.Default.ChevronRight, null, tint = colors.textTertiary, modifier = Modifier.size(12.dp))
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
    Row(
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(Space.s),
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(cardRadiusDp))
            .tsPanel()
            .clickable { onOpen() }
            .padding(Space.m),
    ) {
        if (harness != null) {
            HarnessMark(id = harness, size = ROW_MARK.dp)
        } else {
            Box(
                Modifier.size(ROW_MARK.dp).clip(RoundedCornerShape((ROW_MARK * 0.28f).dp))
                    .background(colors.accent.copy(alpha = 0.12f)),
                contentAlignment = Alignment.Center,
            ) {
                Icon(Icons.Default.Terminal, null, tint = colors.accent, modifier = Modifier.size((ROW_MARK * 0.46f).dp))
            }
        }
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text(
                title,
                style = TsType.subheadline.copy(fontWeight = FontWeight.Medium),
                color = colors.textPrimary,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            Text(
                if (alive) "Running · ${middleTruncate(session.str("cwd").orEmpty())}" else "Stopped · tap to open",
                style = TsType.caption,
                color = colors.textSecondary,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
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
    Row(
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(Space.s),
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(cardRadiusDp))
            .tsPanel()
            .clickable { onOpen() }
            .padding(Space.m),
    ) {
        Box {
            HarnessMark(id = chat.str("backend").orEmpty(), size = 28.dp)
            if (needsAttention) {
                Canvas(Modifier.size(8.dp).align(Alignment.TopEnd).offset(x = 2.dp, y = (-2).dp)) {
                    drawCircle(color = colors.warning, radius = size.minDimension / 2f)
                    drawCircle(
                        color = colors.background,
                        radius = size.minDimension / 2f,
                        style = androidx.compose.ui.graphics.drawscope.Stroke(width = 2.dp.toPx()),
                    )
                }
            }
        }
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(3.dp)) {
            Text(
                chat.str("title") ?: "Chat",
                style = TsType.subheadline.copy(
                    fontWeight = if (needsAttention) FontWeight.SemiBold else FontWeight.Medium,
                ),
                color = colors.textPrimary,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(5.dp),
            ) {
                Text(folderName, style = TsType.caption, color = colors.textSecondary, maxLines = 1)
                (chat["lastMessageAtMs"] as? JsonPrimitive)?.longOrNull?.let { at ->
                    Text("·", style = TsType.caption, color = colors.textSecondary)
                    Text(RelativeClock.abbreviated(at), style = TsType.caption, color = colors.textSecondary, maxLines = 1)
                }
                if (needsAttention) {
                    Text("· Needs approval", style = TsType.caption, color = colors.warning, maxLines = 1)
                } else if (running) {
                    Text("· Working", style = TsType.caption, color = colors.accent, maxLines = 1)
                }
            }
        }
        Icon(ActionIcon.Disclosure.vector, null, tint = colors.textTertiary, modifier = Modifier.size(12.dp))
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
                                overflow = TextOverflow.Ellipsis,
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
    LazyColumn(contentPadding = PaddingValues(bottom = TabBarChrome.contentBottomInset), verticalArrangement = Arrangement.spacedBy(Space.s)) {
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
                        overflow = TextOverflow.Ellipsis,
                    )
                }
            }
        }
    }
}
