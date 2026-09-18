// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.billing

import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/// Where "See plans" goes, in one place. Port of the Apple client's `Plans`
/// and its `tokenstatOpenPaywall` notification.
///
/// A plan here is a Play subscription, so every route to it ends at the
/// in-app paywall and the system's own purchase sheet. A gate that opens the
/// pricing page in a browser instead is a gate somebody cannot buy from, and
/// it puts the one screen that sells the plan behind two more taps in
/// Account. One object so a new gate cannot get that backwards.
object Plans {
    private val requests = MutableStateFlow(0)

    /// Bumped rather than set, so two gates in a row both open the sheet even
    /// if the first was dismissed without the state ever going back to false.
    val openRequests: StateFlow<Int> = requests.asStateFlow()

    fun open() {
        requests.value = requests.value + 1
    }
}
