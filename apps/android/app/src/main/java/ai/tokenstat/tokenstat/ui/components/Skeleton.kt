// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.components

import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.StartOffset
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import ai.tokenstat.tokenstat.ui.theme.LocalTsColors
import ai.tokenstat.tokenstat.ui.theme.Space
import ai.tokenstat.tokenstat.ui.theme.TsMotion
import ai.tokenstat.tokenstat.ui.theme.cardPadding
import ai.tokenstat.tokenstat.ui.theme.cardRadius
import ai.tokenstat.tokenstat.ui.theme.rememberReduceMotion

private val barShape = RoundedCornerShape(4.dp)

/// One grey bar standing in for a line of text or a number.
///
/// [width] of null fills the space, which is what a title or a row wants. A
/// soft opacity pulse (when motion is allowed) keeps the layout alive without
/// a shimmer that steals attention from the data about to land. [phaseMillis]
/// offsets neighbouring bars so they do not pulse in lockstep.
@Composable
fun SkeletonBar(width: Dp? = null, height: Dp = 12.dp, phaseMillis: Int = 0) {
    val colors = LocalTsColors.current
    val reduceMotion = rememberReduceMotion()
    val transition = rememberInfiniteTransition(label = "skeleton")
    val alpha by transition.animateFloat(
        initialValue = 0.52f,
        targetValue = 1f,
        animationSpec = infiniteRepeatable(
            animation = tween(TsMotion.pulseMillis, easing = TsMotion.easeInOut),
            repeatMode = RepeatMode.Reverse,
            initialStartOffset = StartOffset(phaseMillis),
        ),
        label = "skeletonPulse",
    )
    Box(
        Modifier
            .then(if (width != null) Modifier.width(width) else Modifier.fillMaxWidth())
            .height(height)
            .clip(barShape)
            .background(colors.border)
            .then(if (reduceMotion) Modifier else Modifier.alpha(alpha)),
    )
}

/// A stack of rows, each a label bar and a value bar, like a list. Widths vary
/// down the stack so it reads as text rather than as a bar chart.
/// Deterministic, not random: a placeholder that reshuffles on every redraw is
/// a distraction of its own.
@Composable
fun SkeletonRows(count: Int = 5, showsValue: Boolean = true) {
    val labelWidths = listOf(128.dp, 96.dp, 152.dp, 84.dp, 116.dp, 104.dp)
    Column(verticalArrangement = Arrangement.spacedBy(Space.s)) {
        repeat(count) { index ->
            Row(verticalAlignment = Alignment.CenterVertically) {
                SkeletonBar(
                    width = labelWidths[index % labelWidths.size],
                    phaseMillis = index * 80,
                )
                Spacer(Modifier.weight(1f))
                if (showsValue) SkeletonBar(width = 52.dp, phaseMillis = index * 80 + 40)
            }
        }
    }
}

/// A card-shaped placeholder: heading, subheading, and some rows.
@Composable
fun SkeletonCard(rows: Int = 3) {
    val colors = LocalTsColors.current
    Column(
        Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(cardRadius))
            .background(colors.panel)
            .tsCardBorder()
            .padding(cardPadding),
        verticalArrangement = Arrangement.spacedBy(Space.m),
    ) {
        Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
            SkeletonBar(width = 116.dp, height = 11.dp, phaseMillis = 0)
            SkeletonBar(width = 168.dp, height = 9.dp, phaseMillis = 60)
        }
        SkeletonRows(count = rows)
    }
}
