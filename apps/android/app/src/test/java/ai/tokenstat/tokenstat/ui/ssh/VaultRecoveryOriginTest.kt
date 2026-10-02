// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.ssh

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class VaultRecoveryOriginTest {
    @Test fun onlySetupRecoveryCanDiscardTheVaultWithoutTypedConfirmation() {
        assertTrue(VaultRecoveryOrigin.Created.allowsDiscard)
        // Both return new recovery words for an existing vault: words alone
        // must never turn its recovery confirmation into a reset shortcut.
        assertFalse(VaultRecoveryOrigin.UnlockMigration.allowsDiscard)
        assertFalse(VaultRecoveryOrigin.PasswordRecovery.allowsDiscard)
    }
}
