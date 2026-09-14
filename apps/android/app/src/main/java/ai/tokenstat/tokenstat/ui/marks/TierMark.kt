// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.marks

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.size
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.PathFillType
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp

/// Which silhouette a tier wears. Transcribed from the website's badge paths
/// via Apple's `BadgeShape`: a crest shield for Patron, a star for Supporter,
/// a crown for Legend. Free has no mark at all, and a tier this build does
/// not know still gets a seal rather than looking downgraded.
enum class TierKind {
    Crown, Star, Shield, Seal, None,
}

fun tierKind(tier: String): TierKind = when (tier.lowercase()) {
    "legend" -> TierKind.Crown
    "patron" -> TierKind.Shield
    "supporter" -> TierKind.Star
    "free", "" -> TierKind.None
    else -> TierKind.Seal
}

/// The tier as the silhouette the website puts beside a name, filled with the
/// logo's own two strongest bars top to bottom. Points are absolute in the
/// website's 24 unit square, matching `BadgeShape.path`.
@Composable
fun TierMark(tier: String, markSize: Int = 15) {
    val kind = tierKind(tier)
    if (kind == TierKind.None) return
    // Fixed pair, not the adaptive tokens: Apple fills from these two hexes.
    val fill = remember {
        Brush.verticalGradient(listOf(Color(0xFF8B5CF6), Color(0xFFC026D3)))
    }
    Canvas(
        Modifier
            .size(markSize.dp)
            .semantics { contentDescription = "${tier.lowercase().replaceFirstChar { it.uppercase() }} tier" },
    ) {
        val unit = size.minDimension / 24f
        fun pt(x: Float, y: Float) = Offset(x * unit, y * unit)
        when (kind) {
            TierKind.Crown -> {
                // The band, and the bar under it, as two closed subpaths.
                val band = Path().apply {
                    val outline = listOf(
                        3f to 7.4f, 7.6f to 10.6f, 12f to 3.4f, 16.4f to 10.6f,
                        21f to 7.4f, 19.3f to 18.6f, 4.7f to 18.6f,
                    )
                    val first = pt(outline[0].first, outline[0].second)
                    moveTo(first.x, first.y)
                    for (i in 1 until outline.size) {
                        val q = pt(outline[i].first, outline[i].second)
                        lineTo(q.x, q.y)
                    }
                    close()
                    val bar = listOf(
                        4.7f to 20.1f, 19.3f to 20.1f, 19.3f to 22f, 4.7f to 22f,
                    )
                    val start = pt(bar[0].first, bar[0].second)
                    moveTo(start.x, start.y)
                    for (i in 1 until bar.size) {
                        val q = pt(bar[i].first, bar[i].second)
                        lineTo(q.x, q.y)
                    }
                    close()
                }
                drawPath(band, fill)
            }
            TierKind.Star -> {
                val star = Path().apply {
                    val p = listOf(
                        12f to 2.6f, 14.7f to 8.5f, 21f to 9.2f, 16.3f to 13.5f,
                        17.6f to 19.8f, 12f to 16.7f, 6.4f to 19.8f, 7.7f to 13.5f,
                        3f to 9.2f, 9.3f to 8.5f,
                    )
                    val first = pt(p[0].first, p[0].second)
                    moveTo(first.x, first.y)
                    for (i in 1 until p.size) {
                        val q = pt(p[i].first, p[i].second)
                        lineTo(q.x, q.y)
                    }
                    close()
                }
                drawPath(star, fill)
            }
            TierKind.Shield -> {
                // Crest shield with a chevron cut out of it. The cut is wound
                // against the shield under an even-odd fill, so it stays open.
                val shield = Path().apply {
                    fillType = PathFillType.EvenOdd
                    fun to(x: Float, y: Float) {
                        val q = pt(x, y)
                        lineTo(q.x, q.y)
                    }
                    fun curve(
                        c1x: Float, c1y: Float, c2x: Float, c2y: Float,
                        x: Float, y: Float,
                    ) {
                        val c1 = pt(c1x, c1y)
                        val c2 = pt(c2x, c2y)
                        val end = pt(x, y)
                        cubicTo(c1.x, c1.y, c2.x, c2.y, end.x, end.y)
                    }
                    val a = pt(12f, 2.1f)
                    moveTo(a.x, a.y)
                    to(20.4f, 4.9f)
                    to(20.4f, 11f)
                    curve(20.4f, 16.1f, 16.8f, 20.2f, 12f, 21.9f)
                    curve(7.2f, 20.2f, 3.6f, 16.1f, 3.6f, 11f)
                    to(3.6f, 4.9f)
                    close()
                    val cut = pt(7.9f, 9.2f)
                    moveTo(cut.x, cut.y)
                    to(7.9f, 11.9f)
                    to(12f, 16f)
                    to(16.1f, 11.9f)
                    to(16.1f, 9.2f)
                    to(12f, 13.3f)
                    close()
                }
                drawPath(shield, fill)
            }
            TierKind.Seal -> {
                drawCircle(
                    brush = fill,
                    radius = 8f * unit,
                    center = pt(12f, 12f),
                )
            }
            TierKind.None -> Unit
        }
    }
}
