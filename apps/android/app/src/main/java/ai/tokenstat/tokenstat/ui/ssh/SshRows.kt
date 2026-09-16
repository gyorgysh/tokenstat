// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.ssh

import ai.tokenstat.tokenstat.ui.components.ActionIcon
import ai.tokenstat.tokenstat.ui.components.TsCard
import ai.tokenstat.tokenstat.ui.components.TsSecondaryButton
import ai.tokenstat.tokenstat.ui.theme.LocalTsColors
import ai.tokenstat.tokenstat.ui.theme.Space
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.width
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Computer
import androidx.compose.material.icons.filled.Key
import androidx.compose.material.icons.filled.Star
import androidx.compose.material.icons.filled.Terminal
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.booleanOrNull

/// The tail, not the whole line. A full SHA256 fingerprint is wider than a
/// phone, so the row prints what comes after the `SHA256:` prefix, which is
/// the part you compare against. Port of `SSHLibraryView.shortFingerprint`.
fun shortFingerprint(value: String?): String? {
    if (value.isNullOrEmpty()) return null
    val separator = value.indexOf(":")
    if (separator < 0) return value
    return value.substring(separator + 1).takeIf { it.isNotEmpty() } ?: value
}

@Composable
private fun SshRowShell(
    title: String,
    subtitle: String?,
    onOpen: () -> Unit,
    leading: @Composable () -> Unit,
    menu: @Composable (close: () -> Unit) -> Unit,
    trailing: @Composable (() -> Unit)? = null,
) {
    val colors = LocalTsColors.current
    var open by remember { mutableStateOf(false) }
    TsCard(Modifier.clickable { onOpen() }) {
        Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.fillMaxWidth()) {
            leading()
            Spacer(Modifier.width(Space.m))
            Column(Modifier.weight(1f)) {
                Text(title, fontWeight = FontWeight.SemiBold, color = colors.textPrimary, maxLines = 1)
                subtitle?.let {
                    Text(it, style = MaterialTheme.typography.bodySmall, color = colors.textSecondary, maxLines = 1)
                }
            }
            trailing?.let { it() }
            IconButton(onClick = { open = true }) {
                Icon(ActionIcon.More.vector, "More actions", tint = colors.textSecondary)
            }
            DropdownMenu(expanded = open, onDismissRequest = { open = false }) {
                menu { open = false }
            }
        }
    }
}

/// One saved server: its name, where it points, a Connect button that stays
/// visible, and the long-press menu as a popup: connect, favourites, edit,
/// delete. Port of `SSHHostRow` plus `hostRow`'s context menu.
@Composable
fun SshHostRow(
    host: JsonObject,
    folderName: String?,
    searching: Boolean,
    onConnect: () -> Unit,
    onEdit: () -> Unit,
    onDelete: () -> Unit,
    onToggleFavorite: () -> Unit,
) {
    val colors = LocalTsColors.current
    val favorite = (host["favorite"] as? kotlinx.serialization.json.JsonPrimitive)?.booleanOrNull == true
    SshRowShell(
        title = host.sshString("label") ?: "SSH host",
        subtitle = "${host.sshString("username") ?: "root"}@${host.sshString("hostname") ?: ""}:${host["port"]?.toString() ?: "22"}" +
            if (searching && folderName != null) " · $folderName" else "",
        onOpen = onConnect,
        leading = {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Icon(Icons.Default.Computer, null, tint = colors.accent)
                if (favorite) {
                    Icon(Icons.Default.Star, "Favourite", tint = colors.warning)
                }
            }
        },
        trailing = {
            TsSecondaryButton(label = "Connect", small = true, onClick = onConnect)
        },
        menu = { close ->
            DropdownMenuItem(text = { Text("Connect") }, onClick = { close(); onConnect() })
            DropdownMenuItem(
                text = { Text(if (favorite) "Remove from favourites" else "Add to favourites") },
                onClick = { close(); onToggleFavorite() },
            )
            DropdownMenuItem(text = { Text("Edit") }, onClick = { close(); onEdit() })
            DropdownMenuItem(
                text = { Text("Delete", color = colors.danger) },
                onClick = { close(); onDelete() },
            )
        },
    )
}

/// One saved key: its label and the fingerprint tail. Copying the public key
/// is the reason to open one at all, so it has a shortcut rather than hiding
/// behind the editor. Port of `keyRow`.
@Composable
fun SshKeyRow(
    key: JsonObject,
    onEdit: () -> Unit,
    onCopyPublic: () -> Unit,
    onCopyFingerprint: () -> Unit,
    onDelete: () -> Unit,
) {
    val colors = LocalTsColors.current
    val fingerprint = key.sshString("fingerprint").orEmpty()
    SshRowShell(
        title = key.sshString("label") ?: "Key",
        subtitle = shortFingerprint(fingerprint) ?: key.sshString("algorithm") ?: "Key",
        onOpen = onEdit,
        leading = { Icon(Icons.Default.Key, null, tint = colors.accent) },
        menu = { close ->
            DropdownMenuItem(text = { Text("Edit") }, onClick = { close(); onEdit() })
            DropdownMenuItem(text = { Text("Copy public key") }, onClick = { close(); onCopyPublic() })
            if (fingerprint.isNotEmpty()) {
                DropdownMenuItem(text = { Text("Copy fingerprint") }, onClick = { close(); onCopyFingerprint() })
            }
            DropdownMenuItem(
                text = { Text("Delete", color = colors.danger) },
                onClick = { close(); onDelete() },
            )
        },
    )
}

/// One saved command. Port of `snippetRow`.
@Composable
fun SshSnippetRow(
    snippet: JsonObject,
    onEdit: () -> Unit,
    onCopy: () -> Unit,
    onToggleRunOnConnect: () -> Unit,
    onDelete: () -> Unit,
) {
    val colors = LocalTsColors.current
    val runOnConnect = (snippet["runOnConnect"] as? kotlinx.serialization.json.JsonPrimitive)?.booleanOrNull == true
    SshRowShell(
        title = snippet.sshString("title") ?: "Snippet",
        subtitle = snippet.sshString("command").orEmpty(),
        onOpen = onEdit,
        leading = { Icon(Icons.Default.Terminal, null, tint = colors.accent) },
        menu = { close ->
            DropdownMenuItem(text = { Text("Edit") }, onClick = { close(); onEdit() })
            DropdownMenuItem(text = { Text("Copy command") }, onClick = { close(); onCopy() })
            DropdownMenuItem(
                text = { Text(if (runOnConnect) "Do not run on connect" else "Run on connect") },
                onClick = { close(); onToggleRunOnConnect() },
            )
            DropdownMenuItem(
                text = { Text("Delete", color = colors.danger) },
                onClick = { close(); onDelete() },
            )
        },
    )
}
