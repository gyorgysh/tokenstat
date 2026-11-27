// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.ssh

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class VaultRecoveryOriginTest {
    @Test fun onlySetupRecoveryCanDiscardTheVaultWithoutTypedConfirmation() {
        assertTrue(VaultRecoveryOrigin.Created.allowsDiscard)
        assertFalse(VaultRecoveryOrigin.UnlockMigration.allowsDiscard)
        assertFalse(VaultRecoveryOrigin.PasswordRecovery.allowsDiscard)
    }
}
