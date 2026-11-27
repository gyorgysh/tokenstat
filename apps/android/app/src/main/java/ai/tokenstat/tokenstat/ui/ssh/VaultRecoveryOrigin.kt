// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.ssh

internal enum class VaultRecoveryOrigin {
    Created,
    UnlockMigration,
    PasswordRecovery;

    val allowsDiscard: Boolean get() = this == Created
}
