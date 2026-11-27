// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.persona

import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.lerp
import kotlin.math.PI
import kotlin.math.sin
import kotlin.math.cos
import kotlin.math.pow
import kotlin.math.max
import kotlin.math.abs
import kotlin.math.min

class PersonaTraits(seed: ULong, nodes: Int = 20) {
    enum class BodyShape { BALL, STAR, HEART, TORTILLA }
    val bodyShape = BodyShape.entries[((seed shr 1) % 4UL).toInt()]

    enum class EyeShape { ROUND, OVAL, PIXEL }

    enum class Mouth { DOT, SMILE, FLAT, FROWN }

    val eyeCount: Int
    val eyeShape: EyeShape
    val mouth: Mouth?

    val mouthWidth: Float

    val firmness: Float

    val lumps: List<Float>

    val hasAntenna: Boolean

    val hueMix: Float

    companion object {
        private val heartOutline = List(64) { i ->
            val t = i * 2 * PI / 64
            Pair(16 * sin(t).pow(3) / 17,
                -(13 * cos(t) - 5 * cos(2 * t) - 2 * cos(3 * t) - cos(4 * t)) / 17)
        }

        private fun heartRadius(angle: Double): Double {
            val dx = cos(angle); val dy = sin(angle)
            var radius = 1.0
            for (i in heartOutline.indices) {
                val p = heartOutline[i]; val q = heartOutline[(i + 1) % heartOutline.size]
                val ex = q.first - p.first; val ey = q.second - p.second
                val cross = dx * ey - dy * ex
                if (abs(cross) < 1e-8) continue
                val u = (p.first * dy - p.second * dx) / cross
                val r = (p.first * ey - p.second * ex) / cross
                if (u in 0.0..1.0 && r > 0) radius = min(radius, r)
            }
            return max(0.42, radius)
        }
    }

    init {
        var bits = if (seed == 0UL) 0x9E3779B97F4A7C15UL else seed
        fun next(modulo: ULong): ULong {
            bits = bits xor (bits shl 13)
            bits = bits xor (bits shr 7)
            bits = bits xor (bits shl 17)
            return bits % modulo
        }
        next(10UL)
        eyeCount = 2
        eyeShape = if (next(4UL) == 0UL) EyeShape.ROUND else EyeShape.OVAL
        next(5UL)
        mouth = Mouth.SMILE
        next(3UL)
        hasAntenna = false
        mouthWidth = 0.72f + next(9UL).toFloat() * 0.035f
        firmness = 0.95f + next(9UL).toFloat() * 0.03f
        val firstPhase = next(360UL).toFloat() * PI.toFloat() / 180f
        val secondPhase = next(360UL).toFloat() * PI.toFloat() / 180f
        val firstAmount = 0.10f + next(100UL).toFloat() / 100f * 0.15f
        val secondAmount = 0.04f + next(100UL).toFloat() / 100f * 0.07f
        val dents = ArrayList<Float>(nodes)
        for (index in 0 until nodes) {
            val angle = index.toFloat() * 2f * PI.toFloat() / nodes.toFloat()
            val silhouette = when (bodyShape) {
                BodyShape.BALL -> 0f
                BodyShape.STAR -> -sin(5 * angle) * 0.24f
                BodyShape.HEART -> heartRadius(angle.toDouble()).toFloat() - 1f
                BodyShape.TORTILLA -> (0.6f * cos(2 * angle) + 0.35f * sin(angle)) * 0.34f
            }
            val softness = sin(angle * 2f + firstPhase) * firstAmount +
                sin(angle * 3f + secondPhase) * secondAmount
            dents.add(silhouette * 10f + softness * 0.25f)
        }
        lumps = dents
        hueMix = next(7UL).toFloat() / 6f
    }

    fun hue(accent: Color, secondary: Color): Color = lerp(accent, secondary, hueMix)
}

fun personaSeed(identifier: String): ULong {
    var hash = 0xCBF29CE484222325UL
    for (byte in identifier.toByteArray(Charsets.UTF_8)) {
        hash = hash xor byte.toUByte().toULong()
        hash *= 0x100000001B3UL
    }
    return hash or 1UL
}
