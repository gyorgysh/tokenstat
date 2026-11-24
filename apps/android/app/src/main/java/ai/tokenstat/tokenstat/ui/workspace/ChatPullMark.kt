// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.workspace

import ai.tokenstat.tokenstat.AppViewModel
import ai.tokenstat.tokenstat.ui.components.ActionIcon
import ai.tokenstat.tokenstat.ui.components.TsType
import ai.tokenstat.tokenstat.ui.localization.L10n
import ai.tokenstat.tokenstat.ui.theme.LocalTsColors
import ai.tokenstat.tokenstat.ui.theme.Space
import ai.tokenstat.tokenstat.ui.theme.TsColors
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.foundation.layout.size
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.StrokeJoin
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.platform.LocalUriHandler
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject

/// Every pull request a chat opened or talked about, newest first. A host
/// older than 1.26.0 only knows the branch's own.
internal fun chatPulls(chat: JsonObject): List<JsonObject> =
    (chat["pulls"] as? JsonArray)?.filterIsInstance<JsonObject>()?.takeIf { it.isNotEmpty() }
        ?: listOfNotNull(chat["pull"] as? JsonObject)

/// The one whose state a row shows: work still open first, then merged.
internal fun leadPull(pulls: List<JsonObject>): JsonObject? =
    pulls.firstOrNull { it.str("state") == "open" && !it.bol("draft") }
        ?: pulls.firstOrNull { it.str("state") == "open" }
        ?: pulls.firstOrNull { it.str("state") == "merged" }
        ?: pulls.firstOrNull()

/// `owner/repo #53`, read from the address when the host did not say.
internal fun pullName(pull: JsonObject): String {
    val number = pull.str("number").orEmpty()
    val repo = pull.str("repo")
        ?: pull.str("url")?.removePrefix("https://")?.split("/")?.takeIf { it.size >= 3 }?.let { "${it[1]}/${it[2]}" }
    return if (repo == null) "#$number" else "$repo #$number"
}

/// A pull request's state in the colours every forge uses for it. Read by
/// colour alone, like a diff, so they do not follow the theme.
internal fun pullTint(pull: JsonObject, colors: TsColors): Color = when (pull.str("state")) {
    "merged" -> if (colors.isDark) Color(0xFFA371F7) else Color(0xFF8250DF)
    "closed" -> if (colors.isDark) Color(0xFFF85149) else Color(0xFFCF222E)
    else -> if (pull.bol("draft")) colors.stateIdle else if (colors.isDark) Color(0xFF3FB950) else Color(0xFF1A7F37)
}

/// The same drawing as the Apple `PullGlyph`, on its sixteen unit grid.
@Composable
internal fun PullGlyph(state: String?, tint: Color, size: Dp, modifier: Modifier = Modifier) {
    Canvas(modifier.size(size)) {
        val unit = this.size.minDimension / 16f
        fun at(x: Float, y: Float) = Offset(x * unit, y * unit)
        val stroke = Stroke(1.35f * unit, cap = StrokeCap.Round, join = StrokeJoin.Round)
        fun dot(x: Float, y: Float) = drawCircle(tint, 1.75f * unit, at(x, y), style = stroke)
        fun line(vararg points: Pair<Float, Float>) {
            val path = Path()
            points.forEachIndexed { i, (x, y) -> at(x, y).let { if (i == 0) path.moveTo(it.x, it.y) else path.lineTo(it.x, it.y) } }
            drawPath(path, tint, style = stroke)
        }
        dot(4f, 3.5f)
        dot(4f, 12.5f)
        line(4f to 5.25f, 4f to 10.75f)
        when (state) {
            "merged" -> {
                dot(12f, 9f)
                drawPath(Path().apply {
                    moveTo(4f * unit, 5.25f * unit)
                    cubicTo(4.2f * unit, 7.6f * unit, 6.8f * unit, 9f * unit, 10.25f * unit, 9f * unit)
                }, tint, style = stroke)
            }
            "closed" -> {
                dot(12f, 12.5f)
                line(12f to 7.75f, 12f to 10.75f)
                line(10.2f to 1.9f, 13.8f to 5.5f)
                line(13.8f to 1.9f, 10.2f to 5.5f)
            }
            else -> {
                dot(12f, 12.5f)
                drawPath(Path().apply {
                    moveTo(8.25f * unit, 3.5f * unit)
                    lineTo(10.25f * unit, 3.5f * unit)
                    quadraticTo(12f * unit, 3.5f * unit, 12f * unit, 5.25f * unit)
                    lineTo(12f * unit, 10.75f * unit)
                }, tint, style = stroke)
                line(10.1f to 1.4f, 8f to 3.5f, 10.1f to 5.6f)
            }
        }
    }
}

/// The mark on a chat row: the state, and how many when there are several.
/// A tap lists them. Drawing it never asks the forge.
@Composable
fun ChatPullMark(chat: JsonObject, peer: String, hostLabel: String = "") {
    val pulls = chatPulls(chat)
    val lead = leadPull(pulls) ?: return
    val colors = LocalTsColors.current
    val uri = LocalUriHandler.current
    var open by remember(chat.str("id")) { mutableStateOf(false) }
    val spoken = pulls.joinToString(", ") {
        L10n.text("android.branchpull.help", branchPullState(it), it.str("number").orEmpty(), it.str("title").orEmpty())
    }
    Box {
        Row(
            Modifier
                .clickable(role = Role.Button) { open = true }
                .semantics { contentDescription = spoken }
                .padding(horizontal = 6.dp, vertical = 10.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(3.dp),
        ) {
            PullGlyph(lead.str("state"), pullTint(lead, colors), 15.dp)
            if (pulls.size > 1) {
                Text("${pulls.size}", style = TsType.caption, color = colors.textSecondary,
                    modifier = Modifier.clearAndSetSemantics {})
            }
        }
        DropdownMenu(open, onDismissRequest = { open = false }) {
            pulls.forEach { pull ->
                DropdownMenuItem(
                    text = {
                        Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
                            Text(pull.str("title").orEmpty(), style = TsType.caption, color = colors.textPrimary,
                                maxLines = 1, overflow = TextOverflow.Ellipsis)
                            Row(horizontalArrangement = Arrangement.spacedBy(Space.xs), verticalAlignment = Alignment.CenterVertically) {
                                PullGlyph(pull.str("state"), pullTint(pull, colors), 12.dp)
                                Text(branchPullState(pull), style = TsType.caption2, color = pullTint(pull, colors))
                                Text(pullName(pull), style = TsType.caption2, color = colors.textSecondary)
                                pull.str("additions")?.let { Text("+$it", style = TsType.caption2, color = colors.diffAdded) }
                                pull.str("deletions")?.let { Text("−$it", style = TsType.caption2, color = colors.diffRemoved) }
                            }
                        }
                    },
                    trailingIcon = {
                        IconButton(onClick = {
                            open = false
                            pull.str("url")?.takeIf { it.startsWith("https://") }?.let { runCatching { uri.openUri(it) } }
                        }) {
                            Icon(ActionIcon.External.vector, L10n.text("android.branchpull.open_browser"),
                                tint = colors.textSecondary, modifier = Modifier.size(16.dp))
                        }
                    },
                    onClick = {
                        open = false
                        val folder = pull.str("workspaceId")
                        if (folder != null) {
                            PullOpener.request = PullOpener.Request(peer, folder, hostLabel, pull)
                        } else {
                            pull.str("url")?.takeIf { it.startsWith("https://") }?.let { runCatching { uri.openUri(it) } }
                        }
                    },
                )
            }
        }
    }
}

/// The pull request somebody asked to see from a chat list. One at a time,
/// shown over whatever screen they were on.
internal object PullOpener {
    data class Request(val peer: String, val workspace: String, val hostLabel: String, val pull: JsonObject)

    var request by mutableStateOf<Request?>(null)
}

@Composable
internal fun PullOpenerHost(model: AppViewModel) {
    // Leaving the signed-in app must not leave one waiting for the next account.
    DisposableEffect(Unit) { onDispose { PullOpener.request = null } }
    val request = PullOpener.request ?: return
    val number = request.pull.str("number")?.toLongOrNull() ?: return
    val dismiss = { PullOpener.request = null }
    Dialog(
        onDismissRequest = dismiss,
        properties = DialogProperties(usePlatformDefaultWidth = false, decorFitsSystemWindows = false),
    ) {
        Surface(Modifier.fillMaxSize(), color = LocalTsColors.current.background) {
            PullDetailPage(
                model = model,
                peer = request.peer,
                workspace = request.workspace,
                hostLabel = request.hostLabel,
                number = number,
                modifier = Modifier.safeDrawingPadding().padding(horizontal = Space.m),
                summary = request.pull,
                onBack = dismiss,
            )
        }
    }
}
