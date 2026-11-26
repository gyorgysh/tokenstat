// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.workspace

import ai.tokenstat.tokenstat.AppViewModel
import ai.tokenstat.tokenstat.ui.components.TsPickerField
import ai.tokenstat.tokenstat.ui.localization.L10n
import ai.tokenstat.tokenstat.ui.logic.HostContracts
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Text
import androidx.compose.foundation.layout.Box
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
