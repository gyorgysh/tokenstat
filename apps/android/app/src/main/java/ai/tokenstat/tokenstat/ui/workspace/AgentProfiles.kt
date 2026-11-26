// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.workspace

import ai.tokenstat.tokenstat.AppViewModel
import ai.tokenstat.tokenstat.ui.components.TsPickerField
import ai.tokenstat.tokenstat.ui.localization.L10n
import ai.tokenstat.tokenstat.ui.logic.HostContracts
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Text
import androidx.compose.foundation.background
import androidx.compose.material.icons.filled.AccountCircle
import androidx.compose.material.icons.filled.KeyboardArrowDown
import androidx.compose.material.icons.filled.Lock
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.ui.draw.clip
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import androidx.compose.runtime.*
import kotlinx.coroutines.CancellationException
import kotlinx.serialization.json.*

internal data class AgentProfile(val id: String, val name: String, val own: Set<String>, val platform: String?) {
    val title: String get() = if (id != "system") name else when (platform) {
        "macos" -> L10n.text("common.profiles.this_mac")
        "windows" -> L10n.text("common.profiles.this_pc")
        else -> L10n.text("common.profiles.this_computer")
    }
}

internal class AgentProfiles(value: JsonObject) {
    val defaultId = value.str("default") ?: "system"
    val profiles = (value["profiles"] as? JsonArray).orEmpty().mapNotNull { entry ->
        val profile = entry as? JsonObject ?: return@mapNotNull null
        val id = profile.str("id") ?: return@mapNotNull null
        val own = (profile["own"] as? JsonArray).orEmpty().mapNotNull { (it as? JsonPrimitive)?.contentOrNull }.toSet()
        AgentProfile(id, profile.str("name").orEmpty(), own, profile.str("platform"))
    }
    private val locks = value["workspaceLocks"] as? JsonObject
    fun byId(id: String?): AgentProfile? = profiles.find { it.id == id }
    fun title(id: String?): String = byId(id)?.title ?: L10n.text("common.profiles.removed")
    fun locked(workspace: String?): String? = workspace?.let { locks?.str(it) }
}

@Composable
internal fun rememberAgentProfiles(model: AppViewModel, peer: String, protocol: Long?): AgentProfiles? {
    var value by remember(model, peer, protocol) { mutableStateOf<AgentProfiles?>(null) }
    LaunchedEffect(model, peer, protocol) {
        if (peer.isBlank() || !HostContracts.supportsAgentProfiles(protocol)) return@LaunchedEffect
        try {
            value = (model.workspaceSection(peer, "profiles.list", buildJsonObject {}) as? JsonObject)?.let(::AgentProfiles)
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (_: Exception) {
            // The normal agent controls are still available.
        }
    }
    return value
}

internal fun ownAgentProfile(profiles: AgentProfiles?, id: String?, launcher: String?): String? {
    if (id == null || id == "system") return null
    return id.takeIf { profiles?.byId(id)?.own?.contains(launcher) != false }
}

internal fun agentProfileTitle(profiles: AgentProfiles?, id: String?): String? =
    id?.takeIf { it != "system" }?.let { profiles?.title(it) ?: L10n.text("common.profiles.named_limits") }

internal fun withAgentProfile(summary: String, profiles: AgentProfiles?, id: String?): String =
    agentProfileTitle(profiles, id)?.let { "$summary · $it" } ?: summary

@Composable
internal fun AgentProfilePicker(profiles: AgentProfiles, selected: String?, lock: String?,
    enabled: Boolean, onChange: (String) -> Unit,
) {
    if (profiles.profiles.size < 2 && (selected == null || selected == "system") && lock == null) return
    if (lock != null && lock == selected) {
        Text(L10n.text("common.profiles.locked", profiles.title(lock)))
        return
    }
    var open by remember { mutableStateOf(false) }
    val active = selected ?: profiles.defaultId
    Box {
        TsPickerField(
            summary = L10n.text("common.profiles.label") + " · " + profiles.title(active),
            enabled = enabled,
            onOpen = { open = true },
        )
        DropdownMenu(expanded = open, onDismissRequest = { open = false }) {
            profiles.profiles.filter { lock == null || it.id == lock }.forEach { profile ->
                DropdownMenuItem(
                    text = { Text(profile.title) },
                    enabled = profile.id != active,
                    onClick = { open = false; onChange(profile.id) },
                )
            }
        }
    }
}

/// Which login the listed agents run as, as a small chip on the picker's
/// caption line. A locked repository shows its profile with a lock and no
/// menu. Port of the Apple `profileMenu`.
@Composable
internal fun AgentProfileChip(profiles: AgentProfiles, selected: String?, lock: String?,
    enabled: Boolean, onChange: (String) -> Unit,
) {
    if (profiles.profiles.size < 2 && (selected == null || selected == "system") && lock == null) return
    val colors = ai.tokenstat.tokenstat.ui.theme.LocalTsColors.current
    val active = lock ?: selected ?: profiles.defaultId
    var open by remember { mutableStateOf(false) }
    Box {
        androidx.compose.foundation.layout.Row(
            androidx.compose.ui.Modifier
                .clip(androidx.compose.foundation.shape.CircleShape)
                .background(if (lock != null) colors.panel else colors.accentSoft)
                .clickable(enabled = enabled && lock == null, role = androidx.compose.ui.semantics.Role.Button) { open = true }
                .semantics { contentDescription = L10n.text("common.profiles.label") + ", " + profiles.title(active) }
                .heightIn(min = 32.dp)
                .padding(horizontal = 10.dp, vertical = 4.dp),
            verticalAlignment = androidx.compose.ui.Alignment.CenterVertically,
            horizontalArrangement = androidx.compose.foundation.layout.Arrangement.spacedBy(4.dp),
        ) {
            androidx.compose.material3.Icon(
                if (lock != null) androidx.compose.material.icons.Icons.Default.Lock
                else androidx.compose.material.icons.Icons.Default.AccountCircle,
                null, tint = if (lock != null) colors.textSecondary else colors.accent,
                modifier = androidx.compose.ui.Modifier.size(14.dp),
            )
            Text(profiles.title(active), style = ai.tokenstat.tokenstat.ui.components.TsType.caption,
                color = if (lock != null) colors.textSecondary else colors.accent, maxLines = 1)
            if (lock == null) androidx.compose.material3.Icon(
                androidx.compose.material.icons.Icons.Default.KeyboardArrowDown, null,
                tint = colors.accent, modifier = androidx.compose.ui.Modifier.size(14.dp),
            )
        }
        DropdownMenu(expanded = open, onDismissRequest = { open = false }) {
            profiles.profiles.forEach { profile ->
                DropdownMenuItem(
                    text = { Text(profile.title) },
                    enabled = profile.id != active,
                    onClick = { open = false; onChange(profile.id) },
                )
            }
        }
    }
}
