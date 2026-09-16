// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.home

import android.content.Context
import android.content.SharedPreferences
import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.IntrinsicSize
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ChatBubbleOutline
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.ChevronRight
import androidx.compose.material.icons.filled.Folder
import androidx.compose.material.icons.filled.KeyboardArrowDown
import androidx.compose.material.icons.filled.KeyboardArrowUp
import androidx.compose.material.icons.filled.Speed
import androidx.compose.material.icons.filled.Terminal
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.unit.sp
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.MutableState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import ai.tokenstat.tokenstat.ui.components.ActionIcon
import ai.tokenstat.tokenstat.ui.components.BrandCheckDisc
import ai.tokenstat.tokenstat.ui.components.EmptyState
import ai.tokenstat.tokenstat.ui.components.SectionLabel
import ai.tokenstat.tokenstat.ui.components.SectionTitle
import ai.tokenstat.tokenstat.ui.components.TsAccentButton
import ai.tokenstat.tokenstat.ui.components.TsCard
import ai.tokenstat.tokenstat.ui.components.TsSecondaryButton
import ai.tokenstat.tokenstat.ui.components.tsPanel
import ai.tokenstat.tokenstat.ui.logic.HomePreset
import ai.tokenstat.tokenstat.ui.logic.HomeSection
import ai.tokenstat.tokenstat.ui.logic.PinnedWork
import ai.tokenstat.tokenstat.ui.logic.RecentPlaces
import ai.tokenstat.tokenstat.ui.logic.RelativeClock
import ai.tokenstat.tokenstat.ui.logic.friendlyError
import ai.tokenstat.tokenstat.ui.logic.normalizeHomeLayout
import ai.tokenstat.tokenstat.ui.marks.DeviceGlyph
import ai.tokenstat.tokenstat.ui.marks.EmptyArt
import ai.tokenstat.tokenstat.ui.marks.EmptyArtKind
import ai.tokenstat.tokenstat.ui.theme.LocalTsColors
import ai.tokenstat.tokenstat.ui.theme.Space
import ai.tokenstat.tokenstat.ui.theme.rememberReduceMotion
import ai.tokenstat.tokenstat.ui.components.TsType
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json

/// Device-local Home furniture: the continue shelf, the pin shelf, and the
/// card arrangement. Ports `ClientRecentPlaces`, `PinnedWorkStore`, and
/// `HomeLayout`, backed by SharedPreferences the way the Apple client uses
/// UserDefaults. Pins and the work itself belong to the account; the order of
/// the cards does not, so the layout is keyed to this device only.

@Serializable
private data class StoredPlace(
    val peer: String,
    val workspaceId: String? = null,
    val kind: String,
    val itemId: String? = null,
    val workspaceName: String,
    val openedAtMs: Long,
)

@Serializable
private data class StoredPin(
    val scope: String,
    val hostIdentity: String,
    val workspaceId: String,
    val kind: String,
    val itemId: String? = null,
    val label: String,
    val folderName: String,
    val pinnedAtMs: Long,
)

private fun RecentPlaces.Kind.key(): String = when (this) {
    RecentPlaces.Kind.WORKSPACE -> "workspace"
    RecentPlaces.Kind.CHAT -> "chat"
    RecentPlaces.Kind.TERMINAL -> "terminal"
}

private fun placeKindOf(key: String): RecentPlaces.Kind? = when (key) {
    "workspace" -> RecentPlaces.Kind.WORKSPACE
    "chat" -> RecentPlaces.Kind.CHAT
    "terminal" -> RecentPlaces.Kind.TERMINAL
    else -> null
}

private fun PinnedWork.Kind.key(): String = when (this) {
    PinnedWork.Kind.WORKSPACE -> "workspace"
    PinnedWork.Kind.CONVERSATION -> "conversation"
}

private fun pinKindOf(key: String): PinnedWork.Kind? = when (key) {
    "workspace" -> PinnedWork.Kind.WORKSPACE
    "conversation", "chat" -> PinnedWork.Kind.CONVERSATION
    else -> null
}

class HomeStores(context: Context) {
    private val prefs: SharedPreferences =
        context.getSharedPreferences("tokenstat.home.v1", Context.MODE_PRIVATE)
    private val json = Json { ignoreUnknownKeys = true }

    /// Bumped on every mutation so readers recompose. The stores decode on
    /// every access, so rows must read once per pass, never twice in a loop.
    val revision: MutableState<Int> = mutableIntStateOf(0)

    private fun scopeOf(handle: String): String = handle.trim()

    fun places(identity: String?, host: String): List<RecentPlaces.Place> {
        revision.value
        val scope = identity?.trim().orEmpty()
        if (scope.isEmpty() || host.isEmpty()) return emptyList()
        val raw = prefs.getString(placesKey(host, scope), null) ?: return emptyList()
        val stored = runCatching { json.decodeFromString<List<StoredPlace>>(raw) }.getOrNull()
            ?: return emptyList()
        return RecentPlaces.places(stored.mapNotNull { dto ->
            val kind = placeKindOf(dto.kind) ?: return@mapNotNull null
            RecentPlaces.Place(
                RecentPlaces.PlaceId(dto.peer, dto.workspaceId, kind, dto.itemId),
                dto.workspaceName,
                dto.openedAtMs,
            )
        })
    }

    fun recordPlace(
        identity: String?,
        host: String,
        peer: String,
        workspaceId: String?,
        workspaceName: String,
        kind: RecentPlaces.Kind,
        itemId: String? = null,
    ) {
        val scope = identity?.trim().orEmpty()
        if (scope.isEmpty() || host.isEmpty()) return
        val stored = readPlacesDto(host, scope)
        val current = stored.mapNotNull { dto ->
            val dtoKind = placeKindOf(dto.kind) ?: return@mapNotNull null
            RecentPlaces.Place(
                RecentPlaces.PlaceId(dto.peer, dto.workspaceId, dtoKind, dto.itemId),
                dto.workspaceName,
                dto.openedAtMs,
            )
        }
        val updated = RecentPlaces.record(current, peer, workspaceId, workspaceName, kind, itemId, System.currentTimeMillis())
        prefs.edit().putString(placesKey(host, scope), json.encodeToString(updated.map {
            StoredPlace(it.id.peer, it.id.workspaceId, it.id.kind.key(), it.id.itemId, it.workspaceName, it.openedAtMs)
        })).apply()
        revision.value += 1
    }

    private fun readPlacesDto(host: String, scope: String): List<StoredPlace> {
        val raw = prefs.getString(placesKey(host, scope), null) ?: return emptyList()
        return runCatching { json.decodeFromString<List<StoredPlace>>(raw) }.getOrNull() ?: emptyList()
    }

    private fun placesKey(host: String, scope: String): String = RecentPlaces.scopeKey(host, scope)

    fun pins(handle: String): List<PinnedWork.Pin> {
        revision.value
        val scope = pinScope(handle)
        if (scope.isEmpty()) return emptyList()
        return PinnedWork.pins(readPinsDto(scope).mapNotNull { dto ->
            val kind = pinKindOf(dto.kind) ?: return@mapNotNull null
            PinnedWork.Pin(dto.scope, dto.hostIdentity, dto.workspaceId, kind, dto.itemId, dto.label, dto.folderName, dto.pinnedAtMs)
        }, scope)
    }

    /// True when the pin landed. False when the shelf is full and this is
    /// new: the row says the shelf holds eight, rather than the oldest pin
    /// silently going.
    fun togglePin(
        handle: String,
        peer: String,
        workspaceId: String,
        kind: PinnedWork.Kind,
        itemId: String?,
        label: String,
        folderName: String,
    ): Boolean {
        val scope = pinScope(handle)
        if (scope.isEmpty()) return false
        val stored = readPinsDto(scope).mapNotNull { dto ->
            val dtoKind = pinKindOf(dto.kind) ?: return@mapNotNull null
            PinnedWork.Pin(dto.scope, dto.hostIdentity, dto.workspaceId, dtoKind, dto.itemId, dto.label, dto.folderName, dto.pinnedAtMs)
        }
        if (PinnedWork.isPinned(stored, scope, peer, workspaceId, kind, itemId)) {
            savePins(scope, PinnedWork.unpin(stored, scope, peer, workspaceId, kind, itemId))
            return true
        }
        val (next, ok) = PinnedWork.pin(stored, scope, peer, workspaceId, kind, itemId, label, folderName, System.currentTimeMillis())
        if (!ok) return false
        savePins(scope, next)
        return true
    }

    fun unpin(handle: String, pin: PinnedWork.Pin) {
        val scope = pinScope(handle)
        if (scope.isEmpty()) return
        val stored = readPinsDto(scope).mapNotNull { dto ->
            val dtoKind = pinKindOf(dto.kind) ?: return@mapNotNull null
            PinnedWork.Pin(dto.scope, dto.hostIdentity, dto.workspaceId, dtoKind, dto.itemId, dto.label, dto.folderName, dto.pinnedAtMs)
        }
        savePins(scope, PinnedWork.unpin(stored, scope, pin.hostIdentity, pin.workspaceId, pin.kind, pin.itemId))
    }

    fun isPinned(handle: String, peer: String, workspaceId: String, kind: PinnedWork.Kind, itemId: String?): Boolean {
        revision.value
        val scope = pinScope(handle)
        if (scope.isEmpty()) return false
        return PinnedWork.isPinned(
            readPinsDto(scope).mapNotNull { dto ->
                val dtoKind = pinKindOf(dto.kind) ?: return@mapNotNull null
                PinnedWork.Pin(dto.scope, dto.hostIdentity, dto.workspaceId, dtoKind, dto.itemId, dto.label, dto.folderName, dto.pinnedAtMs)
            },
            scope, peer, workspaceId, kind, itemId,
        )
    }

    private fun readPinsDto(scope: String): List<StoredPin> {
        val raw = prefs.getString(pinsKey(scope), null) ?: return emptyList()
        return runCatching { json.decodeFromString<List<StoredPin>>(raw) }.getOrNull() ?: emptyList()
    }

    private fun savePins(scope: String, pins: List<PinnedWork.Pin>) {
        prefs.edit().putString(pinsKey(scope), json.encodeToString(pins.map {
            StoredPin(it.scope, it.hostIdentity, it.workspaceId, it.kind.key(), it.itemId, it.label, it.folderName, it.pinnedAtMs)
        })).apply()
        revision.value += 1
    }

    private fun pinScope(handle: String): String {
        val scope = scopeOf(handle)
        return if (scope.isEmpty()) "" else "account|host|$scope"
    }

    private fun pinsKey(scope: String): String = "pinned.work.v1.$scope"

    fun layout(): Pair<List<HomeSection>, Set<HomeSection>> {
        revision.value
        val rawOrder = prefs.getString("home.sectionOrder.v1", null)
        val stored = rawOrder
            ?.let { runCatching { json.decodeFromString<List<String>>(it) }.getOrNull() }
            ?.mapNotNull(HomeSection::of)
        val hidden = prefs.getString("home.sectionHidden.v1", null)
            ?.let { runCatching { json.decodeFromString<List<String>>(it) }.getOrNull() }
            .orEmpty().mapNotNull(HomeSection::of).toSet()
        // A missing order key means nobody arranged this device: balanced,
        // and the editor should say so.
        if (rawOrder == null) return HomePreset.BALANCED.order to HomePreset.BALANCED.hidden
        return normalizeHomeLayout(stored, hidden)
    }

    fun saveLayout(order: List<HomeSection>, hidden: Set<HomeSection>, preset: HomePreset?) {
        prefs.edit()
            .putString("home.sectionOrder.v1", json.encodeToString(order.map { it.key }))
            .putString("home.sectionHidden.v1", json.encodeToString(hidden.map { it.key }))
            .putString("home.sectionPreset.v1", preset?.name ?: "")
            .apply()
        revision.value += 1
    }

    fun preset(): HomePreset? {
        revision.value
        if (!prefs.contains("home.sectionOrder.v1")) return HomePreset.BALANCED
        return prefs.getString("home.sectionPreset.v1", null)?.let { runCatching { HomePreset.valueOf(it) }.getOrNull() }
    }
}

/// Presence words for a machine behind a continue or pinned row. The
/// destination owns reachability; a machine that is asleep says so there.
fun machineRowState(linked: Boolean, offline: Boolean, online: Boolean?): String =
    when {
        !linked -> "No longer linked"
        offline -> "You are offline"
        online == true -> "Awake"
        online == false -> "Asleep"
        else -> "Status unknown"
    }

/// The work worth going back to: up to four folders and conversations, newest
/// first. Empty collapses to nothing and keeps its arranged position.
@Composable
fun ContinueSection(
    places: List<RecentPlaces.Place>,
    machineName: (String) -> String?,
    machineOnline: (String) -> Boolean?,
    offline: Boolean,
    onOpen: (RecentPlaces.Place) -> Unit,
    isPinned: (RecentPlaces.Place) -> Boolean,
    onTogglePin: (RecentPlaces.Place) -> Boolean,
) {
    val colors = LocalTsColors.current
    val shown = places.take(4)
    if (shown.isEmpty()) return
    var refused by remember { mutableStateOf(false) }
    Column(verticalArrangement = Arrangement.spacedBy(Space.s)) {
        SectionLabel("Pick up where you left off")
        TsCard {
            Column {
                shown.forEachIndexed { index, place ->
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        modifier = Modifier.fillMaxWidth().clickable { onOpen(place) }.padding(vertical = 12.dp),
                    ) {
                        Icon(
                            when (place.id.kind) {
                                RecentPlaces.Kind.WORKSPACE -> Icons.Default.Folder
                                RecentPlaces.Kind.CHAT -> Icons.Default.ChatBubbleOutline
                                RecentPlaces.Kind.TERMINAL -> Icons.Default.Terminal
                            },
                            null,
                            tint = colors.accent,
                            modifier = Modifier.width(24.dp),
                        )
                        Spacer(Modifier.width(Space.m))
                        Column(Modifier.weight(1f)) {
                            Text(
                                RecentPlaces.title(place),
                                fontWeight = FontWeight.SemiBold,
                                color = colors.textPrimary,
                                maxLines = 2,
                            )
                            val name = machineName(place.id.peer)
                            val state = machineRowState(name != null, offline, name?.let(machineOnline))
                            Text(
                                "${name ?: "Machine"} · $state · ${RelativeClock.label(place.openedAtMs)}",
                                style = MaterialTheme.typography.bodySmall,
                                color = colors.textSecondary,
                                maxLines = 2,
                            )
                        }
                        // Terminal sessions end, so they are not pinnable:
                        // keeping a link to a dead shell is worse than no pin.
                        if (place.id.kind != RecentPlaces.Kind.TERMINAL) {
                            val pinned = isPinned(place)
                            IconButton(onClick = {
                                refused = !onTogglePin(place)
                            }) {
                                Icon(
                                    (if (pinned) ActionIcon.Pinned else ActionIcon.Pin).vector,
                                    if (pinned) "Pinned" else "Pin",
                                    tint = when {
                                        pinned -> colors.accent
                                        refused -> colors.danger
                                        else -> colors.textSecondary
                                    },
                                )
                            }
                        }
                        Icon(Icons.Default.ChevronRight, null, tint = colors.textSecondary)
                    }
                    if (index != shown.lastIndex) {
                        HorizontalDivider(color = colors.border)
                    }
                }
            }
        }
        if (refused) {
            Text(
                "The shelf holds eight pins",
                style = MaterialTheme.typography.bodySmall,
                color = colors.danger,
            )
        }
    }
}

data class HomeMachine(
    val id: String,
    val peer: String?,
    val name: String,
    val online: Boolean?,
    val label: String? = null,
    val platform: String? = null,
)

/// Which of your computers is awake right now. Account plane only, so this
/// draws with every laptop shut. Asleep ones stay off this screen: the list
/// is a jumping-off point, not an inventory, and Devices already inventories
/// everything.
@Composable
fun MachinesSection(
    machines: List<HomeMachine>,
    onOpenWork: (String) -> Unit,
    onOpenDevices: () -> Unit,
) {
    val colors = LocalTsColors.current
    val awakeDot = colors.accent
    val asleepDot = colors.textSecondary.copy(alpha = 0.35f)
    if (machines.isEmpty()) return
    Column(verticalArrangement = Arrangement.spacedBy(Space.s)) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            modifier = Modifier.fillMaxWidth().padding(horizontal = 2.dp),
        ) {
            SectionTitle("Machines", "mark_host")
            Spacer(Modifier.weight(1f))
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(2.dp),
                modifier = Modifier.clickable { onOpenDevices() }.padding(vertical = 12.dp),
            ) {
                Text(
                    "Devices",
                    style = TsType.caption.copy(fontWeight = FontWeight.SemiBold),
                    color = colors.accent,
                )
                Icon(Icons.Default.ChevronRight, null, tint = colors.accent, modifier = Modifier.size(12.dp))
            }
        }
        // One card with ruled dividers, like the Apple home. The rows are one
        // list with seams, not separate computers in separate panels.
        Column(
            Modifier
                .fillMaxWidth()
                .clip(RoundedCornerShape(14.dp))
                .tsPanel(),
        ) {
            machines.forEachIndexed { index, machine ->
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(Space.m),
                    modifier = Modifier
                        .fillMaxWidth()
                        .clickable { onOpenWork(machine.id) }
                        .heightIn(min = 60.dp)
                        .padding(Space.m),
                ) {
                    androidx.compose.foundation.Canvas(Modifier.size(9.dp)) {
                        drawCircle(color = if (machine.online == true) awakeDot else asleepDot)
                    }
                    Box(Modifier.width(24.dp), contentAlignment = Alignment.Center) {
                        DeviceGlyph(
                            name = machine.name,
                            label = machine.label,
                            platform = machine.platform,
                            isHost = true,
                            sizeDp = 17,
                        )
                    }
                    Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                        Text(
                            machine.name,
                            style = TsType.subheadline.copy(fontWeight = FontWeight.Medium),
                            color = colors.textPrimary,
                            maxLines = 1,
                        )
                        Text(
                            machineState(machine.online),
                            style = TsType.caption,
                            color = colors.textSecondary,
                            maxLines = 1,
                        )
                    }
                    Icon(Icons.Default.ChevronRight, null, tint = colors.textTertiary, modifier = Modifier.size(12.dp))
                }
                if (index != machines.lastIndex) {
                    HorizontalDivider(color = colors.border, modifier = Modifier.padding(horizontal = Space.m))
                }
            }
        }
    }
}

/// Awake, Asleep, or unknown, the same three words the Apple home reads.
fun machineState(online: Boolean?): String = when (online) {
    true -> "Awake"
    false -> "Asleep"
    else -> "Status unknown"
}

/// The shelf: up to eight folders and conversations, newest first. Rows open
/// through the same destination Continue uses, so a pin to work on a sleeping
/// machine says so there rather than here.
@Composable
fun PinnedSection(
    pins: List<PinnedWork.Pin>,
    machineName: (String) -> String?,
    machineOnline: (String) -> Boolean?,
    offline: Boolean,
    onOpen: (PinnedWork.Pin) -> Unit,
    onUnpin: (PinnedWork.Pin) -> Unit,
) {
    val colors = LocalTsColors.current
    if (pins.isEmpty()) return
    Column(verticalArrangement = Arrangement.spacedBy(Space.s)) {
        SectionLabel("Pinned")
        TsCard {
            Column {
                pins.forEachIndexed { index, pin ->
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        modifier = Modifier.fillMaxWidth().clickable { onOpen(pin) }.padding(vertical = 12.dp),
                    ) {
                        Icon(
                            when (pin.kind) {
                                PinnedWork.Kind.WORKSPACE -> Icons.Default.Folder
                                PinnedWork.Kind.CONVERSATION -> Icons.Default.ChatBubbleOutline
                            },
                            null,
                            tint = colors.accent,
                            modifier = Modifier.width(24.dp),
                        )
                        Spacer(Modifier.width(Space.m))
                        Column(Modifier.weight(1f)) {
                            Text(pin.label, fontWeight = FontWeight.SemiBold, color = colors.textPrimary, maxLines = 2)
                            val name = machineName(pin.hostIdentity)
                            val state = machineRowState(name != null, offline, name?.let(machineOnline))
                            Text(
                                "${pin.folderName} · ${name ?: "Machine"} · $state · Pinned",
                                style = MaterialTheme.typography.bodySmall,
                                color = colors.textSecondary,
                                maxLines = 2,
                            )
                        }
                        IconButton(onClick = { onUnpin(pin) }) {
                            Icon(ActionIcon.Pinned.vector, "Unpin ${pin.label}", tint = colors.accent)
                        }
                        Icon(Icons.Default.ChevronRight, null, tint = colors.textSecondary)
                    }
                    if (index != pins.lastIndex) {
                        HorizontalDivider(color = colors.border)
                    }
                }
            }
        }
    }
}

/// What happened to the account read, when something did. A failed load
/// replaces the wireframe with the reason: a skeleton that never resolves is
/// a lie told slowly. Offline gets its own words: with no network there is
/// nothing to fetch and nothing anybody can do about it.
@Composable
fun HomeStatusBlock(error: String?, offline: Boolean, onRetry: () -> Unit) {
    val colors = LocalTsColors.current
    if (offline) {
        EmptyState(
            icon = ActionIcon.Help.vector,
            title = "You are offline",
            message = "This updates by itself when the connection is back.",
            art = { EmptyArt(EmptyArtKind.Waiting) },
        )
    } else if (error != null) {
        EmptyState(
            icon = ActionIcon.Help.vector,
            title = "Could not load your activity",
            message = friendlyError(error).message,
            action = { TsAccentButton(label = "Try again", onClick = onRetry) },
            art = { EmptyArt(EmptyArtKind.Waiting) },
        )
    } else {
        EmptyState(
            icon = ActionIcon.Help.vector,
            title = "Activity is unavailable",
            message = "Waiting for your activity to load.",
            action = { TsAccentButton(label = "Try again", onClick = onRetry) },
            art = { EmptyArt(EmptyArtKind.Waiting) },
        )
    }
    Spacer(Modifier.height(Space.s))
    Text(
        "tokenstat counts on the computers you work on. Only aggregate numbers are eligible for sync.",
        style = MaterialTheme.typography.bodySmall,
        color = colors.textSecondary,
    )
}

/// Every card switched off. Not an error, and not empty space with nothing
/// to press: the way back is right here.
@Composable
fun ClearHomeCard() {
    TsCard {
        Text("Your Home is clear", fontWeight = FontWeight.Medium, color = LocalTsColors.current.textPrimary)
        Text(
            "Every card is switched off. The tabs and your folders are where they were.",
            style = MaterialTheme.typography.bodySmall,
            color = LocalTsColors.current.textSecondary,
        )
    }
}

/// The phone's first run: signed in already, counting nothing yet.
/// Where a step sits in a rail somebody is walking. Three states and no
/// fourth: behind you, in front of you, or the one to do now.
enum class GettingStartedState { DONE, NOW, NEXT }

/// One step, and what it offers. The action is part of the step rather than
/// something drawn under the rail, because if there is something to do, the
/// button doing it belongs on the line that asks for it.
data class GettingStartedStep(
    val number: Int,
    val title: String,
    val body: String,
    val state: GettingStartedState,
    val actionTitle: String? = null,
    val action: (() -> Unit)? = null,
)

/// The numbered rail a new account walks: one line, one live step, the rest
/// ahead or struck behind. Ported from `GettingStartedRail.swift`. The
/// connector is drawn on the step and not between two of them, so a step can
/// be any height and the line still reaches the next disc.
@Composable
fun GettingStartedRail(steps: List<GettingStartedStep>) {
    Column {
        steps.forEachIndexed { index, step ->
            GettingStartedRow(step, isLast = index == steps.lastIndex)
        }
    }
}

@Composable
private fun GettingStartedRow(step: GettingStartedStep, isLast: Boolean) {
    val colors = LocalTsColors.current
    val reduceMotion = rememberReduceMotion()
    Row(Modifier.height(IntrinsicSize.Min)) {
        Column(
            Modifier.width(30.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            // The live step gets a halo. It is the one thing on the card
            // that should catch the eye first, and a ring costs nothing
            // next to making the disc itself louder than the title.
            Box(Modifier.size(30.dp), contentAlignment = Alignment.Center) {
                if (step.state == GettingStartedState.NOW && !reduceMotion) {
                    val pulse by rememberInfiniteTransition(label = "railPulse").animateFloat(
                        initialValue = 0f,
                        targetValue = 1f,
                        animationSpec = infiniteRepeatable(tween(1800, easing = LinearEasing)),
                        label = "railPulse",
                    )
                    androidx.compose.foundation.Canvas(Modifier.size(30.dp)) {
                        drawCircle(
                            color = colors.accent.copy(alpha = 0.16f * (1f - pulse)),
                            radius = size.minDimension / 2f * (1f + 0.42f * pulse),
                        )
                    }
                }
                androidx.compose.foundation.Canvas(Modifier.size(26.dp)) {
                    val fill = when (step.state) {
                        GettingStartedState.NEXT -> colors.accentSoft
                        else -> colors.accent
                    }
                    drawCircle(color = fill, radius = size.minDimension / 2f)
                    if (step.state == GettingStartedState.NEXT) {
                        drawCircle(
                            color = colors.border,
                            radius = size.minDimension / 2f,
                            style = androidx.compose.ui.graphics.drawscope.Stroke(width = 1.dp.toPx()),
                        )
                    }
                }
                when (step.state) {
                    GettingStartedState.DONE -> Icon(
                        Icons.Default.Check,
                        contentDescription = null,
                        modifier = Modifier.size(12.dp),
                        tint = androidx.compose.ui.graphics.Color.White,
                    )
                    else -> Text(
                        step.number.toString(),
                        style = TsType.mono(11, FontWeight.Bold),
                        color = if (step.state == GettingStartedState.NOW) {
                            androidx.compose.ui.graphics.Color.White
                        } else {
                            colors.textSecondary
                        },
                    )
                }
            }
            if (!isLast) {
                // Below the disc rather than beside it, so the line starts
                // where the circle ends whatever the row above is doing. A
                // finished stretch reads finished; the rest fades out so it
                // does not end in a hard stop.
                val top = if (step.state == GettingStartedState.DONE) {
                    colors.accent.copy(alpha = 0.5f)
                } else {
                    colors.border
                }
                Box(
                    Modifier
                        .weight(1f)
                        .width(2.dp)
                        .padding(vertical = 4.dp)
                        .background(
                            androidx.compose.ui.graphics.Brush.verticalGradient(
                                listOf(top, top.copy(alpha = top.alpha * 0.25f)),
                            ),
                            RoundedCornerShape(50),
                        ),
                )
            }
        }
        Spacer(Modifier.width(Space.m))
        Column(
            Modifier
                .weight(1f)
                .padding(bottom = if (isLast) 0.dp else Space.l),
            verticalArrangement = Arrangement.spacedBy(Space.xs),
        ) {
            Text(
                step.title,
                style = TsType.headline,
                color = if (step.state == GettingStartedState.DONE) colors.textSecondary else colors.textPrimary,
            )
            Text(
                step.body,
                style = TsType.callout,
                color = colors.textSecondary,
                modifier = Modifier.widthIn(max = 420.dp),
            )
            if (step.actionTitle != null && step.action != null) {
                TsAccentButton(
                    label = step.actionTitle,
                    icon = ActionIcon.Connect.vector,
                    onClick = step.action,
                    modifier = Modifier.padding(top = Space.xs),
                )
            }
        }
    }
}

/// The grid that is not there yet, drawn where it will be. Cells light in a
/// wave across the weeks and fade, which is roughly what a real first sync
/// looks like arriving. Ported from `GettingStartedGhostGrid`.
@Composable
fun GettingStartedGhostGrid(weeks: Int = 16, centered: Boolean = true) {
    val colors = LocalTsColors.current
    val reduceMotion = rememberReduceMotion()
    val phase = if (reduceMotion) {
        0f
    } else {
        rememberInfiniteTransition(label = "ghostPhase").animateFloat(
            initialValue = 0f,
            targetValue = 1f,
            animationSpec = infiniteRepeatable(tween(3400, easing = LinearEasing)),
            label = "ghostPhase",
        ).value
    }
    Box(Modifier.fillMaxWidth(), contentAlignment = if (centered) Alignment.Center else Alignment.CenterStart) {
        Canvas(
            Modifier
                .width((9 * weeks + 3 * (weeks - 1)).dp)
                .height((9 * 7 + 3 * 6).dp),
        ) {
            val cell = 9.dp.toPx()
            val gap = 3.dp.toPx()
            val step = cell + gap
            for (row in 0 until 7) {
                for (week in 0 until weeks) {
                    drawRoundRect(
                        color = colors.accent.copy(alpha = ghostLevel(row, week, weeks, phase, reduceMotion)),
                        topLeft = Offset(week * step, row * step),
                        size = Size(cell, cell),
                        cornerRadius = CornerRadius(2.dp.toPx(), 2.dp.toPx()),
                    )
                }
            }
        }
    }
}

/// A soft band over a floor of empty cells. The per-cell jitter keeps it from
/// reading as a scanning bar: a real week is not one brightness.
private fun ghostLevel(row: Int, week: Int, weeks: Int, phase: Float, reduceMotion: Boolean): Float {
    val floor = 0.08f
    if (reduceMotion) return floor
    val position = week.toFloat() / maxOf(weeks - 1, 1)
    var distance = kotlin.math.abs(position - phase)
    distance = minOf(distance, 1f - distance)
    val band = maxOf(0f, 1f - distance * 5f)
    val jitter = ((row * 7 + week * 13) % 5) / 10f
    return floor + band * (0.25f + jitter)
}

/// What to do next, on a phone whose account has nothing on it yet. Ported
/// from `ClientGettingStarted.swift`: the rail opens already part finished
/// instead of opening as a list of chores, and step three has no instruction
/// because it is the picture of what arrives once step two is done.
@Composable
fun GettingStartedCard(phoneName: String?, onSetup: () -> Unit) {
    val colors = LocalTsColors.current
    Column(
        Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(14.dp))
            .tsPanel()
            .padding(Space.m),
        verticalArrangement = Arrangement.spacedBy(Space.m),
    ) {
        Column(verticalArrangement = Arrangement.spacedBy(Space.xs)) {
            EmptyArt(EmptyArtKind.GetCounting, modifier = Modifier.fillMaxWidth().padding(bottom = 2.dp))
            SectionTitle("Get tokenstat counting", "mark_activity")
            Text(
                "tokenstat counts on the computers you work on. This device shows " +
                    "what they counted, with every laptop shut.",
                style = TsType.subheadline,
                color = colors.textSecondary,
            )
        }
        GettingStartedRail(
            listOf(
                GettingStartedStep(
                    number = 1,
                    title = "Signed in",
                    body = phoneName?.let { "This device is on your account as $it." }
                        ?: "This device is on your account.",
                    state = GettingStartedState.DONE,
                ),
                GettingStartedStep(
                    number = 2,
                    title = "Connect a machine",
                    body = "A Mac you already work on, or a server tokenstat sets up " +
                        "for you over SSH. Free includes two devices, so a machine " +
                        "and this device fit.",
                    state = GettingStartedState.NOW,
                    actionTitle = "Set up a machine",
                    action = onSetup,
                ),
            ),
        )
        Column(verticalArrangement = Arrangement.spacedBy(Space.s), modifier = Modifier.padding(top = Space.xs)) {
            HorizontalDivider(color = colors.border)
            Text(
                "Then there is nothing left to run",
                style = TsType.subheadline.copy(fontWeight = FontWeight.SemiBold),
                color = colors.textPrimary,
            )
            Text(
                "The first window of counters arrives on its own and fills this screen.",
                style = TsType.caption,
                color = colors.textSecondary,
            )
            GettingStartedGhostGrid(weeks = 16)
        }
    }
}

/// Arrange Home: pick a starting layout, move the cards, switch off the ones
/// never read. A working copy, so Done applies the whole arrangement at once
/// and Cancel really is a cancel.
@Composable
fun HomeEditor(
    order: List<HomeSection>,
    hidden: Set<HomeSection>,
    preset: HomePreset?,
    emptyReason: (HomeSection) -> String?,
    onDone: (List<HomeSection>, Set<HomeSection>, HomePreset?) -> Unit,
    onCancel: () -> Unit,
) {
    val colors = LocalTsColors.current
    var draftOrder by remember(order, hidden) { mutableStateOf(order) }
    var draftHidden by remember(order, hidden) { mutableStateOf(hidden) }
    var draftPreset by remember(order, hidden) { mutableStateOf(preset) }
    var beforeReset by remember { mutableStateOf<Triple<List<HomeSection>, Set<HomeSection>, HomePreset?>?>(null) }
    val visible = draftOrder.filter { it !in draftHidden }
    fun move(section: HomeSection, delta: Int) {
        val index = visible.indexOf(section)
        if (index < 0) return
        val target = index + delta
        if (target !in visible.indices) return
        val moving = visible[index]
        val rest = visible.toMutableList().also { it.removeAt(index) }
        rest.add(target, moving)
        val hiddenPart = draftOrder.filter { it in draftHidden }
        draftOrder = rest + hiddenPart
        draftPreset = null
        beforeReset = null
    }
    LazyColumn(
        modifier = Modifier.fillMaxWidth(),
        verticalArrangement = Arrangement.spacedBy(Space.s),
    ) {
        item {
            Row(verticalAlignment = Alignment.CenterVertically) {
                IconButton(onClick = onCancel) { Icon(ActionIcon.Dismiss.vector, "Cancel") }
                Text(
                    "Customize Home",
                    style = MaterialTheme.typography.titleLarge,
                    color = colors.textPrimary,
                    modifier = Modifier.weight(1f),
                )
                TsAccentButton(label = "Done", small = true, onClick = { onDone(draftOrder, draftHidden, draftPreset) })
            }
        }
        item {
            Row(horizontalArrangement = Arrangement.spacedBy(Space.s), modifier = Modifier.fillMaxWidth()) {
                HomePreset.entries.forEach { option ->
                    TsSecondaryButton(
                        label = option.label,
                        small = true,
                        enabled = true,
                        onClick = {
                            draftOrder = option.order
                            draftHidden = option.hidden
                            draftPreset = option
                            beforeReset = null
                        },
                        modifier = Modifier.weight(1f),
                    )
                }
            }
            Spacer(Modifier.height(Space.s))
            HomeLayoutPreview(sections = visible)
            Text(
                "A starting arrangement. It moves the cards and nothing else.",
                style = MaterialTheme.typography.bodySmall,
                color = colors.textSecondary,
            )
        }
        item { SectionLabel("Visible · drag to reorder") }
        itemsIndexed(visible, key = { _, section -> section.key }) { _, section ->
            TsCard {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Icon(
                        homeSectionGlyph(section),
                        null,
                        tint = colors.accent,
                        modifier = Modifier.width(24.dp),
                    )
                    Spacer(Modifier.width(Space.s))
                    Column(Modifier.weight(1f)) {
                        Text(section.label, fontWeight = FontWeight.Medium, color = colors.textPrimary)
                        Text(
                            emptyReason(section) ?: section.detail,
                            style = MaterialTheme.typography.bodySmall,
                            color = colors.textSecondary,
                        )
                    }
                    IconButton(
                        onClick = { move(section, -1) },
                        enabled = visible.first() != section,
                    ) { Icon(Icons.Default.KeyboardArrowUp, "Move up", tint = colors.accent) }
                    IconButton(
                        onClick = { move(section, 1) },
                        enabled = visible.last() != section,
                    ) { Icon(Icons.Default.KeyboardArrowDown, "Move down", tint = colors.accent) }
                    BrandCheckDisc(on = true, modifier = Modifier.clickable {
                        draftHidden = draftHidden + section
                        draftPreset = null
                        beforeReset = null
                    })
                }
            }
        }
        if (draftHidden.isNotEmpty()) {
            item { SectionLabel("Hidden") }
            itemsIndexed(draftOrder.filter { it in draftHidden }, key = { _, section -> section.key }) { _, section ->
                TsCard {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Icon(
                            homeSectionGlyph(section),
                            null,
                            tint = colors.textSecondary,
                            modifier = Modifier.width(24.dp),
                        )
                        Spacer(Modifier.width(Space.s))
                        Column(Modifier.weight(1f)) {
                            Text(section.label, color = colors.textSecondary)
                            Text(
                                emptyReason(section) ?: section.detail,
                                style = MaterialTheme.typography.bodySmall,
                                color = colors.textSecondary,
                            )
                        }
                        BrandCheckDisc(on = false, modifier = Modifier.clickable {
                            draftHidden = draftHidden - section
                            draftPreset = null
                            beforeReset = null
                        })
                    }
                }
            }
        }
        item {
            val off = draftOrder.filter { it in draftHidden }
            Text(
                when {
                    visible.isEmpty() -> "Home will be clear. Search and the tabs are still there, and you can switch a card back on here at any time."
                    off.isEmpty() -> "Every card is on."
                    else -> "Off: ${off.joinToString(", ") { it.label }}."
                },
                style = MaterialTheme.typography.bodySmall,
                color = colors.textSecondary,
            )
        }
        item {
            TsSecondaryButton(
                label = "Reset Home",
                onClick = {
                    beforeReset = Triple(draftOrder, draftHidden, draftPreset)
                    draftOrder = HomePreset.BALANCED.order
                    draftHidden = HomePreset.BALANCED.hidden
                    draftPreset = HomePreset.BALANCED
                },
                modifier = Modifier.fillMaxWidth(),
            )
            val previous = beforeReset
            if (previous != null) {
                Spacer(Modifier.height(Space.s))
                TsSecondaryButton(
                    label = "Undo reset",
                    onClick = {
                        draftOrder = previous.first
                        draftHidden = previous.second
                        draftPreset = previous.third
                        beforeReset = null
                    },
                    modifier = Modifier.fillMaxWidth(),
                )
            }
        }
    }
}

/// One glyph per Home card, the Material reading of `HomeSection.symbol`.
/// The editor rows and the preview strip share them.
fun homeSectionGlyph(section: HomeSection): ImageVector = when (section) {
    HomeSection.CONTINUE -> ActionIcon.History.vector
    HomeSection.PINNED -> ActionIcon.Pinned.vector
    HomeSection.MACHINES -> ActionIcon.Device.vector
    HomeSection.USAGE -> ActionIcon.Calculate.vector
    HomeSection.ACTIVITY -> ActionIcon.Layout.vector
    HomeSection.LIMITS -> Icons.Default.Speed
}

/// Home at a glance: one bar per visible card, in order. Port of
/// `HomeLayoutPreview`. Not a rendering of the real cards: a miniature that
/// pretended to be the screen would be wrong the moment any of them had
/// nothing to say.
@Composable
fun HomeLayoutPreview(sections: List<HomeSection>) {
    val colors = LocalTsColors.current
    Column(
        Modifier.fillMaxWidth()
            .clip(RoundedCornerShape(10.dp))
            .background(colors.background)
            .border(1.dp, colors.border, RoundedCornerShape(10.dp))
            .padding(Space.s),
        verticalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        // The greeting, which is not a card and cannot be moved. Drawn so
        // the bars below read as a screen rather than a stack.
        Box(
            Modifier.width(84.dp).height(8.dp)
                .clip(CircleShape)
                .background(colors.accent.copy(alpha = 0.35f)),
        )
        if (sections.isEmpty()) {
            Text(
                "Your Home is clear",
                style = TextStyle(fontSize = 12.sp),
                color = colors.textSecondary,
                modifier = Modifier.fillMaxWidth().padding(vertical = 12.dp),
            )
        } else {
            sections.forEach { section ->
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    modifier = Modifier.fillMaxWidth()
                        .height(if (section == HomeSection.ACTIVITY) 30.dp else 20.dp)
                        .clip(RoundedCornerShape(5.dp))
                        .background(colors.accent.copy(alpha = 0.10f))
                        .padding(horizontal = 6.dp),
                ) {
                    Icon(homeSectionGlyph(section), null, tint = colors.accent, modifier = Modifier.size(10.dp))
                    Spacer(Modifier.width(6.dp))
                    Text(
                        section.label,
                        style = TextStyle(fontSize = 9.sp, fontWeight = FontWeight.Medium),
                        color = colors.textSecondary,
                        maxLines = 1,
                    )
                }
            }
        }
    }
}
