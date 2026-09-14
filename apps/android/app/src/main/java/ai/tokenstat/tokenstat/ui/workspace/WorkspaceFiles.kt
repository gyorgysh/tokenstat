// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.workspace

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.InsertDriveFile
import androidx.compose.material.icons.filled.Archive
import androidx.compose.material.icons.filled.AudioFile
import androidx.compose.material.icons.filled.Code
import androidx.compose.material.icons.filled.Description
import androidx.compose.material.icons.filled.Folder
import androidx.compose.material.icons.filled.Image
import androidx.compose.material.icons.filled.PictureAsPdf
import androidx.compose.material.icons.filled.VideoFile
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
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
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.unit.sp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import ai.tokenstat.tokenstat.AppViewModel
import ai.tokenstat.tokenstat.ui.components.Banner
import ai.tokenstat.tokenstat.ui.components.BannerSeverity
import ai.tokenstat.tokenstat.ui.components.EmptyState
import ai.tokenstat.tokenstat.ui.components.TsAccentButton
import ai.tokenstat.tokenstat.ui.components.TsSecondaryButton
import ai.tokenstat.tokenstat.ui.components.TsType
import ai.tokenstat.tokenstat.ui.logic.FileIcons
import ai.tokenstat.tokenstat.ui.logic.TunnelCopy
import ai.tokenstat.tokenstat.ui.marks.EmptyArt
import ai.tokenstat.tokenstat.ui.marks.EmptyArtKind
import ai.tokenstat.tokenstat.ui.theme.LocalTsColors
import ai.tokenstat.tokenstat.ui.theme.Space
import kotlinx.coroutines.launch
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put

/// Folder drill with per-type icons, file open, and a single-file editor.
///
/// Ports `ClientFilesView` (phone file list, no editor tabs: those are the
/// iPad presentation) and the `ClientFileEditor` save contract (dirty dot,
/// Save disabled until dirty, discard confirm). The editor names the folder
/// it returns to, so Back lands in context rather than on a bare path.
@Composable
fun FilesSection(
    model: AppViewModel,
    peer: String,
    workspace: String,
    modifier: Modifier = Modifier,
    folderName: String = "",
    hostLabel: String = "",
) {
    val scope = rememberCoroutineScope()
    var path by remember { mutableStateOf("") }
    var entries by remember { mutableStateOf<List<JsonObject>>(emptyList()) }
    var error by remember { mutableStateOf<String?>(null) }
    var loading by remember { mutableStateOf(true) }
    var editing by remember { mutableStateOf<EditTarget?>(null) }

    suspend fun load(at: String) {
        loading = true
        runCatching {
            model.workspaceSection(peer, "workspace.tree", buildJsonObject {
                put("id", workspace); put("path", at)
            })
        }.onSuccess {
            entries = asObjects(it).ifEmpty { asObjects((it as? JsonObject)?.get("entries")) }
            error = null
        }.onFailure { error = TunnelCopy.display(it.message ?: "The request failed.", hostLabel) }
        loading = false
    }
    LaunchedEffect(path) { load(path) }

    LazyColumn(modifier, verticalArrangement = Arrangement.spacedBy(Space.xs)) {
        item { Breadcrumb(folderName.ifBlank { "Files" }, path, onJump = { path = it }) }
        if (path.isNotEmpty()) {
            item {
                TsSecondaryButton(label = "Up", small = true, onClick = {
                    path = path.trimEnd('/').substringBeforeLast('/', "")
                })
            }
        }
        if (error != null) item { Banner(error!!, BannerSeverity.DANGER) }
        if (!loading && entries.isEmpty() && error == null) {
            item {
                EmptyState(
                    Icons.Default.Folder,
                    "Nothing in this folder",
                    "Files an agent writes here show up as it works.",
                    art = { EmptyArt(EmptyArtKind.Files) },
                )
            }
        }
        itemsIndexed(entries, key = { _, entry -> entry.str("path") ?: entry.str("name") ?: entry.hashCode().toString() }) { _, entry ->
            val name = entry.str("name") ?: entry.str("path") ?: return@itemsIndexed
            val child = entry.str("path") ?: listOf(path, name).filter { it.isNotBlank() }.joinToString("/")
            val dir = entry.bol("dir") || entry.bol("isDir") || entry.str("kind") == "dir" || entry.str("type") == "dir"
            Column {
                Row(
                    Modifier
                        .fillMaxWidth()
                        .clickable {
                            if (dir) {
                                path = child
                            } else {
                                scope.launch {
                                    runCatching {
                                        val read = model.workspaceSection(peer, "workspace.read", buildJsonObject {
                                            put("id", workspace); put("path", child)
                                        }) as? JsonObject
                                        editing = EditTarget(
                                            path = child,
                                            body = read?.str("content") ?: "",
                                        )
                                    }.onFailure { error = TunnelCopy.display(it.message ?: "The request failed.", hostLabel) }
                                }
                            }
                        }
                        .padding(vertical = Space.xs),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(Space.s),
                ) {
                    Icon(
                        fileIcon(name, dir),
                        if (dir) "Open folder $name" else "Open file $name",
                        tint = if (dir) LocalTsColors.current.accent else LocalTsColors.current.textSecondary,
                    )
                    Column(Modifier.weight(1f)) {
                        Text(name, style = TsType.mono(12), color = LocalTsColors.current.textPrimary, maxLines = 1)
                        if (dir) {
                            Text(
                                "Folder",
                                style = TextStyle(fontSize = 11.sp),
                                color = LocalTsColors.current.textTertiary,
                            )
                        }
                    }
                }
                HorizontalDivider(color = LocalTsColors.current.border)
            }
        }
    }
    val target = editing
    if (target != null) {
        FileEditorDialog(
            target = target,
            folderName = folderName,
            onDismiss = { editing = null },
            onSave = { body ->
                scope.launch {
                    runCatching {
                        model.workspaceSection(peer, "workspace.write", buildJsonObject {
                            put("id", workspace)
                            put("path", target.path)
                            put("content", body)
                        })
                    }.onSuccess { editing = null }
                        .onFailure { error = TunnelCopy.display(it.message ?: "The request failed.", hostLabel) }
                }
            },
        )
    }
}

private data class EditTarget(val path: String, val body: String)

private fun fileIcon(name: String, isDir: Boolean): ImageVector {
    if (isDir) return Icons.Default.Folder
    return when (FileIcons.keyFor(name, false)) {
        "code" -> Icons.Default.Code
        "text" -> Icons.Default.Description
        "image" -> Icons.Default.Image
        "audio" -> Icons.Default.AudioFile
        "video" -> Icons.Default.VideoFile
        "pdf" -> Icons.Default.PictureAsPdf
        "archive" -> Icons.Default.Archive
        else -> Icons.AutoMirrored.Filled.InsertDriveFile
    }
}

@Composable
private fun Breadcrumb(root: String, path: String, onJump: (String) -> Unit) {
    val segments = path.split('/').filter { it.isNotEmpty() }
    Row(
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(Space.xs),
    ) {
        TextButton(onClick = { onJump("") }) {
            Text(root, color = if (segments.isEmpty()) LocalTsColors.current.textPrimary else LocalTsColors.current.accent)
        }
        segments.forEachIndexed { index, segment ->
            Text("/", color = LocalTsColors.current.textTertiary)
            val full = segments.take(index + 1).joinToString("/")
            TextButton(onClick = { onJump(full) }) {
                Text(
                    segment,
                    maxLines = 1,
                    color = if (index == segments.lastIndex) LocalTsColors.current.textPrimary else LocalTsColors.current.accent,
                )
            }
        }
    }
}

/// One file to read and write, with the way back named. Save stays disabled
/// until the text differs from what the host sent, and closing with edits
/// asks first, like `ClientFileEditor` ("Discard changes?").
@Composable
private fun FileEditorDialog(
    target: EditTarget,
    folderName: String,
    onDismiss: () -> Unit,
    onSave: (String) -> Unit,
) {
    var body by remember(target.path) { mutableStateOf(target.body) }
    var saving by remember { mutableStateOf(false) }
    var confirmClose by remember { mutableStateOf(false) }
    val dirty = body != target.body
    val fileName = target.path.substringAfterLast('/')
    val parent = target.path.substringBeforeLast('/', "")

    fun close() {
        if (dirty) confirmClose = true else onDismiss()
    }

    Dialog(onDismissRequest = ::close, properties = DialogProperties(usePlatformDefaultWidth = false)) {
        Column(
            Modifier
                .fillMaxSize()
                .padding(Space.m),
            verticalArrangement = Arrangement.spacedBy(Space.s),
        ) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Column(Modifier.weight(1f)) {
                    Text(fileName, style = TsType.mono(13), color = LocalTsColors.current.textPrimary, maxLines = 1)
                    Text(
                        listOfNotNull(
                            folderName.takeIf { it.isNotBlank() }?.let { "Back to $it" },
                            parent.takeIf { it.isNotBlank() },
                        ).joinToString(" · ").ifBlank { "Back" },
                        style = TextStyle(fontSize = 11.sp),
                        color = LocalTsColors.current.accent,
                        maxLines = 1,
                    )
                }
                if (dirty) {
                    Text("Unsaved", style = TextStyle(fontSize = 11.sp), color = LocalTsColors.current.warning)
                }
            }
            OutlinedTextField(
                body,
                { body = it },
                modifier = Modifier
                    .fillMaxWidth()
                    .weight(1f),
                textStyle = TsType.mono(12),
                minLines = 12,
            )
            Row(horizontalArrangement = Arrangement.spacedBy(Space.s)) {
                TsSecondaryButton(label = "Close", small = true, onClick = ::close)
                TsAccentButton(
                    label = if (saving) "Saving…" else "Save",
                    small = true,
                    enabled = dirty && !saving,
                    onClick = {
                        saving = true
                        onSave(body)
                    },
                )
            }
        }
    }
    if (confirmClose) {
        androidx.compose.material3.AlertDialog(
            onDismissRequest = { confirmClose = false },
            title = { Text("Discard changes?") },
            text = { Text("${target.path} has edits that are not saved on the host.") },
            confirmButton = {
                TextButton(onClick = { confirmClose = false; onDismiss() }) { Text("Discard") }
            },
            dismissButton = {
                TextButton(onClick = { confirmClose = false }) { Text("Keep editing") }
            },
        )
    }
}
