// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.devices

import ai.tokenstat.tokenstat.ui.localization.L10n

import ai.tokenstat.tokenstat.ui.components.ForegroundEffect
import ai.tokenstat.tokenstat.ui.chrome.HideTopBar

import ai.tokenstat.tokenstat.AppViewModel
import ai.tokenstat.tokenstat.ClientState
import ai.tokenstat.tokenstat.ui.components.ActionIcon
import ai.tokenstat.tokenstat.ui.components.SectionTitle
import ai.tokenstat.tokenstat.ui.components.TsAccentButton
import ai.tokenstat.tokenstat.ui.components.TsCard
import ai.tokenstat.tokenstat.ui.components.TsSecondaryButton
import ai.tokenstat.tokenstat.ui.components.TsType
import ai.tokenstat.tokenstat.ui.components.cardPaddingDp
import ai.tokenstat.tokenstat.ui.components.cardRadiusDp
import ai.tokenstat.tokenstat.ui.chrome.TabBarChrome
import ai.tokenstat.tokenstat.ui.logic.DeviceCopy
import ai.tokenstat.tokenstat.ui.logic.DeviceUsage
import ai.tokenstat.tokenstat.ui.logic.HostContracts
import ai.tokenstat.tokenstat.ui.logic.HostStatsFormat
import ai.tokenstat.tokenstat.ui.logic.deviceSpendDetail
import ai.tokenstat.tokenstat.ui.logic.deviceWindowPhrase
import ai.tokenstat.tokenstat.ui.logic.friendlyError
import ai.tokenstat.tokenstat.ui.logic.money
import ai.tokenstat.tokenstat.ui.marks.AwakeDot
import ai.tokenstat.tokenstat.ui.marks.FeatureMark
import ai.tokenstat.tokenstat.ui.marks.formatRelativeDate
import ai.tokenstat.tokenstat.ui.screen.ScreenViewerScreen
import ai.tokenstat.tokenstat.ui.theme.LocalTsColors
import ai.tokenstat.tokenstat.ui.theme.Space
import ai.tokenstat.tokenstat.ui.workspace.CloneRepositoryScreen
import ai.tokenstat.tokenstat.ui.workspace.ConnectionRouteMark
import ai.tokenstat.tokenstat.ui.workspace.FolderPickerScreen
import ai.tokenstat.tokenstat.ui.workspace.SecurityCard
import ai.tokenstat.tokenstat.ui.workspace.powerIconVector
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.collectIsPressedAsState
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.ChevronRight
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.doubleOrNull
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.longOrNull
import kotlinx.serialization.json.put

/// One device: what it is, what it spent, and whether it can be reached.
/// Port of `ClientDeviceDetailView`, the clean card stack: theme surfaces
/// throughout, a section mark on every header, and no raw Material card
/// fills. Hosts only carry spend; phones and tablets never upload usage,
/// so a $0.00 card there would invent a number.
@Composable
fun DeviceDetailScreen(
    model: AppViewModel,
    state: ClientState,
    machine: JsonObject,
    thisId: String?,
    usage: DeviceUsage?,
    accountTotalMicros: Long,
    onBack: () -> Unit,
    onPlans: () -> Unit,
    onOpenWork: () -> Unit,
) {
    // A pushed screen with its own back and title. Leaving the app toolbar
    // above it stacked two headers, same as the folder hub did.
    HideTopBar()
    val colors = LocalTsColors.current
    val isThis = thisId != null && machine.string("id") == thisId
    val isHost = machine.string("kind") != "client"
    val peer = machine.string("publicIdentity")
    val online = machine.optBoolean("online")
    val hasKey = !peer.isNullOrEmpty()
    // Naming a device, in the row where the name is read. Empty is the undo
    // rather than an error: the machine goes back to naming itself.
    var renaming by remember { mutableStateOf(false) }
    var draft by remember { mutableStateOf("") }
    var savingName by remember { mutableStateOf(false) }
    var renameError by remember { mutableStateOf<String?>(null) }
    // The name this screen just set. `machine` is the copy this screen was
    // opened with, so without it a rename reads as having done nothing.
    var renamedTo by remember { mutableStateOf<String?>(null) }
    val currentLabel = renamedTo ?: machine.string("label")
    val currentName = DeviceCopy.displayName(currentLabel, machine.string("platform"), isHost)
    val detailScope = rememberCoroutineScope()
    fun saveName() {
        val id = machine.string("id")
        if (id.isNullOrEmpty()) {
            renameError = L10n.text("android.devicedetail.this_device_has_no_id_on_the_account_yet.5edab834")
            return
        }
        savingName = true
        detailScope.launch {
            runCatching {
                model.core(
                    "account.renameMachine",
                    buildJsonObject {
                        put("id", id)
                        put("name", draft.trim())
                    },
                )
            }.onSuccess {
                renamedTo = draft.trim().ifEmpty { null }
                renameError = null
                renaming = false
                model.refresh()
            }.onFailure {
                renameError = friendlyError(it.message).message
            }
            savingName = false
        }
    }
    var viewing by remember { mutableStateOf(false) }
    var folderFlow by remember { mutableStateOf<FolderFlow>(FolderFlow.None) }
    if (viewing && !peer.isNullOrEmpty()) {
        ScreenViewerScreen(
            model = model,
            peer = peer,
            hostLabel = currentName,
            tier = state.account?.string("tier"),
            onPlans = onPlans,
            onClose = { viewing = false },
        )
        return
    }
    if (folderFlow != FolderFlow.None && !peer.isNullOrEmpty()) {
        when (folderFlow) {
            FolderFlow.Choose -> FolderPickerScreen(
                model = model,
                peer = peer,
                hostName = currentName,
                onClose = { folderFlow = FolderFlow.None },
                // This screen keeps no folder list to refresh: closing is
                // the whole handling, the way iOS passes `{ _ in }`.
                onAdded = { folderFlow = FolderFlow.None },
            )
            FolderFlow.Clone -> CloneRepositoryScreen(
                model = model,
                peer = peer,
                hostLabel = currentName,
                onClose = { folderFlow = FolderFlow.None },
                onCloned = { folderFlow = FolderFlow.None },
            )
            FolderFlow.None -> Unit
        }
        return
    }
    Column(
        Modifier.fillMaxSize().verticalScroll(rememberScrollState())
            .padding(start = cardPaddingDp, top = cardPaddingDp, end = cardPaddingDp, bottom = cardPaddingDp + TabBarChrome.contentBottomInset),
        verticalArrangement = Arrangement.spacedBy(Space.m),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            IconButton(onClick = onBack) {
                Icon(Icons.AutoMirrored.Filled.ArrowBack, L10n.text("common.back"), tint = colors.textPrimary)
            }
            Text(currentName, style = MaterialTheme.typography.headlineSmall, color = colors.textPrimary)
        }
        if (isHost && !isThis) {
            SpendCard(usage = usage, accountTotalMicros = accountTotalMicros)
        }
        // Reachability, live readings and the two ways in, as one header.
        // This device and keyless machines keep the split cards instead.
        if (!isThis && !peer.isNullOrEmpty() && isHost) {
            HostHeaderCard(
                model = model,
                state = state,
                name = currentName,
                peer = peer,
                platform = machine.string("platform"),
                online = online,
                reach = DeviceCopy.reach(isThis, online, hasKey),
                onPlans = onPlans,
                onOpenWork = onOpenWork,
                onViewScreen = { viewing = true },
            )
            val connectedPeer by model.workspacesConnection.connectedPeer.collectAsStateWithLifecycle()
            if (connectedPeer != null && connectedPeer.equals(peer, ignoreCase = true)) {
                TsSecondaryButton(
                    label = L10n.text("common.disconnect"),
                    icon = ActionIcon.Disconnect.vector,
                    onClick = { model.workspacesConnection.disconnect() },
                )
            }
        } else {
            if (!isThis && !peer.isNullOrEmpty() && online == true) {
                HostStatsBar(model, peer)
            }
            ReachCard(isThis = isThis, online = online, hasKey = hasKey)
        }
        IdentityCard(
            machine = machine,
            isHost = isHost,
            currentLabel = currentLabel,
            renaming = renaming,
            onRenamingChange = { renaming = it },
            draft = draft,
            onDraftChange = { draft = it },
            savingName = savingName,
            renameError = renameError,
            onRenameErrorChange = { renameError = it },
            onSaveName = { saveName() },
        )
        // Which release that computer runs, and the button that moves it. A
        // server has no application to update and nobody at the keyboard, so
        // this is the only place it can be done from.
        if (!isThis && !peer.isNullOrEmpty() && isHost && online == true) {
            SoftwareCard(model = model, peer = peer)
        }
        if (!isThis && isHost && !peer.isNullOrEmpty()) {
            FoldersCard(onChoose = { folderFlow = FolderFlow.Choose }, onClone = { folderFlow = FolderFlow.Clone })
        }
        // The same explanation the workspaces tab carries, with this
        // machine's key beside it: somebody reading a device page is
        // asking what a connection to it actually is.
        SecurityCard(
            model = model,
            peerKey = if (!isThis && hasKey) peer else null,
            peerName = if (!isThis && hasKey) currentName else null,
        )
    }
}

/// Which folder flow the detail opened, if any. Both destinations run their
/// own connection and dismiss themselves.
private enum class FolderFlow { None, Choose, Clone }

/// This device's share of spend: the figure, the window it covers, and the
/// active days, events and account share under it. A share that has not
/// been fetched reads "n/a", never zero: reporting zero for something
/// unmeasured is inventing a number.
@Composable
private fun SpendCard(usage: DeviceUsage?, accountTotalMicros: Long) {
    val colors = LocalTsColors.current
    TsCard {
        Box(Modifier.fillMaxWidth()) {
            Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
                Text(
                    if (usage != null) money(usage.valueMicros) else L10n.text("android.devicedetail.n_a.a683c5c5"),
                    style = TsType.numeric(26, FontWeight.SemiBold),
                    color = colors.accent,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
                Text(
                    if (usage != null) {
                        L10n.text("android.devicedetail.at_api_list_price_0.32cb2c25", "${deviceWindowPhrase(usage.days)}")
                    } else {
                        L10n.text("android.devicedetail.this_device_s_share_has_not_been_fetched.6aa4e138")
                    },
                    style = TsType.caption,
                    color = colors.textSecondary,
                )
                if (usage != null) {
                    Text(
                        deviceSpendDetail(usage, accountTotalMicros),
                        style = TsType.caption,
                        color = colors.textSecondary,
                        modifier = Modifier.padding(top = 2.dp),
                    )
                }
            }
            // Top trailing, the way every other figure card carries its
            // mark. An overlay rather than a row, because the figure
            // under it must keep the whole width to fit.
            Box(Modifier.align(Alignment.TopEnd)) {
                FeatureMark(name = "mark_insights", size = 26)
            }
        }
    }
}

@Composable
private fun ReachCard(isThis: Boolean, online: Boolean?, hasKey: Boolean) {
    TsCard {
        SectionTitle(title = L10n.text("android.devicedetail.reach.2068b81b"), mark = "mark_host")
        Row(
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(Space.s),
        ) {
            AwakeDot(online = if (isThis) true else online)
            Text(
                DeviceCopy.reach(isThis, online, hasKey),
                style = TsType.subheadline,
                color = LocalTsColors.current.textSecondary,
            )
        }
    }
}

/// What another computer is doing, and the two ways in. Port of
/// `ClientHostHeader`: the awake dot and the name, the reach sentence, the
/// live readings while it is awake, and the Open work plus View screen
/// rows, all on one card.
@Composable
private fun HostHeaderCard(
    model: AppViewModel,
    state: ClientState,
    name: String,
    peer: String,
    platform: String?,
    online: Boolean?,
    reach: String,
    onPlans: () -> Unit,
    onOpenWork: () -> Unit,
    onViewScreen: () -> Unit,
) {
    val colors = LocalTsColors.current
    // Whether the host reports no display layer, so the row that opens the
    // screen viewer stays off rather than landing in its error state.
    // Probed live, with the account's platform string as the fallback when
    // the host cannot answer. Seeded from the platform so a Linux host
    // never flashes a row that only ever lands in an error state.
    var isHeadless by remember(peer, platform) { mutableStateOf(DeviceCopy.isHeadlessPlatform(platform)) }
    LaunchedEffect(peer) {
        val headless = runCatching {
            (model.workspaceSection(peer, "host.provisionStatus", buildJsonObject {}) as? JsonObject)
                ?.get("headless")?.jsonPrimitive?.booleanOrNull
        }.getOrNull()
        isHeadless = headless ?: DeviceCopy.isHeadlessPlatform(platform)
    }
    TsCard {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(Space.s),
        ) {
            AwakeDot(online = online)
            Column(verticalArrangement = Arrangement.spacedBy(2.dp), modifier = Modifier.weight(1f)) {
                Text(name, style = TsType.headline, color = colors.textPrimary)
                Text(reach, style = TsType.subheadline, color = colors.textSecondary)
            }
        }
        // Only for a host that is awake. A sleeping machine has no
        // readings, and a bar of dashes says less than no bar.
        if (online == true) {
            val (stats, failed, route) = rememberHostStats(model, peer)
            HostStatsPanel(stats = stats, failed = failed, route = route)
        }
        if (state.canRemote) {
            DeviceActionRow(
                title = L10n.text("android.devicedetail.open_work.536b133a"),
                subtitle = if (online == true) {
                    L10n.text("android.devicedetail.folders_terminals_and_sessions_on_this_com.d3339016")
                } else {
                    L10n.text("android.devicedetail.it_is_asleep_opening_this_will_wake_nothin.9373e7fd")
                },
                icon = ActionIcon.Reveal,
                onClick = onOpenWork,
            )
        } else {
            // The same seat and panel as the row it stands in for. An upsell
            // drawn as loose text beside a panelled row reads as a different
            // component rather than as the locked version of one.
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .heightIn(min = 44.dp)
                    .clip(RoundedCornerShape(cardRadiusDp))
                    .background(colors.panel)
                    .border(1.dp, colors.border, RoundedCornerShape(cardRadiusDp))
                    .padding(cardPaddingDp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(Space.m),
            ) {
                ActionSeat(icon = ActionIcon.Reveal)
                Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                    Text(
                        L10n.text("android.devicedetail.open_work.536b133a"),
                        style = TsType.subheadline,
                        fontWeight = FontWeight.Medium,
                        color = colors.textPrimary,
                    )
                    Text(
                        L10n.text("android.devicedetail.opening_folders_and_terminals_on_this_comp.995676db"),
                        style = TsType.caption,
                        color = colors.textSecondary,
                    )
                    TextLink(label = L10n.text("android.devicedetail.see_plans.d9898933"), icon = ActionIcon.Plans, onClick = onPlans)
                }
            }
        }
        if (!(isHeadless || DeviceCopy.isHeadlessPlatform(platform))) {
            DeviceActionRow(
                title = L10n.text("android.devicedetail.view_screen.56dea3b5"),
                subtitle = if ((state.account?.string("tier") ?: "").equals("legend", ignoreCase = true)) {
                    L10n.text("android.devicedetail.end_to_end_encrypted_from_this_device.54caee7b")
                } else {
                    L10n.text("android.devicedetail.requires_legend.ba9f23f7")
                },
                icon = ActionIcon.Preview,
                onClick = onViewScreen,
            )
        }
    }
}

/// A caption-sized accent link with its glyph, the reading of a tinted iOS
/// text button. The glyph and the word stay small, the target around them
/// does not.
@Composable
private fun TextLink(label: String, icon: ActionIcon, onClick: () -> Unit) {
    val colors = LocalTsColors.current
    Row(
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(4.dp),
        modifier = Modifier
            .heightIn(min = 44.dp)
            .clip(RoundedCornerShape(8.dp))
            .clickable(onClick = onClick)
            .padding(horizontal = 4.dp),
    ) {
        Icon(icon.vector, contentDescription = null, tint = colors.accent, modifier = Modifier.size(12.dp))
        Text(
            label,
            style = TsType.caption,
            fontWeight = FontWeight.SemiBold,
            color = colors.accent,
        )
    }
}

@Composable
private fun IdentityCard(
    machine: JsonObject,
    isHost: Boolean,
    currentLabel: String?,
    renaming: Boolean,
    onRenamingChange: (Boolean) -> Unit,
    draft: String,
    onDraftChange: (String) -> Unit,
    savingName: Boolean,
    renameError: String?,
    onRenameErrorChange: (String?) -> Unit,
    onSaveName: () -> Unit,
) {
    val colors = LocalTsColors.current
    TsCard {
        SectionTitle(title = L10n.text("android.devicedetail.what_this_is.45d2766e"), mark = "mark_device")
        if (renaming) {
            Text(L10n.text("android.devicedetail.name.dcd1d522"), style = TsType.caption, color = colors.textSecondary)
            OutlinedTextField(
                value = draft,
                onValueChange = onDraftChange,
                placeholder = { Text(L10n.text("android.devicedetail.name_this_device.ab6b2bc7")) },
                singleLine = true,
                modifier = Modifier.fillMaxWidth(),
            )
            Row(horizontalArrangement = Arrangement.spacedBy(Space.s)) {
                TsAccentButton(
                    label = if (savingName) L10n.text("android.devicedetail.saving.23e39291") else L10n.text("common.save"),
                    enabled = !savingName,
                    onClick = onSaveName,
                )
                TsSecondaryButton(
                    label = L10n.text("common.cancel"),
                    onClick = {
                        onRenamingChange(false)
                        onRenameErrorChange(null)
                    },
                )
            }
            Text(
                L10n.text("android.devicedetail.empty_puts_back_the_name_the_device_gives.9bb5bd6d"),
                style = TsType.caption,
                color = colors.textTertiary,
            )
        } else {
            Row(verticalAlignment = Alignment.CenterVertically) {
                DetailLine(
                    label = L10n.text("android.devicedetail.name.dcd1d522"),
                    value = currentLabel?.ifEmpty { null } ?: L10n.text("android.devicedetail.not_named_on_this_account.3695693d"),
                    modifier = Modifier.weight(1f),
                )
                Spacer(Modifier.width(Space.s))
                // Any device on the account, not only this phone. A Linux
                // server with nothing but the CLI on it has no other way
                // to be named.
                TextLink(
                    label = L10n.text("common.rename"),
                    icon = ActionIcon.Edit,
                    onClick = {
                        onDraftChange(currentLabel ?: "")
                        onRenamingChange(true)
                    },
                )
            }
        }
        renameError?.let { Text(it, style = TsType.caption, color = colors.danger) }
        machine.string("platform")?.let {
            DetailLine(label = L10n.text("android.devicedetail.what_it_runs.ba619d80"), value = it)
        }
        machine.string("id")?.let {
            DetailLine(label = L10n.text("android.devicedetail.device_id.4ad41656"), value = it)
        }
        // Hosts upload an archive, so their sync time is a product fact.
        // Phones never do: lastSyncAt there is not a fact.
        if (isHost) {
            DetailLine(
                label = L10n.text("android.devicedetail.last_sync.71967fca"),
                value = DeviceCopy.lastSync(true, machine.string("lastSyncAt")),
            )
        } else {
            formatRelativeDate(machine.string("lastSeenAt"))?.let { seen ->
                DetailLine(label = L10n.text("android.devicedetail.last_used.830ec7f8"), value = seen)
            }
        }
    }
}

/// A label and its value, stacked so a long value truncates in the middle
/// rather than pushing the label off. Device ids are long enough.
@Composable
private fun DetailLine(label: String, value: String, modifier: Modifier = Modifier) {
    val colors = LocalTsColors.current
    Column(modifier, verticalArrangement = Arrangement.spacedBy(1.dp)) {
        Text(label, style = TsType.caption, color = colors.textSecondary)
        SelectionContainer {
            Text(
                value,
                style = TsType.numeric(16),
                color = colors.textPrimary,
                maxLines = 2,
                overflow = TextOverflow.MiddleEllipsis,
            )
        }
    }
}

/// Giving a machine more work after setup. The empty machine is covered
/// from the workspaces tab; a machine that already has folders had no way
/// in from here. Both destinations run their own connection and dismiss
/// themselves, so this screen keeps no loading state for them.
@Composable
private fun FoldersCard(onChoose: () -> Unit, onClone: () -> Unit) {
    TsCard {
        SectionTitle(title = L10n.text("common.projects"), mark = "mark_folder")
        DeviceActionRow(
            title = L10n.text("android.devicedetail.choose_a_folder.5c71b8cd"),
            subtitle = L10n.text("android.devicedetail.register_a_folder_already_on_this_computer.31c7d112"),
            icon = ActionIcon.Reveal,
            onClick = onChoose,
        )
        DeviceActionRow(
            title = L10n.text("android.devicedetail.clone_a_repository.749e5d4d"),
            subtitle = L10n.text("android.devicedetail.run_git_on_this_computer_and_register_the.d6fc5a8e"),
            icon = ActionIcon.Download,
            onClick = onClone,
        )
    }
}

/// One row inside the folders card: a glyph, a title, a line of why, a
/// chevron. Port of `DeviceActionRow`: the glyph and the panel under it
/// are what say this is a button.
@Composable
private fun DeviceActionRow(title: String, subtitle: String, icon: ActionIcon, onClick: () -> Unit) {
    val colors = LocalTsColors.current
    val interactions = remember { MutableInteractionSource() }
    val pressed by interactions.collectIsPressedAsState()
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .heightIn(min = 44.dp)
            .clip(RoundedCornerShape(cardRadiusDp))
            .background(if (pressed) colors.rowHighlight else colors.panel)
            .border(1.dp, colors.border, RoundedCornerShape(cardRadiusDp))
            .clickable(
                interactionSource = interactions,
                indication = null,
                onClick = onClick,
            )
            .padding(cardPaddingDp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(Space.m),
    ) {
        ActionSeat(icon = icon)
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text(title, style = TsType.subheadline, fontWeight = FontWeight.Medium, color = colors.textPrimary)
            Text(subtitle, style = TsType.caption, color = colors.textSecondary)
        }
        Spacer(Modifier.width(Space.s))
        Icon(Icons.Default.ChevronRight, contentDescription = null, tint = colors.textTertiary)
    }
}

/// The glyph on its tinted tile, port of `ActionSeat`: accent at 12%,
/// cornered at 28%, the glyph at 44% in the accent.
@Composable
private fun ActionSeat(icon: ActionIcon, size: Int = 34) {
    val colors = LocalTsColors.current
    Box(
        Modifier
            .size(size.dp)
            .clip(RoundedCornerShape((size * 0.28f).dp))
            .background(colors.accent.copy(alpha = 0.12f)),
        contentAlignment = Alignment.Center,
    ) {
        Icon(
            icon.vector,
            contentDescription = null,
            modifier = Modifier.size((size * 0.44f).dp),
            tint = colors.accent,
        )
    }
}

/// Title plus plan fill above the device list, port of the `header` in
/// `ClientDevicesView`: the Devices mark, a trailing capacity chip, the
/// fill bar, and the remote line when the account cannot remote.
@Composable
fun DevicesHeader(machineCount: Int, machineLimit: Int?, canRemote: Boolean) {
    val colors = LocalTsColors.current
    val tint = capacityTint(machineCount, machineLimit)
    val planLine = if (!canRemote) {
        L10n.text("android.devicedetail.remote_control_is_on_patron_usage_from_eve.5dc0dfc8")
    } else {
        null
    }
    Column(
        verticalArrangement = Arrangement.spacedBy(Space.s),
        modifier = Modifier.semantics(mergeDescendants = true) {
            val parts = mutableListOf(L10n.text("common.devices"))
            if (machineLimit != null) parts.add(L10n.text("android.devicedetail.0_of_1_devices.bd266bff", "${machineCount}", "${machineLimit}"))
            else parts.add(if (machineCount == 1) "1 device" else L10n.text("android.devicedetail.0_devices.f3bf57aa", "${machineCount}"))
            if (planLine != null) parts.add(planLine)
            contentDescription = parts.joinToString(". ")
        },
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            SectionTitle(title = L10n.text("common.devices"), mark = "mark_device")
            Spacer(Modifier.weight(1f))
            Spacer(Modifier.width(Space.s))
            if (machineLimit != null) {
                Box(
                    Modifier
                        .clip(RoundedCornerShape(50))
                        .background(tint.copy(alpha = 0.12f))
                        .padding(horizontal = 10.dp, vertical = 5.dp),
                ) {
                    Text(
                        "$machineCount / $machineLimit",
                        style = TsType.caption,
                        fontWeight = FontWeight.SemiBold,
                        color = tint,
                    )
                }
            } else {
                Box(
                    Modifier
                        .clip(RoundedCornerShape(50))
                        .background(colors.accent.copy(alpha = 0.10f))
                        .padding(horizontal = 10.dp, vertical = 5.dp),
                ) {
                    Text(
                        if (machineCount == 1) L10n.text("android.devicedetail.1_device.b97db9d5") else L10n.text("android.devicedetail.0_devices.f3bf57aa", "${machineCount}"),
                        style = TsType.caption,
                        fontWeight = FontWeight.Medium,
                        color = colors.textSecondary,
                    )
                }
            }
        }
        if (machineLimit != null && machineLimit > 0) {
            val fill = (machineCount.toFloat() / machineLimit).coerceIn(0f, 1f)
            Box(
                Modifier
                    .fillMaxWidth()
                    .height(4.dp)
                    .clip(RoundedCornerShape(50))
                    .background(colors.accent.copy(alpha = 0.12f)),
            ) {
                Box(
                    Modifier
                        .fillMaxWidth(fill)
                        .height(4.dp)
                        .clip(RoundedCornerShape(50))
                        .background(tint.copy(alpha = 0.7f)),
                )
            }
        }
        planLine?.let {
            Text(it, style = TsType.caption, color = colors.textSecondary)
        }
    }
}

/// Plan fill as a tint: the accent until the account is nearly full,
/// warning past four fifths, danger at the limit.
@Composable
private fun capacityTint(used: Int, limit: Int?): Color {
    val colors = LocalTsColors.current
    if (limit == null || limit <= 0) return colors.accent
    val ratio = used.toDouble() / limit
    return when {
        ratio >= 1 -> colors.danger
        ratio >= 0.8 -> colors.warning
        else -> colors.accent
    }
}

/// The live readings behind the stats bar: the last answer, whether the
/// hop failed, and the observed route. Polled every 2.5 seconds while the
/// caller is composed, like `HostStatsBar`.
@Composable
private fun rememberHostStats(model: AppViewModel, peer: String): Triple<JsonObject?, Boolean, String?> {
    var stats by remember(peer) { mutableStateOf<JsonObject?>(null) }
    var failed by remember(peer) { mutableStateOf(false) }
    var route by remember(peer) { mutableStateOf<String?>(null) }
    ForegroundEffect(peer) {
        runCatching { model.prepareHost(peer, L10n.text("android.devicedetail.computer.76ed42d2")) }
        while (true) {
            runCatching { model.hostStats(peer) }
                .onSuccess { stats = it; failed = false }
                .onFailure { if (stats == null) failed = true }
            // Re-read every poll, like the readings: the tunnel is often
            // still opening on the first pass, and a route read once stays
            // missing forever.
            route = runCatching { model.peerRoute(peer) }.getOrNull()
                ?.takeIf { it == "direct" || it == "relay" } ?: route
            delay(2500)
        }
    }
    return Triple(stats, failed, route)
}

/// Power, CPU and memory after a hop to an awake host. Missing readings
/// stay off the bar rather than drawing as zero.
@Composable
fun HostStatsBar(model: AppViewModel, peer: String) {
    val (stats, failed, route) = rememberHostStats(model, peer)
    TsCard {
        HostStatsCells(stats = stats, failed = failed, route = route)
    }
}

/// The readings nested inside the host header: the same cells on the same
/// panel the action rows sit on, so the rows and the readings above them
/// are one family.
@Composable
private fun HostStatsPanel(stats: JsonObject?, failed: Boolean, route: String?) {
    val colors = LocalTsColors.current
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(cardRadiusDp))
            .background(colors.panel)
            .border(1.dp, colors.border, RoundedCornerShape(cardRadiusDp))
            .padding(cardPaddingDp),
        verticalArrangement = Arrangement.spacedBy(Space.s),
    ) {
        HostStatsCells(stats = stats, failed = failed, route = route)
    }
}

@Composable
private fun HostStatsCells(stats: JsonObject?, failed: Boolean, route: String?) {
    val colors = LocalTsColors.current
    // Missing readings stay off the bar rather than drawing as zero.
    val charging = stats?.bool("charging") == true
    val power = HostStatsFormat.powerLabel(
        charging = charging,
        percent = stats?.int("percent"),
        power = stats?.string("power"),
        failed = failed,
        hadStats = stats != null,
    )
    val cpu = stats?.doubleOrNull("cpu")
    val ramUsed = stats?.long("ramUsedBytes")
    val ramTotal = stats?.long("ramTotalBytes")
    Row(
        Modifier.fillMaxWidth().heightIn(min = 44.dp),
        horizontalArrangement = Arrangement.spacedBy(Space.m),
    ) {
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(6.dp),
            ) {
                Icon(
                    powerIconVector(charging, stats?.int("percent"), stats?.string("power")),
                    contentDescription = null,
                    modifier = Modifier.size(14.dp),
                    tint = colors.accent,
                )
                Text(power, style = TsType.numeric(16), color = colors.textPrimary, maxLines = 1)
            }
            Text(L10n.text("android.devicedetail.power.848e9656"), style = TsType.caption, color = colors.textSecondary)
        }
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            if (cpu != null) {
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(6.dp),
                ) {
                    StatMeter(fraction = cpu)
                    Text(
                        HostStatsFormat.cpuLabel(cpu),
                        style = TsType.numeric(16),
                        color = colors.textPrimary,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                    )
                }
            } else {
                Text(L10n.text("android.devicedetail.n_a.a683c5c5"), style = TsType.numeric(16), color = colors.textTertiary)
            }
            Text(L10n.text("android.devicedetail.cpu.db9a4c7d"), style = TsType.caption, color = colors.textSecondary)
        }
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            if (ramUsed != null && ramTotal != null && ramTotal > 0) {
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(6.dp),
                ) {
                    StatMeter(fraction = ramUsed.toDouble() / ramTotal)
                    // "26 / 32 GB" does not fit the column at 16, so the
                    // figure shrinks toward 11 until it does, the way the
                    // Apple cell's minimumScaleFactor does.
                    var ramSize by remember(ramUsed, ramTotal) { mutableStateOf(16) }
                    Text(
                        HostStatsFormat.ramLabel(ramUsed, ramTotal),
                        style = TsType.numeric(ramSize),
                        color = colors.textPrimary,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                        onTextLayout = { if (it.hasVisualOverflow && ramSize > 11) ramSize -= 1 },
                    )
                }
            } else {
                Text(L10n.text("android.devicedetail.n_a.a683c5c5"), style = TsType.numeric(16), color = colors.textTertiary)
            }
            Text(L10n.text("android.devicedetail.memory.c3963aed"), style = TsType.caption, color = colors.textSecondary)
        }
    }
    ConnectionRouteMark(route)
    Text(
        L10n.text("android.devicedetail.read_from_this_computer_over_the_encrypted.2e1e5e7b"),
        style = TsType.caption,
        color = colors.textTertiary,
    )
}

/// The 28 by 6 meter beside a CPU or memory figure, port of the capsule in
/// `HostStatsBar`: accent at 12% under accent at 70%, never narrower than
/// two points so a sliver of load still reads.
@Composable
private fun StatMeter(fraction: Double) {
    val colors = LocalTsColors.current
    Box(
        Modifier
            .size(28.dp, 6.dp)
            .clip(RoundedCornerShape(50))
            .background(colors.accent.copy(alpha = 0.12f)),
    ) {
        Box(
            Modifier
                .width((28f * fraction.toFloat().coerceIn(0f, 1f)).coerceAtLeast(2f).dp)
                .height(6.dp)
                .clip(RoundedCornerShape(50))
                .background(colors.accent.copy(alpha = 0.7f)),
        )
    }
}

/// Which release a machine is on, and the one button that moves it. Port
/// of `HostUpdateCard`, peer only: a phone is never a host. One check, not
/// a poll: a published release does not change fast enough to ask about on
/// a timer.
@Composable
private fun SoftwareCard(model: AppViewModel, peer: String) {
    val colors = LocalTsColors.current
    val scope = rememberCoroutineScope()
    var phase by remember(peer) { mutableStateOf<UpdatePhase>(UpdatePhase.Checking) }
    var state by remember(peer) { mutableStateOf<JsonObject?>(null) }
    var applied by remember(peer) { mutableStateOf<JsonObject?>(null) }
    var supported by remember(peer) { mutableStateOf(true) }
    var retry by remember(peer) { mutableStateOf(0) }
    suspend fun probeVersion(): Long? = runCatching {
        (model.workspaceSection(peer, "protocol", buildJsonObject {}) as? JsonObject)?.let {
            it.string("protocolVersion")?.toLongOrNull()
                ?: it.string("protocol")?.toLongOrNull()
                ?: HostContracts.protocolOf(it)
        }
    }.getOrNull()
    fun load() {
        scope.launch {
            phase = UpdatePhase.Checking
            applied = null
            runCatching { model.prepareHost(peer, L10n.text("android.devicedetail.computer.76ed42d2")) }
            // A host older than these methods must not be discovered by
            // showing somebody its `unknown method` error.
            val version = probeVersion() ?: run {
                // The tunnel session is often still coming up behind the
                // stats bar's own prepare, which fires in the same frame.
                // One patient retry beats hiding the card for a race.
                delay(3000)
                probeVersion()
            }
            supported = version != null && HostContracts.supportsHostUpdate(version)
            if (!supported) return@launch
            runCatching {
                model.workspaceSection(peer, "host.updateCheck", buildJsonObject {}) as? JsonObject
            }.onSuccess {
                state = it
                phase = UpdatePhase.Ready
            }.onFailure {
                phase = UpdatePhase.Failed(friendlyError(it.message).message)
            }
        }
    }
    fun apply(restartNow: Boolean) {
        scope.launch {
            phase = UpdatePhase.Installing
            runCatching {
                model.workspaceSection(
                    peer,
                    "host.updateApply",
                    buildJsonObject { put("restartNow", restartNow) },
                ) as? JsonObject
            }.onSuccess {
                applied = it
                phase = UpdatePhase.Done
            }.onFailure {
                // A restart the caller asked for takes the connection with
                // it, and that is the update working. Saying it failed
                // would be wrong, and would invite a second attempt at
                // something already done.
                if (restartNow) {
                    applied = buildJsonObject { put("restarting", true) }
                    phase = UpdatePhase.Done
                } else {
                    phase = UpdatePhase.Failed(friendlyError(it.message).message)
                }
            }
        }
    }
    LaunchedEffect(peer, retry) { load() }
    if (!supported) return
    TsCard {
        SectionTitle(title = L10n.text("android.devicedetail.software.9b3289a3"), mark = "mark_sync")
        when (val p = phase) {
            UpdatePhase.Checking -> Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(Space.s),
            ) {
                CircularProgressIndicator(modifier = Modifier.size(14.dp), strokeWidth = 2.dp, color = colors.accent)
                Text(L10n.text("android.devicedetail.looking_for_a_newer_release.7e1ada06"), style = TsType.caption, color = colors.textSecondary)
            }
            UpdatePhase.Ready -> state?.let { UpdateReadyBody(it) }
            UpdatePhase.Installing -> Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(Space.s),
            ) {
                CircularProgressIndicator(modifier = Modifier.size(14.dp), strokeWidth = 2.dp, color = colors.accent)
                Text(
                    L10n.text("android.devicedetail.downloading_checking_and_installing_this_t.c0e97360"),
                    style = TsType.caption,
                    color = colors.textSecondary,
                )
            }
            UpdatePhase.Done -> applied?.let { UpdateDoneBody(it) }
            is UpdatePhase.Failed -> Text(p.reason, style = TsType.caption, color = colors.danger)
        }
        val s = state
        if (s != null && phase != UpdatePhase.Installing && phase != UpdatePhase.Checking) {
            Row(horizontalArrangement = Arrangement.spacedBy(Space.s)) {
                // `state` is the answer from before an install, so after one
                // it still names a newer version. Offering Install again
                // there would be offering work that is already done.
                if (phase == UpdatePhase.Done) {
                    if (applied?.bool("restartPending") == true && s.bool("canRestart")) {
                        TsAccentButton(label = L10n.text("android.devicedetail.restart.6b983a81"), icon = ActionIcon.Refresh.vector, onClick = { apply(true) })
                    }
                } else if (s.bool("restartPending")) {
                    // The only thing left is the restart, and it ends
                    // whatever that machine is running, so it is never
                    // automatic here.
                    if (s.bool("canRestart")) {
                        TsAccentButton(label = L10n.text("android.devicedetail.restart.6b983a81"), icon = ActionIcon.Refresh.vector, onClick = { apply(true) })
                    }
                } else if (s.bool("newer") && !s.bool("appManaged")) {
                    TsAccentButton(label = L10n.text("android.devicedetail.install.569ca49f"), icon = ActionIcon.Download.vector, onClick = { apply(false) })
                } else if (s.bool("appManaged") && s.bool("newer")) {
                    TsAccentButton(label = L10n.text("android.devicedetail.fetch.cd7d61bf"), icon = ActionIcon.Download.vector, onClick = { apply(false) })
                }
                TsSecondaryButton(label = L10n.text("android.devicedetail.check_again.fb7099ad"), icon = ActionIcon.Refresh.vector, onClick = { retry += 1 })
            }
        }
    }
}

/// What the software card is doing, rather than several booleans that can
/// disagree.
private sealed interface UpdatePhase {
    data object Checking : UpdatePhase
    data object Ready : UpdatePhase
    data object Installing : UpdatePhase
    data object Done : UpdatePhase
    data class Failed(val reason: String) : UpdatePhase
}

private enum class UpdateTone { PLAIN, AVAILABLE, WAITING }

@Composable
private fun UpdateNote(text: String, tone: UpdateTone) {
    val colors = LocalTsColors.current
    Text(
        text,
        style = TsType.caption,
        color = when (tone) {
            UpdateTone.PLAIN -> colors.textSecondary
            UpdateTone.AVAILABLE -> colors.accent
            UpdateTone.WAITING -> colors.warning
        },
    )
}

/// Counted rather than "some work": a person deciding whether to end their
/// own sessions wants the number.
private fun updateWorkPhrase(count: Int): String =
    if (count == 1) L10n.text("android.devicedetail.one_thing_is.cda2ad7f") else L10n.text("android.devicedetail.0_things_are.ce038154", "${count}")

private fun updatePendingSentence(state: JsonObject): String {
    val installed = L10n.text("android.devicedetail.version_0_is_installed_and_waiting.87629ce8", "${state.string("latest").orEmpty()}")
    if (!state.bool("canRestart")) return L10n.text("android.devicedetail.0_restart_it_there_to_use_it.258c3248", "${installed}")
    val live = state.int("liveWork") ?: 0
    return if (live > 0) {
        L10n.text("android.devicedetail.0_1_running_so_it_restarts_when_they_finis.3d730cfa", "${installed}", "${updateWorkPhrase(live)}")
    } else {
        L10n.text("android.devicedetail.0_it_restarts_on_its_own_shortly.0d399003", "${installed}")
    }
}

private fun updateInstalledWaitingSentence(applied: JsonObject): String {
    val version = applied.string("to") ?: L10n.text("android.devicedetail.the_new_version.c8c06a3b")
    val live = applied.int("liveWork") ?: 0
    if (!applied.bool("canRestart")) return L10n.text("android.devicedetail.installed_0_restart_it_there_to_use_it.a0ac537c", "${version}")
    return if (live > 0) {
        L10n.text("android.devicedetail.installed_0_1_running_so_it_restarts_when.ae74cc9c", "${version}", "${updateWorkPhrase(live)}")
    } else {
        L10n.text("android.devicedetail.installed_0_it_restarts_shortly.b1c4d920", "${version}")
    }
}

@Composable
private fun UpdateReadyBody(state: JsonObject) {
    val colors = LocalTsColors.current
    Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
        // Two versions on one line, because the pair is the fact.
        Row(
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(6.dp),
        ) {
            Text(
                if (state.bool("restartPending")) L10n.text("android.devicedetail.running_0.015ef2e2", "${state.string("hostVersion")}") else state.string("hostVersion").orEmpty(),
                style = TsType.numeric(16),
                color = colors.textPrimary,
            )
            if (state.bool("newer") && !state.bool("restartPending")) {
                Icon(ActionIcon.Disclosure.vector, contentDescription = null, tint = colors.textTertiary, modifier = Modifier.size(12.dp))
                Text(
                    state.string("latest").orEmpty(),
                    style = TsType.numeric(16),
                    color = colors.accent,
                )
            }
        }
        if (state.bool("restartPending")) {
            // Installed but not in use. Saying "up to date" here would name
            // a version the running process does not have.
            UpdateNote(updatePendingSentence(state), UpdateTone.WAITING)
        } else if (state.bool("newer")) {
            UpdateNote(L10n.text("android.devicedetail.version_0_is_available.874abce6", "${state.string("latest")}"), UpdateTone.AVAILABLE)
        } else {
            UpdateNote(L10n.text("android.devicedetail.up_to_date.50620fd9"), UpdateTone.PLAIN)
        }
        // Additive, not instead of the line above: an application-managed
        // helper that is current should still say so, and one that is
        // behind should say both things.
        if (state.bool("appManaged")) {
            UpdateNote(
                L10n.text("android.devicedetail.the_tokenstat_application_there_owns_its_h.c214574e"),
                UpdateTone.PLAIN,
            )
        } else {
            if (state.bool("newer") && !state.bool("canRestart")) {
                UpdateNote(
                    L10n.text("android.devicedetail.it_installs_but_cannot_restart_itself_so_i.f14f8d70"),
                    UpdateTone.WAITING,
                )
            }
            if (state.bool("autoApply")) {
                UpdateNote(L10n.text("android.devicedetail.checks_daily_on_its_own.bfd7c539"), UpdateTone.PLAIN)
            }
        }
    }
}

@Composable
private fun UpdateDoneBody(applied: JsonObject) {
    val colors = LocalTsColors.current
    Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
        val detail = applied.string("detail")
        val appImage = applied.string("appImage").orEmpty()
        when {
            detail != null -> Text(detail, style = TsType.caption, color = colors.textSecondary)
            applied.bool("restarting") -> UpdateNote(
                L10n.text("android.devicedetail.installed_0_restarting_on_it_now_so_this_m.4a3fb7f6", "${applied.string("to") ?: L10n.text("android.devicedetail.the_new_version.b455aa8f")}"),
                UpdateTone.AVAILABLE,
            )
            appImage.isNotEmpty() && applied.bool("appManaged") ->
                UpdateNote(L10n.text("android.devicedetail.the_application_s_download_is_ready_on_tha.bc948717"), UpdateTone.AVAILABLE)
            else -> UpdateNote(updateInstalledWaitingSentence(applied), UpdateTone.WAITING)
        }
    }
}

private fun JsonObject.string(key: String): String? = (this[key] as? JsonPrimitive)?.contentOrNull
private fun JsonObject.long(key: String): Long? = (this[key] as? JsonPrimitive)?.longOrNull
private fun JsonObject.int(key: String): Int? = (this[key] as? JsonPrimitive)?.intOrNull
private fun JsonObject.doubleOrNull(key: String): Double? = this[key]?.jsonPrimitive?.doubleOrNull
private fun JsonObject.bool(key: String): Boolean = (this[key] as? JsonPrimitive)?.booleanOrNull == true
private fun JsonObject.optBoolean(key: String): Boolean? = (this[key] as? JsonPrimitive)?.booleanOrNull
