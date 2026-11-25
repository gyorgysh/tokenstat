// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.workspace

import ai.tokenstat.tokenstat.ui.components.ActionIcon
import ai.tokenstat.tokenstat.ui.components.TsCard
import ai.tokenstat.tokenstat.ui.components.TsSecondaryButton
import ai.tokenstat.tokenstat.ui.localization.L10n
import ai.tokenstat.tokenstat.ui.theme.LocalTsColors
import ai.tokenstat.tokenstat.ui.theme.Space
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.platform.LocalUriHandler
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put

internal data class GitLfsStatus(val installed: Boolean, val configured: Boolean, val canInstall: Boolean) {
    val ready get() = installed && configured
    val needsInstall get() = !installed && canInstall
}

internal fun JsonObject?.gitLfsStatus(): GitLfsStatus? = (this?.get("lfs") as? JsonObject)?.let {
    GitLfsStatus(it.bol("installed"), it.bol("configured"), it.bol("canInstall"))
}

internal suspend fun setupGitLfs(request: suspend (String, JsonObject) -> JsonElement, workspace: String, status: GitLfsStatus) {
    gitFormRequest(request, "workspace.lfsSetup", buildJsonObject {
        put("id", workspace)
        put("allowInstall", status.needsInstall)
    })
}

@Composable
internal fun GitLfsSetupCard(status: GitLfsStatus, working: Boolean, onSetup: () -> Unit, onCheck: () -> Unit) {
    val uri = LocalUriHandler.current
    val colors = LocalTsColors.current
    TsCard(title = L10n.text("android.gitlfs.title")) {
        Column(verticalArrangement = Arrangement.spacedBy(Space.s)) {
            val message = when {
                status.ready -> L10n.text("android.gitlfs.ready")
                status.installed -> L10n.text("android.gitlfs.enable_help")
                status.canInstall -> L10n.text("android.gitlfs.install_help")
                else -> L10n.text("android.gitlfs.manual_help")
            }
            Text(message, style = MaterialTheme.typography.bodySmall, color = colors.textSecondary)
            if (!status.ready) {
                if (status.installed || status.canInstall) {
                    TsSecondaryButton(
                        label = if (status.installed) L10n.text("android.gitlfs.enable") else L10n.text("android.gitlfs.install"),
                        icon = ActionIcon.Download.vector, enabled = !working, onClick = onSetup,
                    )
                } else {
                    TsSecondaryButton(
                        label = L10n.text("android.gitlfs.guide"), enabled = !working,
                        onClick = { runCatching { uri.openUri("https://git-lfs.com/") } },
                    )
                }
                TsSecondaryButton(label = L10n.text("android.gitlfs.check"), icon = ActionIcon.Refresh.vector, enabled = !working, onClick = onCheck)
            }
        }
    }
}
