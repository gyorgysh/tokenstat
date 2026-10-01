// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.marks

import ai.tokenstat.tokenstat.ui.localization.L10n
import ai.tokenstat.tokenstat.ui.theme.LocalTsColors
import ai.tokenstat.tokenstat.ui.theme.rememberReduceMotion
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.collectIsPressedAsState
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.IconButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.drawscope.rotate
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.unit.dp

/// The toolbar account control shares the plan badge and press ring with Apple.
@Composable
fun AccountAvatarButton(
    name: String,
    avatarUrl: String?,
    signedIn: Boolean,
    tier: String?,
    onClick: () -> Unit,
) {
    val colors = LocalTsColors.current
    val plan = if (signedIn) tier.orEmpty().trim().lowercase() else ""
    val showsPlan = tierKind(plan) != TierKind.None
    val interaction = remember { MutableInteractionSource() }
    val pressed by interaction.collectIsPressedAsState()
    val reduceMotion = rememberReduceMotion()
    val ring by animateFloatAsState(
        if (pressed && showsPlan) 1f else 0f,
        animationSpec = tween(if (reduceMotion) 0 else 300),
        label = "accountPress",
    )
    val sweep = remember(colors.accent, colors.secondary) {
        Brush.sweepGradient(listOf(colors.accent, colors.secondary, colors.accent))
    }
    IconButton(
        onClick = onClick,
        interactionSource = interaction,
        modifier = Modifier.semantics {
            contentDescription = if (signedIn) L10n.text("android.marks.account_0.1342b321", name)
                else L10n.text("android.marks.sign_in_to_tokenstat.9a950fc4")
            if (showsPlan) stateDescription = L10n.text("android.tiermark.0_tier.c75a2e12", plan.replaceFirstChar { it.uppercase() })
        },
    ) {
        Box(Modifier.size(40.dp), contentAlignment = Alignment.Center) {
            Box(
                Modifier.size(38.dp)
                    .shadow(2.dp, CircleShape)
                    .clip(CircleShape)
                    .background(colors.panel)
                    .border(1.dp, colors.border, CircleShape),
                contentAlignment = Alignment.Center,
            ) {
                Avatar(name, size = 34, avatarUrl = avatarUrl, signedIn = signedIn, decorative = true)
            }
            if (showsPlan) {
                Canvas(Modifier.size(38.dp)) {
                    val width = 1.5.dp.toPx()
                    rotate(if (reduceMotion) 0f else ring * 120f) {
                        drawCircle(sweep, radius = (size.minDimension - width) / 2f, alpha = ring, style = Stroke(width))
                    }
                }
                Box(
                    Modifier.align(Alignment.BottomEnd).size(16.dp)
                        .clip(CircleShape)
                        .background(colors.panel)
                        .border(1.dp, colors.border, CircleShape)
                        .clearAndSetSemantics {},
                    contentAlignment = Alignment.Center,
                ) {
                    TierMark(plan, markSize = 10)
                }
            }
        }
    }
}
