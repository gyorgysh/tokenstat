// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.ssh

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive

/** Retire each awaited vault step before it can publish or start a later write. */
internal class VaultOperationGuard(private val isCurrentOwner: () -> Boolean) {
    suspend fun check() {
        currentCoroutineContext().ensureActive()
        if (!isCurrentOwner()) throw CancellationException("Vault account changed")
    }

    suspend fun <T> run(operation: suspend () -> T): T {
        check()
        val result = operation()
        check()
        return result
    }
}
