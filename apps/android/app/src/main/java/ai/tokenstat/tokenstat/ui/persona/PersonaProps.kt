// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.persona

import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.drawscope.Stroke
import kotlin.math.PI
import kotlin.math.cos
import kotlin.math.sin

/** Props face the character; their backs face us. Small marks omit them. */
internal fun DrawScope.drawPersonaProps(mood: PersonaMood, time: Double, hue: Color, opacity: Float) {
    val ink = hue.copy(alpha = opacity * 0.90f)
    val fill = hue.copy(alpha = opacity * 0.28f)
    val stroke = Stroke(width = size.minDimension * 0.022f)
    fun point(x: Double, y: Double) = Offset(x.toFloat() * size.width, y.toFloat() * size.height)
    fun line(x1: Double, y1: Double, x2: Double, y2: Double) =
        drawLine(ink, point(x1, y1), point(x2, y2), stroke.width)
    fun circle(x: Double, y: Double, r: Double, hollow: Boolean = false) {
        if (hollow) drawCircle(ink, (r * size.minDimension).toFloat(), point(x, y), style = stroke)
        else drawCircle(ink, (r * size.minDimension).toFloat(), point(x, y))
    }
    fun box(x: Double, y: Double, width: Double, height: Double) {
        val extent = Size((width * size.width).toFloat(), (height * size.height).toFloat())
        val radius = CornerRadius(size.minDimension * 0.025f)
        drawRoundRect(fill, point(x, y), extent, radius)
        drawRoundRect(ink, point(x, y), extent, radius, style = stroke)
    }
    fun star(x: Double, y: Double, radius: Double) {
        line(x - radius, y, x + radius, y)
        line(x, y - radius, x, y + radius)
    }
    when (mood) {
        PersonaMood.Reading -> {
            // Folded paper seen from behind, with eyes above its top edge.
            val bob = sin(time * 2) * 0.007
            box(0.25, 0.69 + bob, 0.50, 0.23)
            line(0.50, 0.70 + bob, 0.50, 0.91 + bob)
        }
        PersonaMood.Gaming -> {
            val tilt = sin(time * 4) * 0.015
            box(0.28, 0.74 + tilt, 0.44, 0.17)
            circle(0.33, 0.84 + tilt, 0.018)
            circle(0.67, 0.84 + tilt, 0.018)
        }
        PersonaMood.Typing -> {
            box(0.26, 0.69, 0.48, 0.23)
            line(0.22, 0.93, 0.78, 0.93)
            val tap = sin(time * 14) * 0.018
            circle(0.27, 0.79 + tap, 0.035)
            circle(0.73, 0.79 - tap, 0.035)
        }
        PersonaMood.Sipping -> {
            val lift = (sin(time * 1.4) + 1) * 0.055
            box(0.64, 0.73 - lift, 0.16, 0.17)
            drawArc(ink, -90f, 180f, false, point(0.76, 0.76 - lift),
                Size(size.width * 0.10f, size.height * 0.10f), style = stroke)
            for (i in 0..1) {
                val drift = sin(time * 2 + i) * 0.015
                line(0.68 + i * 0.07, 0.66 - lift, 0.68 + i * 0.07 + drift, 0.60 - lift)
            }
        }
        PersonaMood.Sketching -> {
            box(0.31, 0.76, 0.38, 0.16)
            val tip = 0.49 + sin(time * 4) * 0.10
            line(tip, 0.84, tip + 0.13, 0.62)
            line(0.38, 0.87, 0.53, 0.85)
        }
        PersonaMood.Gardening -> {
            val pot = Path().apply {
                moveTo(size.width * 0.69f, size.height * 0.80f)
                lineTo(size.width * 0.89f, size.height * 0.80f)
                lineTo(size.width * 0.85f, size.height * 0.95f)
                lineTo(size.width * 0.73f, size.height * 0.95f)
                close()
            }
            drawPath(pot, fill); drawPath(pot, ink, style = stroke)
            val sway = sin(time * 2) * 0.025
            line(0.79, 0.80, 0.79 + sway, 0.60)
            line(0.79 + sway, 0.69, 0.70 + sway, 0.64)
            line(0.79 + sway, 0.73, 0.88 + sway, 0.65)
        }
        PersonaMood.Snacking -> {
            val lift = (sin(time * 2.0) + 1) * 0.045
            circle(0.72, 0.76 - lift, 0.065, hollow = true)
            circle(0.70, 0.74 - lift, 0.009)
            circle(0.75, 0.78 - lift, 0.009)
        }
        PersonaMood.Juggling -> {
            repeat(3) { i ->
                val phase = time * 3.5 + i * 2 * PI / 3
                circle(0.5 + cos(phase) * 0.28, 0.31 - sin(phase).coerceAtLeast(0.0) * 0.21, 0.038)
            }
        }
        PersonaMood.Stargazing -> {
            repeat(4) { i ->
                val twinkle = 0.017 + (sin(time * 1.7 + i) + 1) * 0.009
                star(0.16 + i * 0.22, 0.11 + (i % 2) * 0.12, twinkle)
            }
        }
        PersonaMood.Bubbling -> {
            repeat(3) { i ->
                val age = (time * 0.23 + i / 3.0) % 1
                circle(0.76 + sin(time + i) * 0.10, 0.69 - age * 0.61, 0.025 + age * 0.035, hollow = true)
            }
        }
        PersonaMood.Speaking -> {
            for (i in 0..2) {
                val pulse = (sin(time * 7 - i) + 1) * 0.015
                line(0.82 + i * 0.045, 0.50 - pulse, 0.82 + i * 0.045, 0.57 + pulse)
            }
        }
        PersonaMood.Complete -> star(0.79, 0.23, 0.04 + sin(time * 3) * 0.009)
        PersonaMood.Sleeping -> {
            repeat(2) { i ->
                val x = 0.71 + i * 0.12
                val y = 0.28 - i * 0.12 - sin(time) * 0.015
                line(x, y, x + 0.06, y)
                line(x + 0.06, y, x, y + 0.06)
                line(x, y + 0.06, x + 0.06, y + 0.06)
            }
        }
        else -> Unit
    }
}
