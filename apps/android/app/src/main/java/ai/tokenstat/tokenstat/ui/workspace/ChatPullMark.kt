// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.workspace

import ai.tokenstat.tokenstat.ui.components.TsBottomSheet
import ai.tokenstat.tokenstat.AppViewModel
import ai.tokenstat.tokenstat.ui.components.ActionIcon
import ai.tokenstat.tokenstat.ui.components.BrandCheckbox
import ai.tokenstat.tokenstat.ui.components.SegmentedCapsulePicker
import ai.tokenstat.tokenstat.ui.components.TsCard
import ai.tokenstat.tokenstat.ui.components.TsProminentButton
import ai.tokenstat.tokenstat.ui.components.TsSecondaryButton
import ai.tokenstat.tokenstat.ui.components.TsType
import ai.tokenstat.tokenstat.ui.localization.L10n
import ai.tokenstat.tokenstat.ui.theme.LocalTsColors
import ai.tokenstat.tokenstat.ui.theme.Space
import ai.tokenstat.tokenstat.ui.theme.TsColors
import android.content.Context
import android.content.Intent
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.foundation.layout.size
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
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
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import androidx.core.net.toUri
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject

internal fun chatPulls(chat: JsonObject): List<JsonObject> =
    (chat["pulls"] as? JsonArray)?.filterIsInstance<JsonObject>()?.takeIf { it.isNotEmpty() }
        ?: listOfNotNull(chat["pull"] as? JsonObject)

internal fun leadPull(pulls: List<JsonObject>): JsonObject? =
    pulls.firstOrNull { it.str("state") == "open" && !it.bol("draft") }
        ?: pulls.firstOrNull { it.str("state") == "open" }
        ?: pulls.firstOrNull { it.str("state") == "merged" }
        ?: pulls.firstOrNull()

internal fun pullName(pull: JsonObject): String {
    val number = pull.str("number").orEmpty()
    val repo = pull.str("repo")
        ?: pull.str("url")?.removePrefix("https://")?.split("/")?.takeIf { it.size >= 3 }?.let { "${it[1]}/${it[2]}" }
    return if (repo == null) "#$number" else "$repo #$number"
}

internal fun pullTint(pull: JsonObject, colors: TsColors): Color = when (pull.str("state")) {
    "merged" -> if (colors.isDark) Color(0xFFA371F7) else Color(0xFF8250DF)
    "closed" -> if (colors.isDark) Color(0xFFF85149) else Color(0xFFCF222E)
    else -> if (pull.bol("draft")) colors.stateIdle else if (colors.isDark) Color(0xFF3FB950) else Color(0xFF1A7F37)
}

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

@Composable
fun ChatPullMark(chat: JsonObject, peer: String, hostLabel: String = "") {
    val pulls = chatPulls(chat)
    val lead = leadPull(pulls) ?: return
    val colors = LocalTsColors.current
    val context = LocalContext.current
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
                            PullSummaryLine(pull)
                        }
                    },
                    onClick = {
                        open = false
                        openPull(context, pull, peer, hostLabel)
                    },
                )
            }
        }
    }
}

internal enum class PullOpenChoice(val key: String) {
    Ask("ask"),
    Here("here"),
    Browser("browser");

    val label: String
        get() = when (this) {
            Ask -> L10n.text("common.pulls.open_in_ask")
            Here -> "tokenstat"
            Browser -> L10n.text("common.pulls.open_in_browser")
        }

    companion object {
        private fun prefs(context: Context) = context.getSharedPreferences("tokenstat.chat.v1", Context.MODE_PRIVATE)

        fun of(key: String?) = entries.firstOrNull { it.key == key } ?: Ask

        fun read(context: Context) = of(prefs(context).getString("pullsOpenIn", null))

        fun write(context: Context, choice: PullOpenChoice) {
            prefs(context).edit().putString("pullsOpenIn", choice.key).apply()
        }
    }
}

internal object PullOpener {
    data class Request(val peer: String, val workspace: String, val hostLabel: String, val pull: JsonObject)

    var asking by mutableStateOf<Request?>(null)
    var request by mutableStateOf<Request?>(null)
}

private fun browse(context: Context, pull: JsonObject) {
    val url = pull.str("url")?.takeIf { it.startsWith("https://") } ?: return
    runCatching { context.startActivity(Intent(Intent.ACTION_VIEW, url.toUri())) }
}

private fun openPull(context: Context, pull: JsonObject, peer: String, hostLabel: String) {
    val folder = pull.str("workspaceId") ?: return browse(context, pull)
    val request = PullOpener.Request(peer, folder, hostLabel, pull)
    when (PullOpenChoice.read(context)) {
        PullOpenChoice.Ask -> PullOpener.asking = request
        PullOpenChoice.Here -> PullOpener.request = request
        PullOpenChoice.Browser -> browse(context, pull)
    }
}

@Composable
private fun PullSummaryLine(pull: JsonObject) {
    val colors = LocalTsColors.current
    Row(horizontalArrangement = Arrangement.spacedBy(Space.xs), verticalAlignment = Alignment.CenterVertically) {
        PullGlyph(pull.str("state"), pullTint(pull, colors), 12.dp)
        Text(branchPullState(pull), style = TsType.caption2, color = pullTint(pull, colors))
        Text(pullName(pull), style = TsType.caption2, color = colors.textSecondary)
        pull.str("additions")?.let { Text("+$it", style = TsType.caption2, color = colors.diffAdded) }
        pull.str("deletions")?.let { Text("−$it", style = TsType.caption2, color = colors.diffRemoved) }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun PullOpenSheet(request: PullOpener.Request) {
    val colors = LocalTsColors.current
    val context = LocalContext.current
    var keep by remember(request) { mutableStateOf(false) }
    fun pick(choice: PullOpenChoice) {
        if (keep) PullOpenChoice.write(context, choice)
        PullOpener.asking = null
        if (choice == PullOpenChoice.Here) PullOpener.request = request else browse(context, request.pull)
    }
    TsBottomSheet(onDismissRequest = { PullOpener.asking = null }, containerColor = colors.background) {
        Column(
            Modifier.fillMaxWidth().padding(horizontal = Space.l).padding(bottom = Space.xl),
            verticalArrangement = Arrangement.spacedBy(Space.m),
        ) {
            Text(L10n.text("common.pulls.open_title"), style = TsType.headline, color = colors.textPrimary)
            Column(verticalArrangement = Arrangement.spacedBy(Space.xs)) {
                Text(request.pull.str("title").orEmpty(), style = TsType.body, color = colors.textPrimary,
                    maxLines = 2, overflow = TextOverflow.Ellipsis)
                PullSummaryLine(request.pull)
            }
            Column(verticalArrangement = Arrangement.spacedBy(Space.xs)) {
                BrandCheckbox(keep, { keep = !keep }, L10n.text("common.pulls.open_remember"))
                Text(L10n.text("common.pulls.open_remember_help"), style = TsType.caption, color = colors.textSecondary)
            }
            TsProminentButton(L10n.text("common.pulls.view_here"), onClick = { pick(PullOpenChoice.Here) },
                icon = ActionIcon.Merge.vector, modifier = Modifier.fillMaxWidth())
            TsSecondaryButton(L10n.text("common.pulls.open_browser"), onClick = { pick(PullOpenChoice.Browser) },
                icon = ActionIcon.External.vector, modifier = Modifier.fillMaxWidth())
        }
    }
}

@Composable
internal fun PullOpenCard() {
    val context = LocalContext.current
    var choice by remember { mutableStateOf(PullOpenChoice.read(context)) }
    TsCard(title = L10n.text("common.pulls.open_in")) {
        SegmentedCapsulePicker(
            options = PullOpenChoice.entries.map { Triple(it, it.label, null as ImageVector?) },
            selection = choice,
            onSelect = { choice = it; PullOpenChoice.write(context, it) },
        )
    }
}

@Composable
internal fun PullOpenerHost(model: AppViewModel) {
    DisposableEffect(Unit) { onDispose { PullOpener.request = null; PullOpener.asking = null } }
    PullOpener.asking?.let { PullOpenSheet(it) }
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
