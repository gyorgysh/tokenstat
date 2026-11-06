// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.workspace

import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.tween
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.drawWithContent
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.graphics.BlendMode
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Paint
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.drawscope.clipRect
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.TextStyle
import android.os.SystemClock

internal data class ArrivingWord(val start: Int, val end: Int, val born: Long?)
private class StreamingWordPaths {
    var values: List<Pair<ArrivingWord, Path>> = emptyList()
}
internal class StreamingWordArrivals {
    private var previous: String? = null
    private var words = emptyList<ArrivingWord>()
    fun update(text: String, now: Long): List<ArrivingWord> {
        val old = previous
        val append = old != null && text.startsWith(old)
        var index = 0
        val next = mutableListOf<ArrivingWord>()
        while (index < text.length) {
            if (text[index].isWhitespace()) { index++; continue }
            val start = index
            while (index < text.length && !text[index].isWhitespace()) index++
            val prior = if (append) words.getOrNull(next.size)?.takeIf { it.start == start } else null
            val born = if (!append) null else if (prior != null) prior.born else now
            next += ArrivingWord(start, index, born?.takeIf { now - it < 220 })
        }
        if (old != null && old.startsWith(text) && old != text) {
            words = words.map { it.copy(born = null) }
            return next.map { it.copy(born = null) }
        }
        previous = text
        words = next
        return next
    }
}

/** Draw a fading mask over new words; never change text or remeasure per frame. */
@Composable
internal fun StreamingText(text: AnnotatedString, style: TextStyle, modifier: Modifier, live: Boolean,
                           nowMillis: () -> Long = SystemClock::uptimeMillis) {
    if (!live) {
        Text(text, style = style, modifier = modifier)
        return
    }
    val arrivals = remember { StreamingWordArrivals() }
    val words = remember(text.text) { arrivals.update(text.text, nowMillis()) }
    val active = remember(words, text) {
        words.filter { it.born != null && text.getLinkAnnotations(it.start, it.end).isEmpty() &&
            text.getStringAnnotations("tokenstat.noFade", it.start, it.end).isEmpty() }
    }
    val clock = remember { Animatable(0f) }
    val paint = remember { Paint() }
    val geometry = remember { StreamingWordPaths() }
    LaunchedEffect(text.text) {
        if (active.isNotEmpty()) {
            clock.snapTo(0f)
            clock.animateTo(1f, tween(220))
        }
    }
    Text(text, style = style, modifier = modifier.drawWithContent {
        // Reading animation state invalidates drawing only.
        val tick = clock.value
        val now = nowMillis()
        val paths = geometry.values
        if (paths.isEmpty() || (tick >= 1f && active.all { now - it.born!! >= 220 })) {
            drawContent()
        } else {
            val top = paths.minOf { it.second.getBounds().top }.coerceIn(0f, size.height)
            val bottom = paths.maxOf { it.second.getBounds().bottom }.coerceIn(top, size.height)
            clipRect(bottom = top) { this@drawWithContent.drawContent() }
            clipRect(top = bottom) { this@drawWithContent.drawContent() }
            // A long paragraph must not allocate a full-height animation
            // texture. Only the lines containing arriving words need a layer.
            clipRect(top = top, bottom = bottom) {
                drawContext.canvas.saveLayer(Rect(0f, top, size.width, bottom), paint)
                this@drawWithContent.drawContent()
                for ((word, path) in paths) {
                    val progress = ((now - word.born!!) / 220f).coerceIn(0f, 1f)
                    val remaining = 1f - progress
                    drawPath(path, Color.Black.copy(alpha = .8f * remaining * remaining * remaining), blendMode = BlendMode.DstOut)
                }
                drawContext.canvas.restore()
            }
        }
    }, onTextLayout = { layout ->
        // Layout runs before drawing. Store geometry directly so the first
        // frame of a word is faded too, without an extra composition pass.
        geometry.values = active.map { it to layout.getPathForRange(it.start, it.end) }
    })
}
