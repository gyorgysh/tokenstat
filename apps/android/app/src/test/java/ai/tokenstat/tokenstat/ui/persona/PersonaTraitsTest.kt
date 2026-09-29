// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.persona

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/// The face math must match `PersonaTraits.swift` exactly: the same persona is
/// the same creature on every client, so a drift here is a different cast.
/// Raw generator outputs below were computed independently from the xorshift
/// sequence, not copied from this implementation.
class PersonaTraitsTest {
    @Test
    fun seedZeroFallsBackToSettledLook() {
        val traits = PersonaTraits(0UL)
        assertEquals(2, traits.eyeCount)
        assertEquals(PersonaTraits.EyeShape.OVAL, traits.eyeShape)
        assertEquals(PersonaTraits.Mouth.SMILE, traits.mouth)
        assertFalse(traits.hasAntenna)
        assertEquals(0.895f, traits.mouthWidth, 1e-6f)
        assertEquals(1.04f, traits.firmness, 1e-6f)
        assertEquals(4f / 6f, traits.hueMix, 1e-6f)
    }

    @Test
    fun seedOneMatchesSwiftSequence() {
        val traits = PersonaTraits(1UL)
        assertEquals(2, traits.eyeCount)
        assertEquals(PersonaTraits.EyeShape.OVAL, traits.eyeShape)
        assertEquals(PersonaTraits.Mouth.SMILE, traits.mouth)
        assertFalse(traits.hasAntenna)
        assertEquals(0.895f, traits.mouthWidth, 1e-6f)
        assertEquals(0.98f, traits.firmness, 1e-6f)
        assertEquals(2f / 6f, traits.hueMix, 1e-6f)
    }

    @Test
    fun seed42KeepsItsColourWithAGentleSmile() {
        val traits = PersonaTraits(42UL)
        assertEquals(2, traits.eyeCount)
        assertEquals(PersonaTraits.EyeShape.OVAL, traits.eyeShape)
        assertEquals(PersonaTraits.Mouth.SMILE, traits.mouth)
        assertFalse(traits.hasAntenna)
        assertEquals(0.72f, traits.mouthWidth, 1e-6f)
        assertEquals(5f / 6f, traits.hueMix, 1e-6f)
    }

    @Test
    fun sameSeedIsSameCreature() {
        val first = PersonaTraits(123456789UL)
        val second = PersonaTraits(123456789UL)
        assertEquals(first.bodyShape, second.bodyShape)
        assertEquals(first.eyeCount, second.eyeCount)
        assertEquals(first.eyeShape, second.eyeShape)
        assertEquals(first.mouth, second.mouth)
        assertEquals(first.hasAntenna, second.hasAntenna)
        assertEquals(first.mouthWidth, second.mouthWidth, 0f)
        assertEquals(first.lumps, second.lumps)
        assertEquals(first.hueMix, second.hueMix, 0f)
    }

    @Test
    fun lumpsAreBoundedAndPerNode() {
        val traits = PersonaTraits(7UL)
        assertEquals(20, traits.lumps.size)
        traits.lumps.forEach { lump ->
            assertTrue("lump $lump out of range", lump >= -5.6f && lump <= 3f)
        }
    }

    @Test
    fun seedsAreACastNotAMascot() {
        val eyes = (1UL..200UL).map { PersonaTraits(it).eyeCount }.toSet()
        val shapes = (1UL..200UL).map { PersonaTraits(it).eyeShape }.toSet()
        val antennae = (1UL..200UL).map { PersonaTraits(it).hasAntenna }.toSet()
        assertEquals(setOf(2), eyes)
        assertTrue(shapes.size > 1)
        assertEquals(setOf(false), antennae)
        val bodies = (1UL..200UL).map { PersonaTraits(it).bodyShape }.toSet()
        assertEquals(PersonaTraits.BodyShape.entries.toSet(), bodies)
    }

    @Test
    fun personaSeedIsFnv1a() {
        assertEquals(14695981039346656037UL, personaSeed(""))
        assertEquals(150912782645362759UL, personaSeed("empty-chat"))
        assertEquals(16654208175385433931UL, personaSeed("abc"))
    }

    @Test
    fun personaSeedIsStableAndOdd() {
        val first = personaSeed("some-chat-id")
        assertEquals(first, personaSeed("some-chat-id"))
        assertEquals(1UL, first and 1UL)
    }
}
