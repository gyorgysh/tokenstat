// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.persona

import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.lerp
import kotlin.math.PI
import kotlin.math.sin

/// The fixed features of one character, derived from its seed. Port of
/// `PersonaTraits`.
///
/// Deterministic and cheap: the same persona is the same creature on every
/// launch, on every device, with nothing stored but the number.
///
/// The draw order mirrors `PersonaRenderer`: contact shadow, antenna, body
/// gradient fill, stroke, clipped highlight, then the face. Colour stays
/// inside the brand: the hue walks the accent-to-secondary arc, never the
/// whole wheel.
class PersonaTraits(seed: ULong, nodes: Int = 14) {
    /// How this creature's eyes are drawn when they are open. Curved arcs are
    /// deliberately not in here: arcs are an expression, not a feature.
    enum class EyeShape { ROUND, OVAL, PIXEL }

    enum class Mouth { DOT, SMILE, FLAT, FROWN }

    val eyeCount: Int
    val eyeShape: EyeShape
    val mouth: Mouth?

    /** How wide this creature's mouth sits, as a multiplier. */
    val mouthWidth: Float

    /** Stiffness multiplier. Below one is slime, above one is gel. */
    val firmness: Float

    /** A permanent radial offset per node: this creature's own dents. */
    val lumps: List<Float>

    val hasAntenna: Boolean

    /** How far along the accent-to-secondary arc this creature sits, 0 to 1. */
    val hueMix: Float

    init {
        var bits = if (seed == 0UL) 0x9E3779B97F4A7C15UL else seed
        fun next(modulo: ULong): ULong {
            bits = bits xor (bits shl 13)
            bits = bits xor (bits shr 7)
            bits = bits xor (bits shl 17)
            return bits % modulo
        }
        eyeCount = when (next(10UL)) {
            0UL, 1UL -> 1
            2UL -> 3
            else -> 2
        }
        eyeShape = when (next(4UL)) {
            0UL -> EyeShape.ROUND
            1UL -> EyeShape.PIXEL
            else -> EyeShape.OVAL
        }
        mouth = when (next(5UL)) {
            0UL -> Mouth.SMILE
            1UL -> Mouth.FLAT
            2UL -> Mouth.DOT
            else -> null
        }
        hasAntenna = next(3UL) == 0UL
        mouthWidth = 0.78f + next(9UL).toFloat() * 0.06f
        firmness = 0.78f + next(9UL).toFloat() * 0.055f
        // Two low harmonics rather than per-node noise. Noise reads as a
        // damaged circle, harmonics read as a shape somebody drew.
        val firstPhase = next(360UL).toFloat() * PI.toFloat() / 180f
        val secondPhase = next(360UL).toFloat() * PI.toFloat() / 180f
        val firstAmount = 0.35f + next(100UL).toFloat() / 100f * 0.45f
        val secondAmount = next(100UL).toFloat() / 100f * 0.30f
        val dents = ArrayList<Float>(nodes)
        for (index in 0 until nodes) {
            val angle = index.toFloat() * 2f * PI.toFloat() / nodes.toFloat()
            dents.add(
                sin(angle * 2f + firstPhase) * firstAmount +
                    sin(angle * 3f + secondPhase) * secondAmount,
            )
        }
        lumps = dents
        hueMix = next(7UL).toFloat() / 6f
    }

    /// This creature's tint: a colour the app already owns, on the arc from
    /// the accent to the secondary.
    fun hue(accent: Color, secondary: Color): Color = lerp(accent, secondary, hueMix)
}

/// A face for something that has no persona.
///
/// Every conversation gets a character, whether or not anybody made one, so
/// the transcript is never a row of grey dots waiting for a feature to be
/// used. Derived from the conversation's own id, so it is that chat's face for
/// as long as the chat exists.
///
/// The same FNV-1a as `chat_turn::stable_hash` on the host, on purpose: a
/// persona seeded there and a chat seeded here have to sit in the same family,
/// and a second hash function would be a second set of faces.
fun personaSeed(identifier: String): ULong {
    var hash = 0xCBF29CE484222325UL
    for (byte in identifier.toByteArray(Charsets.UTF_8)) {
        hash = hash xor byte.toUByte().toULong()
        hash *= 0x100000001B3UL
    }
    return hash or 1UL
}
