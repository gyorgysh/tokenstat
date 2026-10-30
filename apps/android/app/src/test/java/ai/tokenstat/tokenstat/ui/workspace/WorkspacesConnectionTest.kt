// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.workspace

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class WorkspacesConnectionTest {
    @Test fun explicit_host_choice_replaces_home_warmup_without_late_publication() {
        val session = WorkspacesConnectionState()
        val warmup = session.beginConnecting("saved-host")!!
        assertNull(session.beginConnecting("saved-host"))
        val chosen = session.beginConnecting("chosen-host", explicit = true)!!
        assertFalse(session.isCurrentConnection(warmup))
        session.finishConnecting(warmup)
        assertEquals("chosen-host", session.connectingPeer.value)
        assertTrue(session.isCurrentConnection(chosen))
        session.disconnect()
        assertFalse(session.isCurrentConnection(chosen))
        assertNull(session.connectingPeer.value)
    }
}
