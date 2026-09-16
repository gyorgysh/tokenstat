// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.search

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
            peer to (machine.string("platform") ?: "Linked device")
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
                if (handle.isNotEmpty()) {
                    for (pin in stores.pins(handle)) {
                        if (pin.kind != PinnedWork.Kind.WORKSPACE) continue
                        val id = machineIds[pin.hostIdentity] ?: continue
                        known += SearchFolder(pin.hostIdentity, id, displayNames[pin.hostIdentity] ?: id, pin.workspaceId, pin.folderName, null)
                    }
                    for (place in stores.places(handle)) {
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
                                live += SearchFolder(peer, id, name, folderId, folder.string("name") ?: "Workspace", folder.string("path"))
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

    ModalBottomSheet(onDismissRequest = onDismiss) {
        Column(
            Modifier.fillMaxWidth().verticalScroll(rememberScrollState()).padding(horizontal = Space.m).padding(bottom = Space.xl),
            verticalArrangement = Arrangement.spacedBy(Space.m),
        ) {
            Text("Search", style = TsType.title3.copy(fontWeight = FontWeight.SemiBold), color = colors.textPrimary)
            Text(
                "Find a screen, a setting, or your work",
                style = TsType.subheadline,
                color = colors.textSecondary,
            )
            TsSearchField(prompt = "Search the app", query = query, onQueryChange = { query = it })
            if (preparing) {
                Text("Preparing folders…", style = TsType.subheadline, color = colors.textSecondary)
            }
            if (failure) {
                Banner("Folders could not be read. Unlock this device and try again.", BannerSeverity.WARNING)
                TsSecondaryButton(label = "Try again", small = true, onClick = { learn() })
            }
            val matches = SearchPlaces.rank(query, places)
            if (matches.isNotEmpty()) {
                SectionLabel("Screens and settings")
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
                SectionLabel("Folders")
                folderMatches.forEach { folder ->
                    SearchFolderRow(folder) {
                        onOpen(SearchOpen.Folder(folder.hostId, folder.folderId))
                        onDismiss()
                    }
                }
            }
            if (query.isNotBlank() && matches.isEmpty() && folderMatches.isEmpty() && !preparing) {
                Text("Nothing found for \"$query\".", style = TsType.subheadline, color = colors.textSecondary)
            }
            Text(
                "Saved conversation text is off. Search covers folder information kept on this device.",
                style = TsType.caption,
                color = colors.textSecondary,
            )
            if (unreachable > 0) {
                Text(
                    "Some machines could not be reached. Open a folder on one to verify its access.",
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
        Icon(ActionIcon.Next.vector, null, tint = colors.textTertiary)
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
            )
        }
        Icon(ActionIcon.Next.vector, null, tint = colors.textTertiary)
    }
}

private fun JsonObject.string(key: String): String? {
    val element = get(key) as? kotlinx.serialization.json.JsonPrimitive ?: return null
    return element.contentOrNull
}

