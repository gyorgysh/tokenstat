// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.workspace

import ai.tokenstat.tokenstat.R
import ai.tokenstat.tokenstat.ui.chrome.TabBarChrome
import ai.tokenstat.tokenstat.ui.components.ActionIcon
import ai.tokenstat.tokenstat.ui.components.TsSecondaryButton
import ai.tokenstat.tokenstat.ui.components.TsType
import ai.tokenstat.tokenstat.ui.localization.L10n
import ai.tokenstat.tokenstat.ui.logic.DiffDocumentPage
import ai.tokenstat.tokenstat.ui.logic.DiffDocumentRow
import ai.tokenstat.tokenstat.ui.logic.DiffDocumentRows
import ai.tokenstat.tokenstat.ui.theme.LocalTsColors
import ai.tokenstat.tokenstat.ui.theme.Space
import android.graphics.Paint
import androidx.compose.foundation.background
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.core.content.res.ResourcesCompat
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.JsonObject

/// The fixed metadata and code have separate scroll coordinates. Only the
/// bounded, lazy code pane can pan sideways, with one offset for every line.
@Composable
internal fun DiffDocumentView(
    diffs: List<JsonObject>,
    modifier: Modifier = Modifier,
    fileHeaders: Boolean = true,
    header: @Composable ColumnScope.() -> Unit,
) {
    val context = LocalContext.current
    val density = LocalDensity.current
    val fontPixels = with(density) { 13.sp.toPx() }
    var limit by remember(diffs) { mutableIntStateOf(2000) }
    var page by remember(diffs) { mutableStateOf(DiffDocumentPage(emptyList(), 0)) }
    var textWidth by remember(diffs) { mutableFloatStateOf(0f) }
    var preparing by remember(diffs) { mutableStateOf(true) }
    val horizontal = rememberScrollState()
    val vertical = androidx.compose.foundation.lazy.rememberLazyListState()
    LaunchedEffect(diffs) { horizontal.scrollTo(0); vertical.scrollToItem(0) }
    LaunchedEffect(diffs, limit, fileHeaders, fontPixels) {
        preparing = true
        val result = withContext(Dispatchers.Default) {
            val job = currentCoroutineContext()
            val next = DiffDocumentRows.page(diffs, fileHeaders, limit,
                maxLineUnits = (8000 / fontPixels).toInt().coerceIn(2, 1024)) { job.ensureActive() }
            val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
                typeface = ResourcesCompat.getFont(context, R.font.jetbrainsmono_variable)
                textSize = fontPixels
            }
            var width = 0f
            next.rows.forEach {
                job.ensureActive()
                if (it.kind == DiffDocumentRow.Kind.Line) width = maxOf(width, paint.measureText(it.text))
            }
            next to width
        }
        page = result.first
        textWidth = result.second
        preparing = false
    }
    BoxWithConstraints(modifier.fillMaxSize().padding(bottom = TabBarChrome.contentBottomInset)) {
        val gutter = with(density) { (fontPixels * 5.5f).toDp() }
        val documentWidth = maxOf(maxWidth, with(density) { textWidth.toDp() } + gutter + Space.s * 2)
        val headerLimit = maxHeight * 0.4f
        Column(Modifier.fillMaxSize(), verticalArrangement = Arrangement.spacedBy(Space.s)) {
            Column(
                Modifier.fillMaxWidth().heightIn(max = headerLimit).verticalScroll(rememberScrollState()),
                verticalArrangement = Arrangement.spacedBy(Space.s),
                content = header,
            )
            androidx.compose.foundation.layout.Box(Modifier.weight(1f).fillMaxWidth()) {
                LazyColumn(
                    Modifier.horizontalScroll(horizontal).width(documentWidth).fillMaxSize(),
                    state = vertical,
                ) {
                    items(page.rows, key = { it.key }) { row -> DiffRow(row, gutter) }
                }
                if (preparing && page.rows.isEmpty()) CircularProgressIndicator(Modifier.align(Alignment.Center))
            }
            if (page.total > limit) {
                TsSecondaryButton(
                    label = L10n.text("android.diffdocumentview.show_more_rows", minOf(2000L, page.total - limit), page.total - limit),
                    icon = ActionIcon.Reveal.vector,
                    onClick = { limit = (limit.toLong() + 2000).coerceAtMost(Int.MAX_VALUE.toLong()).toInt() },
                    enabled = !preparing,
                )
            }
        }
    }
}

@Composable
private fun DiffRow(row: DiffDocumentRow, gutter: androidx.compose.ui.unit.Dp) {
    val colors = LocalTsColors.current
    if (row.kind == DiffDocumentRow.Kind.Line) {
        val tint = when (row.change) { "added" -> colors.diffAdded; "removed" -> colors.diffRemoved; else -> colors.textPrimary }
        val wash = if (row.change == "added" || row.change == "removed") tint.copy(alpha = 0.12f) else Color.Transparent
        Row(Modifier.fillMaxWidth().background(wash).padding(horizontal = Space.s, vertical = 1.dp)) {
            val marker = when (row.change) { "added" -> "+"; "removed" -> "−"; else -> " " }
            val number = if (row.continuation) "↳" else row.number?.toString() ?: "·"
            Text("$number $marker", style = TsType.mono(13), color = colors.textTertiary, maxLines = 1, modifier = Modifier.width(gutter))
            Text(row.text.ifEmpty { " " }, style = TsType.mono(13), color = tint, maxLines = 1, softWrap = false)
        }
    } else {
        val text = when (row.kind) {
            DiffDocumentRow.Kind.Binary -> L10n.text("android.workspacehistory.this_is_a_binary_file_there_is_nothing_to.6573d54c")
            DiffDocumentRow.Kind.Empty -> L10n.text("android.workspacechanges.no_changes_against_head.84a982f2")
            DiffDocumentRow.Kind.Untracked -> L10n.text("android.workspacechanges.this_file_is_not_tracked_yet_and_is_empty.7354c94b")
            else -> row.text
        }
        Text(text, style = if (row.kind == DiffDocumentRow.Kind.File) TsType.subheadline else TsType.mono(13),
            color = colors.textSecondary,
            maxLines = if (row.kind == DiffDocumentRow.Kind.File || row.kind == DiffDocumentRow.Kind.Hunk) 1 else Int.MAX_VALUE,
            overflow = TextOverflow.Ellipsis,
            modifier = Modifier.fillMaxWidth().background(colors.panel).padding(Space.s))
    }
}
