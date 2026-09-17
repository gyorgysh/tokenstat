// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.workspace

import ai.tokenstat.tokenstat.ui.chrome.HideTopBar
import ai.tokenstat.tokenstat.ui.chrome.LocalTabBarPresence

import ai.tokenstat.tokenstat.AppViewModel
import ai.tokenstat.tokenstat.ui.components.Banner
import ai.tokenstat.tokenstat.ui.components.BannerSeverity
import ai.tokenstat.tokenstat.ui.components.TsSecondaryButton
import ai.tokenstat.tokenstat.ui.components.TsType
import ai.tokenstat.tokenstat.ui.components.cardRadiusDp
import ai.tokenstat.tokenstat.ui.components.tsPanel
import ai.tokenstat.tokenstat.ui.logic.HostContracts
import ai.tokenstat.tokenstat.ui.logic.HubCounts
import ai.tokenstat.tokenstat.ui.logic.HubCountsParser
import ai.tokenstat.tokenstat.ui.logic.HubSection
import ai.tokenstat.tokenstat.ui.logic.TunnelCopy
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.automirrored.filled.Chat
import androidx.compose.material.icons.automirrored.filled.MergeType
import androidx.compose.material.icons.automirrored.filled.Notes
import androidx.compose.material.icons.filled.AccountTree
import androidx.compose.material.icons.filled.Bolt
import androidx.compose.material.icons.filled.Checklist
import androidx.compose.material.icons.filled.ChevronRight
import androidx.compose.material.icons.filled.Difference
import androidx.compose.material.icons.filled.FolderOpen
import androidx.compose.material.icons.filled.History
import androidx.compose.material.icons.filled.Language
import androidx.compose.material.icons.filled.Terminal
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.launch
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.put

/// A failure that stays on screen until the person deals with it: the message,
/// a way to try again, and a way to put it away. Background refreshes never
/// clear one; only a successful retry or an explicit dismiss does. Port of the
/// `ClientErrorCard` contract.
@Composable
fun StickyErrorCard(
    message: String,
    modifier: Modifier = Modifier,
    onRetry: (() -> Unit)? = null,
    onDismiss: (() -> Unit)? = null,
) {
    Column(modifier, verticalArrangement = Arrangement.spacedBy(2.dp)) {
        Banner(message, BannerSeverity.DANGER)
        if (onRetry != null || onDismiss != null) {
            Row(horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                onRetry?.let {
                    TsSecondaryButton(label = "Try again", small = true, onClick = it)
                }
                onDismiss?.let {
                    TextButton(onClick = it) { Text("Dismiss") }
                }
            }
        }
    }
}

/// One hub row: the same word the Mac sidebar uses, the count when it is
/// news, and a chevron. Zero draws nothing, like iOS `ClientSectionRow`.
@Composable
fun HubSectionRow(
    section: HubSection,
    count: Int?,
    onOpen: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val colors = ai.tokenstat.tokenstat.ui.theme.LocalTsColors.current
    Row(
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(ai.tokenstat.tokenstat.ui.theme.Space.m),
        modifier = modifier
            .fillMaxWidth()
            .heightIn(min = 44.dp)
            .clip(RoundedCornerShape(cardRadiusDp))
            .tsPanel()
            .clickable { onOpen() }
            .padding(ai.tokenstat.tokenstat.ui.theme.Space.m),
    ) {
        Icon(
            hubIcon(section),
            contentDescription = null,
            tint = colors.accent,
            modifier = Modifier.size(22.dp),
        )
        Text(
            section.label,
            style = MaterialTheme.typography.titleSmall.copy(fontWeight = FontWeight.Medium),
            color = colors.textPrimary,
            modifier = Modifier.weight(1f),
            maxLines = 1,
        )
        if (count != null && count > 0) {
            Text(
                count.toString(),
                style = TsType.numeric(15),
                color = colors.textSecondary,
                maxLines = 1,
            )
        }
        Icon(
            Icons.Default.ChevronRight,
            contentDescription = "Open ${section.label}",
            tint = colors.textTertiary,
            modifier = Modifier.size(14.dp),
        )
    }
}

private fun hubIcon(section: HubSection): ImageVector = when (section) {
    HubSection.SESSIONS -> Icons.Default.Terminal
    HubSection.CHAT -> Icons.AutoMirrored.Filled.Chat
    HubSection.CHANGES -> Icons.Default.Difference
    HubSection.HISTORY -> Icons.Default.History
    HubSection.PULLS -> Icons.AutoMirrored.Filled.MergeType
    HubSection.TASKS -> Icons.Default.Checklist
    HubSection.NOTES -> Icons.AutoMirrored.Filled.Notes
    HubSection.WORKFLOWS -> Icons.Default.AccountTree
    HubSection.AUTOMATIONS -> Icons.Default.Bolt
    HubSection.FILES -> Icons.Default.FolderOpen
    HubSection.BROWSER -> Icons.Default.Language
}

/// One folder as its sections, port of iOS `ClientWorkspaceDetailView`'s
/// stacked list: a header card (machine, path, branch plus Switch) and one
/// full-width row per section, each opening its own full page.
///
/// Badges come from two calls, like iOS `reload()`: `workspace.summary` for
/// every badge at once, and `workspace.status` for the git state the header
/// and the Changes row need.
@Composable
fun WorkspaceHubMenu(
    model: AppViewModel,
    peer: String,
    hostName: String,
    folder: JsonObject,
    modifier: Modifier = Modifier,
    onOpenSection: (String) -> Unit = {},
) {
    val colors = ai.tokenstat.tokenstat.ui.theme.LocalTsColors.current
    val space = ai.tokenstat.tokenstat.ui.theme.Space
    val scope = rememberCoroutineScope()
    val workspace = folder.str("id") ?: ""
    var counts by remember(workspace) { mutableStateOf(HubCounts()) }
    var branch by remember(workspace) { mutableStateOf<String?>(null) }
    var isRepo by remember(workspace) { mutableStateOf(true) }
    var gitChanged by remember(workspace) { mutableStateOf<Int?>(null) }
    var cachedPulls by remember(workspace) { mutableStateOf<Int?>(null) }
    var error by remember(workspace) { mutableStateOf<String?>(null) }

    suspend fun reload() {
        val status = runCatching {
            model.workspaceSection(peer, "workspace.status", buildJsonObject { put("id", workspace) }) as? JsonObject
        }.getOrNull()
        val git = status?.get("git") as? JsonObject
        branch = git?.str("branch")
        isRepo = git?.bol("isRepo") ?: true
        gitChanged = (git?.get("files") as? kotlinx.serialization.json.JsonArray)?.size
        runCatching {
            model.workspaceSection(peer, "workspace.summary", buildJsonObject {})
        }.onSuccess { element ->
            val list = asObjects(element)
            val summary = HubCountsParser.findSummary(list, workspace)
            if (summary != null) {
                counts = HubCountsParser.parse(summary, gitChanged, cachedPulls)
                cachedPulls = counts.pulls.takeIf { summaryHasPulls(summary) } ?: cachedPulls
                error = null
            } else {
                // The host answered but does not have this folder, or is too
                // old to know the method. Badges stay as they were.
                counts = counts.copy(changes = gitChanged ?: counts.changes)
            }
        }.onFailure {
            // Every badge comes from this one call, so a failure leaves all
            // of them stale rather than one blank. Say so.
            error = TunnelCopy.display(it.message ?: "The request failed.", hostName)
        }
    }
    LaunchedEffect(peer, workspace) { reload() }

    Column(modifier.verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(space.m)) {
        if (error != null) {
            StickyErrorCard(
                message = error!!,
                onRetry = { scope.launch { reload() } },
                onDismiss = { error = null },
            )
        }
        Column(
            Modifier
                .fillMaxWidth()
                .clip(RoundedCornerShape(cardRadiusDp))
                .tsPanel()
                .padding(space.m),
            verticalArrangement = Arrangement.spacedBy(space.xs),
        ) {
            Text(
                hostName,
                style = TsType.caption,
                color = colors.textSecondary,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            Text(
                middleTruncate(folder.str("path").orEmpty()),
                style = TsType.caption,
                color = colors.textSecondary,
                maxLines = 2,
            )
            Spacer(Modifier.height(2.dp))
            BranchRow(
                model = model,
                peer = peer,
                workspace = workspace,
                hostLabel = hostName,
                branch = branch,
                isRepo = isRepo,
                onChanged = { scope.launch { reload() } },
                stats = folderGitStats(folder),
            )
        }
        HubSection.entries.forEach { section ->
            HubSectionRow(
                section = section,
                count = counts.forSection(section),
                onOpen = { onOpenSection(section.key) },
            )
        }
    }
}

private fun summaryHasPulls(summary: JsonObject): Boolean =
    summary["pulls"] is kotlinx.serialization.json.JsonPrimitive &&
        (summary["pulls"] as kotlinx.serialization.json.JsonPrimitive).contentOrNull != null

/// The folder hub with its own navigation: the section menu, then one full
/// page per section with a way back. Drop-in replacement for the chip-row
/// workspace detail.
@Composable
fun WorkspaceHub(
    model: AppViewModel,
    host: JsonObject,
    folder: JsonObject,
    modifier: Modifier = Modifier,
    initialSection: String? = null,
    onBack: (() -> Unit)? = null,
    onOpenTerminal: (String?) -> Unit = {},
    onOpenBrowser: (String, Int) -> Unit = { _, _ -> },
    onRecordChat: (String) -> Unit = {},
    initialChatId: String? = null,
    openConversationOnAppear: Boolean = false,
) {
    val colors = ai.tokenstat.tokenstat.ui.theme.LocalTsColors.current
    val space = ai.tokenstat.tokenstat.ui.theme.Space
    val peer = host.str("publicIdentity") ?: ""
    val workspace = folder.str("id") ?: ""
    val folderName = folder.str("name") ?: ""
    var openSection by rememberSaveable(folder.str("id"), initialSection) {
        mutableStateOf(initialSection?.let { HubSection.entries.find { s -> s.key == it || s.label == it }?.key })
    }
    // Each tap on a Sessions "start chat" tile is a fresh instruction to open
    // the conversation worth returning to, even on an already-open Chat page.
    var chatNonce by rememberSaveable(folder.str("id")) { mutableStateOf(0) }
    val section = openSection
    // A folder is a push, like the Apple clients push it: this screen owns
    // the header from here down, so the app toolbar steps aside.
    HideTopBar()
    val presence = LocalTabBarPresence.current
    Column(modifier) {
        // A screen inside the section can own the header instead, when it
        // has a truer title than the section's name.
        Row(
            verticalAlignment = Alignment.CenterVertically,
            modifier = if (presence.sectionHeaderHidden) Modifier.height(0.dp) else Modifier,
        ) {
            if (presence.sectionHeaderHidden) return@Row
            if (section != null) {
                IconButton(onClick = { openSection = null }) {
                    Icon(Icons.AutoMirrored.Filled.ArrowBack, "Back to $folderName")
                }
            } else if (onBack != null) {
                IconButton(onClick = onBack) { Icon(Icons.AutoMirrored.Filled.ArrowBack, "Back") }
            }
            Column(Modifier.weight(1f)) {
                Text(
                    if (section != null) HubSection.entries.find { it.key == section }?.label ?: section else folderName.ifBlank { "Workspace" },
                    style = MaterialTheme.typography.headlineSmall,
                    color = colors.textPrimary,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
                Text(
                    if (section != null) folderName else "Sections",
                    style = MaterialTheme.typography.bodySmall,
                    color = colors.textSecondary,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
            }
        }
        Spacer(Modifier.height(space.s))
        if (section == null) {
            WorkspaceHubMenu(
                model = model,
                peer = peer,
                hostName = host.str("label") ?: "Host",
                folder = folder,
                modifier = Modifier.weight(1f),
                onOpenSection = { openSection = it },
            )
        } else {
            WorkspaceSection(
                model = model,
                peer = peer,
                workspace = workspace,
                hostLabel = host.str("label") ?: "Host",
                section = section,
                protocol = HostContracts.protocolOf(host),
                folderName = folderName,
                modifier = Modifier.weight(1f),
                onOpenTerminal = onOpenTerminal,
                onOpenBrowser = onOpenBrowser,
                onOpenSection = { openSection = it },
                onChatOpened = onRecordChat,
                initialChatId = initialChatId,
                openConversationOnAppear = openConversationOnAppear,
                conversationNonce = chatNonce,
                onStartChat = { openSection = "Chat"; chatNonce += 1 },
            )
        }
    }
}
