// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.workspace

import ai.tokenstat.tokenstat.ui.localization.L10n

import ai.tokenstat.tokenstat.ui.chrome.TabBarChrome
import androidx.activity.compose.BackHandler
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
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
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
import androidx.compose.ui.unit.dp
import ai.tokenstat.tokenstat.AppViewModel
import ai.tokenstat.tokenstat.ui.components.ActionIcon
import ai.tokenstat.tokenstat.ui.components.Banner
import ai.tokenstat.tokenstat.ui.components.BannerSeverity
import ai.tokenstat.tokenstat.ui.components.TsAccentButton
import ai.tokenstat.tokenstat.ui.components.TsCard
import ai.tokenstat.tokenstat.ui.components.TsSecondaryButton
import ai.tokenstat.tokenstat.ui.components.TsType
import ai.tokenstat.tokenstat.ui.setup.SetupFailure
import ai.tokenstat.tokenstat.ui.terminal.TerminalScreen
import ai.tokenstat.tokenstat.ui.theme.LocalTsColors
import ai.tokenstat.tokenstat.ui.theme.Space
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put

/// Getting a repository onto a machine that has none. Ported from
/// `ClientCloneRepository.swift`.
///
/// A folder has to exist before it can be registered, and on a fresh server
/// nothing does. The clone runs in a real terminal rather than behind a
/// spinner: one that asks for a passphrase or an unknown host key can be
/// answered, and one that hangs looks like a terminal that stopped moving.
/// Nothing is ever removed, including a clone that failed halfway.
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun CloneRepositoryScreen(
    model: AppViewModel,
    peer: String,
    hostLabel: String,
    onClose: () -> Unit,
    onCloned: (folderId: String) -> Unit,
) {
    var url by remember { mutableStateOf("") }
    var parent by remember { mutableStateOf<String?>(null) }
    var name by remember { mutableStateOf("") }
    var sessionId by remember { mutableStateOf<String?>(null) }
    var status by remember { mutableStateOf<CloneStatus?>(null) }
    var working by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    var picking by remember { mutableStateOf(false) }
    var statusAttempt by remember { mutableStateOf(0) }
    val scope = rememberCoroutineScope()
    val colors = LocalTsColors.current
    val ready = url.trim().isNotEmpty() && parent != null

    BackHandler { onClose() }
    // Start at the machine's own home, so the common case needs no picking.
    LaunchedEffect(peer) {
        runCatching { model.workspaceSection(peer, "fs.browse", buildJsonObject {}).jsonObject }
            .onSuccess { answer ->
                if (parent == null) parent = answer["path"]?.jsonPrimitive?.contentOrNull
            }
    }
    Scaffold(
        containerColor = colors.background,
        topBar = {
            TopAppBar(
                title = { Text(L10n.text("android.clonerepository.clone_a_repository.749e5d4d")) },
                navigationIcon = {
                    TsSecondaryButton(label = L10n.text("common.back"), small = true, onClick = onClose)
                },
                colors = TopAppBarDefaults.topAppBarColors(containerColor = colors.background),
            )
        },
        bottomBar = {
            if (sessionId == null) {
                TsAccentButton(
                    label = if (working) L10n.text("android.clonerepository.starting.bbe5fc3b") else L10n.text("android.clonerepository.clone.5779f32f"),
                    icon = ActionIcon.Download.vector,
                    onClick = {
                        scope.launch {
                            working = true
                            error = null
                            runCatching {
                                val cleanName = name.trim()
                                model.workspaceSection(peer, "workspace.clone", buildJsonObject {
                                    put("url", url.trim())
                                    put("parent", parent!!)
                                    if (cleanName.isNotEmpty()) put("name", cleanName)
                                }).jsonObject
                            }.onSuccess { info ->
                                sessionId = info["id"]?.jsonPrimitive?.contentOrNull
                            }.onFailure { error = SetupFailure.readable(it) }
                            working = false
                        }
                    },
                    modifier = Modifier.fillMaxWidth().padding(horizontal = Space.m, vertical = Space.s),
                    enabled = ready && !working,
                )
            }
        },
    ) { padding ->
        val active = sessionId
        if (active == null) {
            Column(
                Modifier.fillMaxSize().padding(padding).verticalScroll(rememberScrollState()).padding(Space.m).padding(bottom = TabBarChrome.contentBottomInset),
                verticalArrangement = Arrangement.spacedBy(Space.m),
            ) {
                Text(L10n.text("android.clonerepository.clone_onto_0.56da4378", "${hostLabel}"), style = TsType.title2.copy(fontWeight = FontWeight.SemiBold), color = colors.textPrimary)
                Text(
                    L10n.text("android.clonerepository.tokenstat_runs_git_on_that_machine_and_reg.c316bf55"),
                    style = TsType.body,
                    color = colors.textSecondary,
                )
                if (error != null) Banner(error!!, BannerSeverity.DANGER)
                TsCard {
                    Column(verticalArrangement = Arrangement.spacedBy(Space.s)) {
                        Text(L10n.text("android.clonerepository.repository.13d6ff07"), style = TsType.caption, color = colors.textSecondary)
                        OutlinedTextField(
                            value = url,
                            onValueChange = { url = it },
                            placeholder = { Text("https://github.com/owner/repo.git") },
                            singleLine = true,
                            modifier = Modifier.fillMaxWidth(),
                        )
                        Text(L10n.text("android.clonerepository.where_it_lands.452fbb26"), style = TsType.caption, color = colors.textSecondary)
                        Row(
                            Modifier.fillMaxWidth().clickable { picking = true }.padding(vertical = 4.dp),
                            verticalAlignment = Alignment.CenterVertically,
                        ) {
                            Text(
                                parent ?: L10n.text("android.clonerepository.choose_a_folder.5c71b8cd"),
                                style = TsType.mono(13),
                                color = if (parent == null) colors.textSecondary else colors.textPrimary,
                                modifier = Modifier.weight(1f).horizontalScroll(rememberScrollState()),
                                maxLines = 1,
                                overflow = TextOverflow.Ellipsis,
                            )
                            Icon(ActionIcon.Disclosure.vector, null, tint = colors.textTertiary)
                        }
                        Text(L10n.text("android.clonerepository.folder_name.14d34edf"), style = TsType.caption, color = colors.textSecondary)
                        OutlinedTextField(
                            value = name,
                            onValueChange = { name = it },
                            placeholder = { Text(L10n.text("android.clonerepository.taken_from_the_address.1d24ffb4")) },
                            singleLine = true,
                            modifier = Modifier.fillMaxWidth(),
                        )
                    }
                }
                Text(
                    L10n.text("android.clonerepository.a_private_repository_asks_for_its_credenti.7173fc9d"),
                    style = TsType.caption,
                    color = colors.textSecondary,
                )
            }
        } else {
            CloneRunning(
                model = model,
                peer = peer,
                hostLabel = hostLabel,
                sessionId = active,
                status = status,
                statusAttempt = statusAttempt,
                error = error,
                onStatus = { status = it },
                onError = { error = it },
                onRecheck = { statusAttempt += 1 },
                onBack = { sessionId = null; status = null },
                onOpen = { id -> onCloned(id) },
                modifier = Modifier.padding(padding),
            )
        }
    }
    if (picking) {
        FolderPickerScreen(
            model = model,
            peer = peer,
            hostName = hostLabel,
            title = L10n.text("android.clonerepository.where_it_lands.452fbb26"),
            confirm = L10n.text("android.clonerepository.land_it_here.40ae2d76"),
            onClose = { picking = false },
            onChosen = { parent = it; picking = false },
        )
    }
}

private data class CloneStatus(val state: String, val workspaceId: String?, val error: String?)

@Composable
private fun CloneRunning(
    model: AppViewModel,
    peer: String,
    hostLabel: String,
    sessionId: String,
    status: CloneStatus?,
    statusAttempt: Int,
    error: String?,
    onStatus: (CloneStatus?) -> Unit,
    onError: (String?) -> Unit,
    onRecheck: () -> Unit,
    onBack: () -> Unit,
    onOpen: (folderId: String) -> Unit,
    modifier: Modifier = Modifier,
) {
    val colors = LocalTsColors.current
    // The machine registers the folder itself when git exits, so this asks
    // it what happened rather than deciding from what scrolled past. Tied
    // to the view's lifetime, with a timeout instead of sitting on
    // "Cloning…" forever.
    LaunchedEffect(sessionId, statusAttempt) {
        onError(null)
        val deadline = System.currentTimeMillis() + 1_800_000
        while (System.currentTimeMillis() < deadline) {
            val answer = runCatching {
                model.workspaceSection(peer, "workspace.cloneStatus", buildJsonObject {
                    put("sessionId", sessionId)
                }).jsonObject
            }.getOrNull()
            if (answer != null) {
                val next = CloneStatus(
                    state = answer["state"]?.jsonPrimitive?.contentOrNull.orEmpty(),
                    workspaceId = answer["workspaceId"]?.jsonPrimitive?.contentOrNull,
                    error = answer["error"]?.jsonPrimitive?.contentOrNull,
                )
                onStatus(next)
                if (next.state != "running") return@LaunchedEffect
            }
            delay(2_000)
        }
        if (status?.state == "running" || status == null) {
            onError(L10n.text("android.clonerepository.status_checks_stopped_after_30_minutes_the.aff07dba"))
        }
    }
    val headline = when {
        error != null -> L10n.text("android.clonerepository.clone_status_unavailable.a25ebbc8")
        status?.state == "done" -> L10n.text("android.clonerepository.cloned_the_folder_is_registered_on_0.9404dac1", "${hostLabel}")
        status?.state == "failed" -> status?.error ?: L10n.text("android.clonerepository.the_clone_did_not_finish.fa812d0f")
        else -> L10n.text("android.clonerepository.cloning_onto_0.fd24885d", "${hostLabel}")
    }
    Column(modifier.fillMaxSize()) {
        Text(headline, style = TsType.subheadline, color = colors.textSecondary, modifier = Modifier.padding(horizontal = Space.m, vertical = Space.s))
        if (error != null) {
            Column(
                Modifier.padding(horizontal = Space.m),
                verticalArrangement = Arrangement.spacedBy(Space.s),
            ) {
                Text(error, style = TsType.caption, color = colors.textSecondary)
                TsSecondaryButton(label = L10n.text("android.clonerepository.check_status_again.84baa61b"), small = true, onClick = onRecheck)
            }
            Spacer(Modifier.height(Space.s))
        }
        androidx.compose.foundation.layout.Box(Modifier.weight(1f)) {
            TerminalScreen(
                model = model,
                peer = peer,
                hostLabel = hostLabel,
                workspaceId = "",
                existingSessionId = sessionId,
                onClose = {},
            )
        }
        if (status?.state == "done" && status?.workspaceId != null) {
            TsAccentButton(
                label = L10n.text("android.clonerepository.open_the_folder.e241ab00"),
                icon = ActionIcon.Next.vector,
                onClick = { onOpen(status.workspaceId) },
                modifier = Modifier.fillMaxWidth().padding(horizontal = Space.m, vertical = Space.s),
            )
        } else if (status?.state == "failed") {
            TsAccentButton(
                label = L10n.text("common.back"),
                icon = ActionIcon.Back.vector,
                onClick = onBack,
                modifier = Modifier.fillMaxWidth().padding(horizontal = Space.m, vertical = Space.s),
            )
        }
    }
}

/// A folder on the peer to land a clone in, or to register as-is. Ported
/// from the clone picker's shape in `ClientCloneRepository.swift`: browse,
/// up, make a folder, land here.
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun FolderPickerScreen(
    model: AppViewModel,
    peer: String,
    hostName: String,
    title: String,
    confirm: String,
    onClose: () -> Unit,
    onChosen: (path: String) -> Unit,
    notice: String? = null,
) {
    val colors = LocalTsColors.current
    val scope = rememberCoroutineScope()
    var path by remember { mutableStateOf<String?>(null) }
    var parentPath by remember { mutableStateOf<String?>(null) }
    var entries by remember { mutableStateOf(listOf<JsonObject>()) }
    var error by remember { mutableStateOf<String?>(null) }
    var naming by remember { mutableStateOf(false) }
    var newFolder by remember { mutableStateOf("") }
    var creating by remember { mutableStateOf(false) }

    fun load(next: String?) {
        scope.launch {
            error = null
            runCatching {
                model.workspaceSection(peer, "fs.browse", buildJsonObject {
                    if (next != null) put("path", next)
                }).jsonObject
            }.onSuccess { answer ->
                path = answer["path"]?.jsonPrimitive?.contentOrNull
                parentPath = answer["parent"]?.jsonPrimitive?.contentOrNull
                entries = (answer["entries"] as? JsonArray)
                    ?.mapNotNull { it as? JsonObject }
                    ?.filter {
                        it["kind"]?.jsonPrimitive?.contentOrNull == "directory" &&
                            it["hidden"]?.jsonPrimitive?.booleanOrNull != true
                    } ?: emptyList()
            }.onFailure { error = SetupFailure.readable(it) }
        }
    }
    LaunchedEffect(peer) { load(null) }
    BackHandler { onClose() }
    Scaffold(
        containerColor = colors.background,
        topBar = {
            TopAppBar(
                title = { Text(title) },
                navigationIcon = {
                    TsSecondaryButton(label = L10n.text("common.back"), small = true, onClick = onClose)
                },
                actions = {
                    TsSecondaryButton(
                        label = L10n.text("android.clonerepository.new_folder.cf28f49e"),
                        small = true,
                        onClick = { naming = true },
                        enabled = path != null && !creating,
                    )
                },
                colors = TopAppBarDefaults.topAppBarColors(containerColor = colors.background),
            )
        },
        bottomBar = {
            if (path != null) {
                TsAccentButton(
                    label = confirm,
                    icon = ActionIcon.Approve.vector,
                    onClick = { onChosen(path!!) },
                    modifier = Modifier.fillMaxWidth().padding(horizontal = Space.m, vertical = Space.s),
                )
            }
        },
    ) { padding ->
        LazyColumn(Modifier.fillMaxSize().padding(padding), contentPadding = PaddingValues(bottom = TabBarChrome.contentBottomInset)) {
            if (path != null) {
                item {
                    Row(
                        Modifier.fillMaxWidth().padding(horizontal = Space.m, vertical = Space.s),
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(Space.s),
                    ) {
                        if (parentPath != null) {
                            TsSecondaryButton(label = L10n.text("android.clonerepository.up.55490a4b"), small = true, onClick = { load(parentPath) })
                        }
                        Text(
                            path!!,
                            style = TsType.mono(13),
                            color = colors.textPrimary,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis,
                            modifier = Modifier.weight(1f).horizontalScroll(rememberScrollState()),
                        )
                    }
                }
            }
            if (error != null) item { Banner(error!!, BannerSeverity.DANGER, Modifier.padding(horizontal = Space.m)) }
            if (notice != null) item { Banner(notice, BannerSeverity.DANGER, Modifier.padding(horizontal = Space.m)) }
            items(entries, key = { it["path"]?.jsonPrimitive?.contentOrNull ?: it["name"]?.jsonPrimitive?.contentOrNull.orEmpty() }) { entry ->
                Row(
                    Modifier.fillMaxWidth().clickable {
                        entry["path"]?.jsonPrimitive?.contentOrNull?.let { load(it) }
                    }.padding(horizontal = Space.m, vertical = Space.s),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(Space.m),
                ) {
                    Icon(Icons.Default.Folder, null, tint = colors.accent)
                    Text(
                        entry["name"]?.jsonPrimitive?.contentOrNull.orEmpty(),
                        style = TsType.body,
                        color = colors.textPrimary,
                    )
                    Spacer(Modifier.weight(1f))
                    Icon(ActionIcon.Disclosure.vector, null, tint = colors.textTertiary)
                }
            }
        }
    }
    if (naming) {
        val here = path
        AlertDialog(
            onDismissRequest = { naming = false; newFolder = "" },
            title = { Text(L10n.text("android.clonerepository.new_folder.cf28f49e")) },
            text = {
                Column(verticalArrangement = Arrangement.spacedBy(Space.s)) {
                    Text(L10n.text("android.clonerepository.it_is_made_on_0_inside_the_folder_you_are.7077098c", "${hostName}"))
                    OutlinedTextField(
                        value = newFolder,
                        onValueChange = { newFolder = it },
                        placeholder = { Text(L10n.text("android.clonerepository.name.dcd1d522")) },
                        singleLine = true,
                    )
                }
            },
            confirmButton = {
                TextButton(onClick = {
                    val clean = newFolder.trim()
                    newFolder = ""
                    if (clean.isEmpty() || here == null) return@TextButton
                    if (clean.contains("/") || clean.contains("\\") || clean == ".." || clean == ".") {
                        error = L10n.text("android.clonerepository.a_folder_name_is_one_name_without_a_path_i.d41badd4")
                        return@TextButton
                    }
                    naming = false
                    scope.launch {
                        creating = true
                        error = null
                        runCatching {
                            model.workspaceSection(peer, "fs.mkdir", buildJsonObject {
                                put("path", "$here/$clean")
                            }).jsonObject["path"]?.jsonPrimitive?.contentOrNull ?: "$here/$clean"
                        }.onSuccess { made -> load(made) }
                            .onFailure { error = SetupFailure.readable(it) }
                        creating = false
                    }
                }) { Text(L10n.text("android.clonerepository.create.4759498a")) }
            },
            dismissButton = {
                TextButton(onClick = { naming = false; newFolder = "" }) { Text(L10n.text("common.cancel")) }
            },
        )
    }
}

/// Register a folder that is already on the peer. Nothing is copied and
/// nothing is changed.
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun RegisterFolderScreen(
    model: AppViewModel,
    peer: String,
    hostName: String,
    onClose: () -> Unit,
    onRegistered: (folderId: String) -> Unit,
) {
    var registering by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    val scope = rememberCoroutineScope()
    FolderPickerScreen(
        model = model,
        peer = peer,
        hostName = hostName,
        title = L10n.text("android.clonerepository.a_folder_on_0.68442fb8", "${hostName}"),
        confirm = if (registering) L10n.text("android.clonerepository.registering.6bf4d89b") else L10n.text("android.clonerepository.register_this_folder.e273b524"),
        notice = error,
        onClose = onClose,
        onChosen = { picked ->
            scope.launch {
                registering = true
                error = null
                runCatching {
                    model.workspaceSection(peer, "workspace.add", buildJsonObject {
                        put("path", picked)
                    }).jsonObject
                }.onSuccess { folder ->
                    onRegistered(folder["id"]?.jsonPrimitive?.contentOrNull.orEmpty())
                }.onFailure { error = SetupFailure.readable(it) }
                registering = false
            }
        },
    )
}
