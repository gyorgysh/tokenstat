// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.marks

import androidx.compose.material.icons.filled.Terminal

import androidx.compose.material.icons.Icons

import ai.tokenstat.tokenstat.ui.logic.harnessCanonicalID
import ai.tokenstat.tokenstat.ui.logic.harnessName
import ai.tokenstat.tokenstat.ui.theme.LocalTsColors
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

/// A harness brand tile, ported from Design/Marks.swift `HarnessMark`: the
/// product's vector mark on an accent tile, or the initial letter when the
/// harness has no artwork. The drawables are transcribed from the same SVGs
/// the Apple client ships in Brands.xcassets.
@Composable
fun HarnessMark(id: String, size: Dp = 26.dp) {
    val colors = LocalTsColors.current
    val context = LocalContext.current
    // Estimate / rollup rows belong to the same brand as the live source.
    val canonical = when (val c = harnessCanonicalID(id)) {
        "claude_code_estimate", "claude_code_rollup" -> "claude_code"
        else -> c
    }
    val res = remember(canonical) {
        if (canonical.isEmpty()) {
            0
        } else {
            context.resources.getIdentifier("brand_$canonical", "drawable", context.packageName)
        }
    }
    // A shell is not a brand, so it has no artwork and fell through to the
    // initial-letter path: the launch grid showed a plain "S" where every
    // other tile showed a mark. The Apple grid draws it as a terminal glyph
    // with no brand tile behind it, because there is no brand to tile.
    if (canonical == "shell") {
        Box(Modifier.size(size), contentAlignment = Alignment.Center) {
            Icon(
                Icons.Default.Terminal,
                harnessName(id),
                tint = colors.accent,
                modifier = Modifier.size(size * 0.82f),
            )
        }
        return
    }
    Box(
        Modifier
            .size(size)
            .clip(RoundedCornerShape(size * 0.28f))
            .background(colors.accent.copy(alpha = 0.12f)),
        contentAlignment = Alignment.Center,
    ) {
        if (res != 0) {
            Icon(
                painterResource(res),
                harnessName(id),
                tint = colors.accent,
                modifier = Modifier.size(size * 0.58f),
            )
        } else {
            val initial = harnessName(id).firstOrNull()?.uppercase() ?: "?"
            Text(
                initial,
                style = TextStyle(
                    fontSize = (size.value * 0.46f).sp,
                    fontWeight = FontWeight.SemiBold,
                ),
                color = colors.accent,
            )
        }
    }
}
