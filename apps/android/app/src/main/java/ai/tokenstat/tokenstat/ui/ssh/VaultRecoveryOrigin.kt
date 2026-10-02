// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.ssh

/** Only setup creates an unconfirmed vault that can be discarded without typing DELETE. */
internal enum class VaultRecoveryOrigin {
    Created,
    UnlockMigration,
    PasswordRecovery;

    val allowsDiscard: Boolean get() = this == Created
}
