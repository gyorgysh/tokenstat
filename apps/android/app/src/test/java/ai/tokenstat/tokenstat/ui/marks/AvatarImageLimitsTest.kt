package ai.tokenstat.tokenstat.ui.marks

import org.junit.Assert.*
import org.junit.Test

class AvatarImageLimitsTest {
    @Test fun `small avatars retain their pixels`() {
        assertEquals(1, AvatarImageLimits.sampleSize(64, 96))
        assertEquals(1, AvatarImageLimits.sampleSize(512, 512))
    }
    @Test fun `large and extreme dimensions decode within the avatar budget`() {
        for ((w, h) in listOf(4000 to 3000, 1 to 100000, Int.MAX_VALUE to Int.MAX_VALUE)) {
            val sample = AvatarImageLimits.sampleSize(w, h)!!
            assertTrue(maxOf(w, h).toLong() <= 512L * sample)
            assertEquals(0, sample and (sample - 1))
        }
    }
    @Test fun `invalid image bounds are rejected`() {
        assertNull(AvatarImageLimits.sampleSize(-1, 512))
        assertNull(AvatarImageLimits.sampleSize(512, 0))
    }
}
