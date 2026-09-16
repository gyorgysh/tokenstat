// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.ssh

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class SshRowsTest {
    @Test
    fun shortFingerprintStripsAlgorithmPrefix() {
        assertEquals("abc123", shortFingerprint("SHA256:abc123"))
        assertEquals("whole", shortFingerprint("whole"))
        assertNull(shortFingerprint(""))
        assertNull(shortFingerprint(null))
        assertEquals("SHA256:", shortFingerprint("SHA256:"))
    }
}
