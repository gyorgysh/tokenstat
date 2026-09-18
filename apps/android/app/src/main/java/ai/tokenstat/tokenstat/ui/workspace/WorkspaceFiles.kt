// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.workspace

import ai.tokenstat.tokenstat.ui.chrome.TabBarChrome
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
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
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.sp
import ai.tokenstat.tokenstat.AppViewModel
import ai.tokenstat.tokenstat.ui.components.Banner
import ai.tokenstat.tokenstat.ui.components.BannerSeverity
import ai.tokenstat.tokenstat.ui.components.EmptyState
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

/// Folder drill with per-type icons and file open, port of `ClientFilesView`.
///
/// Tapping a file opens the full-page `WorkspaceFileEditorPage`, the port of
/// the iOS phone editor (find and replace, save states, conflict handling,
/// discard confirm). The editor names the folder it returns to, so Back
/// lands in context rather than on a bare path.
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
    var editing by remember { mutableStateOf<String?>(null) }

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

    val open = editing
    if (open != null) {
        WorkspaceFileEditorPage(
            model = model,
            peer = peer,
            workspace = workspace,
            folderName = folderName,
            hostLabel = hostLabel,
            path = open,
            modifier = modifier,
            onClose = { editing = null },
            onSavedFile = { scope.launch { load(path) } },
        )
        return
    }

    LazyColumn(modifier, contentPadding = PaddingValues(bottom = TabBarChrome.contentBottomInset), verticalArrangement = Arrangement.spacedBy(Space.xs)) {
        // At the root the breadcrumb is just the folder name, which the
        // pushed header above already shows as its subtitle. It earns its row
        // once you are inside something.
        if (path.isNotEmpty()) {
            item { Breadcrumb(folderName.ifBlank { "Files" }, path, onJump = { path = it }) }
        }
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
                                editing = child
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
}

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
                    overflow = TextOverflow.Ellipsis,
                    color = if (index == segments.lastIndex) LocalTsColors.current.textPrimary else LocalTsColors.current.accent,
                )
            }
        }
    }
}
