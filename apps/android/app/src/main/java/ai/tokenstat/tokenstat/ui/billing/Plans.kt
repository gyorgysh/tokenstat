// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.billing

import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

object Plans {
    private val requests = MutableStateFlow(0)

    val openRequests: StateFlow<Int> = requests.asStateFlow()

    fun open() {
        requests.value = requests.value + 1
    }
}
