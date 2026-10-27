// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat

import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class AccountEntitlementTest {
    private fun account(tier: String, remote: Boolean? = null, signedIn: Boolean = true) =
        buildJsonObject {
            put("signedIn", signedIn)
            put("tier", tier)
            remote?.let { put("canRemote", it) }
        }

    @Test fun personalRemoteIncludesFreeButVaultRemainsPaid() {
        for (tier in listOf("free", "supporter", "patron", "legend")) {
            val state = ClientState(account = account(tier))
            assertTrue(state.canRemote)
            if (tier == "free") assertFalse(state.vaultAllowed) else assertTrue(state.vaultAllowed)
        }
        assertFalse(ClientState(account = account("free", remote = false)).canRemote)
        assertFalse(ClientState(account = account("free", signedIn = false)).canRemote)
        assertFalse(ClientState(account = account("free", remote = true)).vaultAllowed)
    }
}
