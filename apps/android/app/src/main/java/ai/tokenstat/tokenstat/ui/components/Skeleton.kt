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
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.ui.draw.drawWithContent
import androidx.compose.ui.graphics.BlendMode
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.CompositingStrategy
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import ai.tokenstat.tokenstat.ui.localization.L10n
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
    // Reduce Motion holds the bar still at full strength, like Apple's nil
    // animation, rather than running a loop nobody sees.
    val alpha = if (reduceMotion) {
        1f
    } else {
        val transition = rememberInfiniteTransition(label = "skeleton")
        val pulse by transition.animateFloat(
            initialValue = 0.52f,
            targetValue = 1f,
            animationSpec = infiniteRepeatable(
                animation = tween(TsMotion.pulseMillis, easing = TsMotion.easeInOut),
                repeatMode = RepeatMode.Reverse,
                initialStartOffset = StartOffset(phaseMillis),
            ),
            label = "skeletonPulse",
        )
        pulse
    }
    Box(
        Modifier
            .then(if (width != null) Modifier.width(width) else Modifier.fillMaxWidth())
            .height(height)
            .clip(barShape)
            .background(colors.border)
            .alpha(alpha),
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
            .background(colors.panel.copy(alpha = 0.6f))
            .padding(cardPadding)
            .alpha(0.75f),
        verticalArrangement = Arrangement.spacedBy(Space.m),
    ) {
        Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
            SkeletonBar(width = 116.dp, height = 10.dp, phaseMillis = 0)
            SkeletonBar(width = 168.dp, height = 8.dp, phaseMillis = 60)
        }
        SkeletonRows(count = rows)
    }
}

/// A page of cards still on their way, fading out towards the bottom.
@Composable
fun SkeletonPage(count: Int = 4, rows: Int = 2) {
    Column(
        Modifier
            .fillMaxWidth()
            .graphicsLayer { compositingStrategy = CompositingStrategy.Offscreen }
            .drawWithContent {
                drawContent()
                drawRect(
                    Brush.verticalGradient(0.4f to Color.Black, 1f to Color.Transparent),
                    blendMode = BlendMode.DstIn,
                )
            },
        verticalArrangement = Arrangement.spacedBy(Space.s),
    ) {
        repeat(count) { SkeletonCard(rows = rows) }
    }
}

private data class SkeletonTurn(val mine: Boolean, val lines: Int)

private val transcriptTurns = listOf(
    SkeletonTurn(false, 3), SkeletonTurn(true, 1), SkeletonTurn(false, 5), SkeletonTurn(true, 2),
    SkeletonTurn(false, 2), SkeletonTurn(false, 4), SkeletonTurn(true, 1), SkeletonTurn(false, 3),
)
private val transcriptWidths = listOf(0.94f, 0.86f, 0.71f, 0.9f, 0.58f, 0.8f)
private val transcriptLine = 9.dp
private val transcriptLineGap = 9.dp
private val transcriptTurnGap = 22.dp
private val transcriptBubblePadding = 12.dp

/// Loading placeholder for a chat. Fills the pane, newest turn at the bottom.
@Composable
fun TranscriptSkeleton(modifier: Modifier = Modifier) {
    val colors = LocalTsColors.current
    val label = L10n.text("android.pulldetail.loading_conversation.5eb1e4a3")
    BoxWithConstraints(
        modifier
            .fillMaxSize()
            .padding(horizontal = Space.l, vertical = Space.l)
            .semantics { contentDescription = label }
            .graphicsLayer { compositingStrategy = CompositingStrategy.Offscreen; alpha = 0.7f }
            .drawWithContent {
                drawContent()
                drawRect(
                    Brush.verticalGradient(0f to Color.Transparent, 0.38f to Color.Black),
                    blendMode = BlendMode.DstIn,
                )
            },
    ) {
        val lane = maxWidth
        var used = 0.dp
        var count = 0
        while (used < maxHeight && count < 40) {
            val turn = transcriptTurns[count % transcriptTurns.size]
            used += (transcriptLine + transcriptLineGap) * turn.lines - transcriptLineGap +
                (if (turn.mine) transcriptBubblePadding * 2 else 0.dp) + transcriptTurnGap
            count += 1
        }
        Column(
            Modifier.fillMaxSize(),
            verticalArrangement = Arrangement.spacedBy(transcriptTurnGap, Alignment.Bottom),
        ) {
            for (index in (0 until maxOf(count, 1)).reversed()) {
                val turn = transcriptTurns[index % transcriptTurns.size]
                val span = if (turn.mine) lane * 0.5f else lane
                val lines: @Composable () -> Unit = {
                    Column(verticalArrangement = Arrangement.spacedBy(transcriptLineGap)) {
                        repeat(turn.lines) { line ->
                            SkeletonBar(
                                width = span * transcriptWidths[(index * 2 + line) % transcriptWidths.size],
                                height = transcriptLine,
                                phaseMillis = (index % transcriptTurns.size) * 110 + line * 50,
                            )
                        }
                    }
                }
                if (turn.mine) {
                    Row(Modifier.fillMaxWidth()) {
                        Spacer(Modifier.weight(1f))
                        Box(
                            Modifier
                                .width(span + transcriptBubblePadding * 2)
                                .clip(RoundedCornerShape(16.dp))
                                .background(colors.accentSoft.copy(alpha = 0.55f))
                                .padding(transcriptBubblePadding),
                        ) { lines() }
                    }
                } else {
                    lines()
                }
            }
        }
    }
}
