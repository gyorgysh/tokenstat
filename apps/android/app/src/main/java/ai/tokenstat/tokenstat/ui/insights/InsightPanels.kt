// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.insights

import ai.tokenstat.tokenstat.ui.components.TsType
import ai.tokenstat.tokenstat.ui.components.cardRadiusDp
import ai.tokenstat.tokenstat.ui.components.tsPanel
import ai.tokenstat.tokenstat.ui.logic.InsightFactPanel
import ai.tokenstat.tokenstat.ui.marks.FeatureMark
import ai.tokenstat.tokenstat.ui.theme.LocalTsColors
import ai.tokenstat.tokenstat.ui.theme.Space
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.IntrinsicSize
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.TextAutoSize
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.sp

/// One panel per figure, not one card holding every figure. Port of
/// `ClientStatPanels`: three panels read as three facts. They always sit
/// in one equal-width row, each keeps its own card, and each says which
/// fact it is with a mark from the house vocabulary.
@Composable
fun InsightStatPanels(panels: List<InsightFactPanel>, modifier: Modifier = Modifier) {
    Row(
        modifier.fillMaxWidth().height(IntrinsicSize.Max),
        horizontalArrangement = Arrangement.spacedBy(Space.s),
    ) {
        panels.forEach { panel(it) }
    }
}

@Composable
private fun RowScope.panel(item: InsightFactPanel) {
    val colors = LocalTsColors.current
    Row(
        modifier = Modifier
            .weight(1f)
            .fillMaxHeight()
            .clip(RoundedCornerShape(cardRadiusDp))
            .tsPanel()
            .padding(Space.s)
            .semantics(mergeDescendants = true) {
                contentDescription = "${item.label}, ${item.value}"
            },
        verticalAlignment = Alignment.Top,
        horizontalArrangement = Arrangement.spacedBy(Space.xs),
    ) {
        Column(Modifier.weight(1f)) {
            // The shared-row figure, shrinking the way
            // `minimumScaleFactor(0.5)` lets it on iOS: a compact value
            // is short by construction, but a narrow phone still has
            // to fit it beside the mark.
            Text(
                item.value,
                style = TsType.numeric(22, FontWeight.SemiBold),
                color = colors.accent,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
                softWrap = false,
                autoSize = TextAutoSize.StepBased(
                    minFontSize = 11.sp,
                    maxFontSize = 22.sp,
                    stepSize = 1.sp,
                ),
            )
            Text(
                item.label,
                style = TsType.caption,
                color = colors.textSecondary,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
                softWrap = false,
                autoSize = TextAutoSize.StepBased(
                    minFontSize = 8.sp,
                    maxFontSize = 12.sp,
                    stepSize = 1.sp,
                ),
            )
        }
        // Trailing, not leading. The figure is what the card is for,
        // and every panel lines its number up on the same left edge.
        // A mark in front would push each one in by a different
        // amount. It also fills the room a short number leaves behind.
        FeatureMark(name = item.mark, size = 22)
    }
}
