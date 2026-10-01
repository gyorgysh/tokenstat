// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.search

import ai.tokenstat.tokenstat.ui.localization.L10n

import androidx.compose.foundation.layout.fillMaxHeight

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import ai.tokenstat.tokenstat.AppViewModel
import ai.tokenstat.tokenstat.ClientState
import ai.tokenstat.tokenstat.ui.components.ActionIcon
import ai.tokenstat.tokenstat.ui.components.Banner
import ai.tokenstat.tokenstat.ui.components.BannerSeverity
import ai.tokenstat.tokenstat.ui.components.SectionLabel
import ai.tokenstat.tokenstat.ui.components.TsSearchField
import ai.tokenstat.tokenstat.ui.components.TsSecondaryButton
import ai.tokenstat.tokenstat.ui.components.TsType
import ai.tokenstat.tokenstat.ui.home.HomeStores
import ai.tokenstat.tokenstat.ui.logic.DeviceCopy
import ai.tokenstat.tokenstat.ui.logic.PinnedWork
import ai.tokenstat.tokenstat.ui.logic.RecentPlaces
import ai.tokenstat.tokenstat.ui.theme.LocalTsColors
import ai.tokenstat.tokenstat.ui.theme.Space
import kotlinx.coroutines.launch
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive

/// The one way into search. Ported from `ClientWorkSearch.swift`.
///
/// Screens and settings are searchable either way; folders come from pins,
/// recent places, and one folder list per machine when search opens rather
/// than once per keystroke. The saved-work cache has no Android bridge, so
/// there is no saved conversation text: the notice says so instead of
/// pretending the coverage is wider than it is.
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun WorkSearchSheet(
    model: AppViewModel,
    state: ClientState,
    stores: HomeStores,
    onOpen: (SearchOpen) -> Unit,
    onDismiss: () -> Unit,
) {
    val colors = LocalTsColors.current
    val scope = rememberCoroutineScope()
    var query by remember { mutableStateOf("") }
    var preparing by remember { mutableStateOf(false) }
    var failure by remember { mutableStateOf(false) }
    var folders by remember { mutableStateOf(listOf<SearchFolder>()) }
    var unreachable by remember { mutableStateOf(0) }

    val machines = ((state.account?.get("machines") as? JsonArray).orEmpty())
        .mapNotNull { it as? JsonObject }
    val hosts = machines.filter { it.string("kind") != "client" && !it.string("publicIdentity").isNullOrEmpty() }
    val handle = state.account?.string("handle") ?: state.account?.string("displayName") ?: ""
    val machineIds = machines.mapNotNull { machine ->
        val peer = machine.string("publicIdentity") ?: return@mapNotNull null
        val id = machine.string("id") ?: return@mapNotNull null
        peer to id
    }.toMap()
    val displayNames = machines.mapNotNull { machine ->
        machine.string("publicIdentity")?.let { peer ->
            peer to DeviceCopy.displayName(
                machine.string("label"), machine.string("platform"),
                machine.string("kind") != "client",
            )
        }
    }.toMap()
    val platforms = machines.mapNotNull { machine ->
        machine.string("publicIdentity")?.let { peer ->
            peer to (machine.string("platform") ?: L10n.text("android.worksearchsheet.linked_device.a7ba6a12"))
        }
    }.toMap()
    val places = remember(machines) { SearchPlaces.all(machineIds.mapValues { displayNames[it.key] ?: it.key }, platforms) }

    fun learn() {
        if (preparing) return
        scope.launch {
            preparing = true
            failure = false
            runCatching {
                // Pins and recents first: they are on this device already.
                val known = mutableListOf<SearchFolder>()
                if (HomeStores.pinIdentity(state.account).isNotEmpty()) {
                    for (pin in stores.pins(HomeStores.pinIdentity(state.account))) {
                        if (pin.kind != PinnedWork.Kind.WORKSPACE) continue
                        val id = machineIds[pin.hostIdentity] ?: continue
                        known += SearchFolder(pin.hostIdentity, id, displayNames[pin.hostIdentity] ?: id, pin.workspaceId, pin.folderName, null)
                    }
                    for (place in stores.places(
                        RecentPlaces.accountIdentity(
                            state.account?.string("handle"),
                            state.account?.string("accountId"),
                        ),
                        state.account?.string("host").orEmpty(),
                    )) {
                        if (place.id.kind != RecentPlaces.Kind.WORKSPACE) continue
                        val folderId = place.id.workspaceId ?: continue
                        if (known.any { it.folderId == folderId && it.peer == place.id.peer }) continue
                        val id = machineIds[place.id.peer] ?: continue
                        known += SearchFolder(place.id.peer, id, displayNames[place.id.peer] ?: id, folderId, place.workspaceName, null)
                    }
                }
                // Then one folder list per machine, once when search opens
                // rather than once per keystroke.
                val live = mutableListOf<SearchFolder>()
                var missed = 0
                for (host in hosts) {
                    val peer = host.string("publicIdentity") ?: continue
                    val id = host.string("id") ?: continue
                    val name = displayNames[peer] ?: id
                    runCatching { model.workspaces(peer) }
                        .onSuccess { list ->
                            for (folder in list.mapNotNull { it as? JsonObject }) {
                                val folderId = folder.string("id") ?: continue
                                if (known.any { it.folderId == folderId && it.peer == peer }) continue
                                live += SearchFolder(peer, id, name, folderId, folder.string("name") ?: L10n.text("android.worksearchsheet.project.98595978"), folder.string("path"))
                            }
                        }.onFailure { missed += 1 }
                }
                Triple(known, live, missed)
            }.onSuccess { (known, live, missed) ->
                folders = (known + live).distinctBy { it.peer to it.folderId }
                unreachable = missed
            }.onFailure {
                failure = true
            }
            preparing = false
        }
    }
    LaunchedEffect(Unit) { learn() }

    // Full height: this is a search, so the keyboard takes the bottom half
    // the moment you type. Opening half way left three results visible.
    ModalBottomSheet(
        onDismissRequest = onDismiss,
        sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true),
        containerColor = colors.background,
    ) {
        Column(
            // Fills the sheet, not just its width: `skipPartiallyExpanded`
            // stops the half-height drag state but a short column still
            // wraps, so an empty search opened as a strip at the bottom and
            // the first typed letter pushed it about under the keyboard.
            Modifier.fillMaxWidth().fillMaxHeight().verticalScroll(rememberScrollState()).padding(horizontal = Space.m).padding(bottom = Space.xl),
            verticalArrangement = Arrangement.spacedBy(Space.m),
        ) {
            Text(L10n.text("common.search"), style = TsType.title3.copy(fontWeight = FontWeight.SemiBold), color = colors.textPrimary)
            Text(
                L10n.text("android.worksearchsheet.find_a_screen_a_setting_or_your_work.e15aaac3"),
                style = TsType.subheadline,
                color = colors.textSecondary,
            )
            TsSearchField(prompt = L10n.text("android.worksearchsheet.search_the_app.ad908e74"), query = query, onQueryChange = { query = it })
            if (preparing) {
                Text(L10n.text("android.worksearchsheet.preparing_folders.94aa8ea8"), style = TsType.subheadline, color = colors.textSecondary)
            }
            if (failure) {
                Banner(L10n.text("android.worksearchsheet.folders_could_not_be_read_unlock_this_devi.e40774b9"), BannerSeverity.WARNING)
                TsSecondaryButton(label = L10n.text("android.worksearchsheet.try_again.d8b8392e"), small = true, onClick = { learn() })
            }
            val matches = SearchPlaces.rank(query, places)
            if (matches.isNotEmpty()) {
                SectionLabel(L10n.text("android.worksearchsheet.screens_and_settings.f0586adb"))
                matches.forEach { place ->
                    SearchPlaceRow(place) {
                        SearchPlaces.destinationOf(place) { peer -> machineIds[peer] }?.let(onOpen)
                        onDismiss()
                    }
                }
            }
            val folderMatches = folders.filter {
                query.isBlank() || it.name.contains(query, ignoreCase = true) ||
                    (it.path?.contains(query, ignoreCase = true) == true)
            }.take(8)
            if (folderMatches.isNotEmpty()) {
                SectionLabel(L10n.text("common.projects"))
                folderMatches.forEach { folder ->
                    SearchFolderRow(folder) {
                        onOpen(SearchOpen.Folder(folder.hostId, folder.folderId))
                        onDismiss()
                    }
                }
            }
            if (query.isNotBlank() && matches.isEmpty() && folderMatches.isEmpty() && !preparing) {
                Text(L10n.text("android.worksearchsheet.nothing_found_for_0.5e80d678", "${query}"), style = TsType.subheadline, color = colors.textSecondary)
            }
            Text(
                L10n.text("android.worksearchsheet.saved_conversation_text_is_off_search_cove.38f2ad0a"),
                style = TsType.caption,
                color = colors.textSecondary,
            )
            if (unreachable > 0) {
                Text(
                    L10n.text("android.worksearchsheet.some_machines_could_not_be_reached_open_a.ce7df8b3"),
                    style = TsType.caption,
                    color = colors.textSecondary,
                )
            }
        }
    }
}

private data class SearchFolder(
    val peer: String,
    val hostId: String,
    val hostName: String,
    val folderId: String,
    val name: String,
    val path: String?,
)

@Composable
private fun SearchPlaceRow(place: SearchPlace, onClick: () -> Unit) {
    val colors = LocalTsColors.current
    Row(
        Modifier.fillMaxWidth().clickable(onClick = onClick).padding(vertical = Space.s),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(Space.m),
    ) {
        Icon(place.icon.vector, null, tint = colors.accent)
        Column(Modifier.weight(1f)) {
            Text(place.title, style = TsType.body.copy(fontWeight = FontWeight.SemiBold), color = colors.textPrimary)
            Text(place.detail, style = TsType.caption, color = colors.textSecondary)
        }
        Icon(ActionIcon.Disclosure.vector, null, tint = colors.textTertiary)
    }
}

@Composable
private fun SearchFolderRow(folder: SearchFolder, onClick: () -> Unit) {
    val colors = LocalTsColors.current
    Row(
        Modifier.fillMaxWidth().clickable(onClick = onClick).padding(vertical = Space.s),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(Space.m),
    ) {
        Icon(ActionIcon.Source.vector, null, tint = colors.accent)
        Column(Modifier.weight(1f)) {
            Text(folder.name, style = TsType.body.copy(fontWeight = FontWeight.SemiBold), color = colors.textPrimary)
            Text(
                folder.path ?: folder.hostName,
                style = TsType.caption,
                color = colors.textSecondary,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
        }
        Icon(ActionIcon.Disclosure.vector, null, tint = colors.textTertiary)
    }
}

private fun JsonObject.string(key: String): String? {
    val element = get(key) as? kotlinx.serialization.json.JsonPrimitive ?: return null
    return element.contentOrNull
}
