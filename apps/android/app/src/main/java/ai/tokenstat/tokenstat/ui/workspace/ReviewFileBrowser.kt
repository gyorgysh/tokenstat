// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.workspace

import ai.tokenstat.tokenstat.ui.theme.LocalTsColors
import ai.tokenstat.tokenstat.ui.components.TsType
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.Orientation
import androidx.compose.foundation.gestures.draggable
import androidx.compose.foundation.gestures.rememberDraggableState
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp

/**
 * One file at a time, like the Mac `ReviewFileBrowser`: a file list beside
 * the diff on wide screens, with a width the person can drag, and nothing
 * extra on narrow ones, where [content] shows its own picker. [content] gets
 * `true` when it should show that picker.
 */
@Composable
internal fun ReviewFileBrowser(
    paths: List<String>,
    selected: String?,
    onSelect: (String) -> Unit,
    modifier: Modifier = Modifier,
    content: @Composable (compact: Boolean) -> Unit,
) {
    BoxWithConstraints(modifier) {
        if (paths.isEmpty() || maxWidth < 560.dp) {
            content(true)
            return@BoxWithConstraints
        }
        val colors = LocalTsColors.current
        val density = LocalDensity.current
        val most = (maxWidth.value * 0.5f).coerceAtLeast(160f).coerceAtMost(420f)
        var width by rememberSaveable { mutableFloatStateOf(220f) }
        val shown = width.coerceIn(160f, most)
        Row(Modifier.fillMaxSize()) {
            LazyColumn(Modifier.width(shown.dp).fillMaxHeight().background(colors.panel).padding(4.dp)) {
                items(paths, key = { it }) { path ->
                    val isSelected = path == selected
                    Column(
                        Modifier.fillMaxWidth()
                            .background(if (isSelected) colors.accentSoft else colors.panel, RoundedCornerShape(6.dp))
                            .semantics { this.selected = isSelected }
                            .clickable { onSelect(path) }
                            .padding(horizontal = 8.dp, vertical = 6.dp),
                    ) {
                        Text(path.substringAfterLast('/'), style = TsType.caption, color = colors.textPrimary,
                            maxLines = 1, overflow = TextOverflow.Ellipsis)
                        val folder = path.substringBeforeLast('/', "")
                        if (folder.isNotEmpty()) Text(folder, style = TsType.caption, color = colors.textSecondary,
                            maxLines = 1, overflow = TextOverflow.Ellipsis)
                    }
                }
            }
            // A one point rule with a wider grab area, so the list can be resized.
            Box(
                Modifier.width(9.dp).fillMaxHeight().draggable(
                    orientation = Orientation.Horizontal,
                    state = rememberDraggableState { delta -> width = (width.coerceIn(160f, most) + with(density) { delta.toDp().value }).coerceIn(160f, most) },
                ),
            ) {
                Box(Modifier.width(1.dp).fillMaxHeight().background(colors.border).align(androidx.compose.ui.Alignment.Center))
            }
            Box(Modifier.weight(1f).fillMaxHeight()) { content(false) }
        }
    }
}
